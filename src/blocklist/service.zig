const std = @import("std");
const Source = @import("source.zig").Source;
const fetch = @import("fetch.zig");
const parse = @import("parse.zig");
const Index = @import("index.zig").Index;
const Store = @import("../lists/store.zig").Store;
const log = std.log.scoped(.blocklist);

/// Mutations run before serving, or under the caller's exclusive publication
/// lock. Queries borrow immutable state and perform a single RAM hash lookup.
pub const Service = struct {
    const Entry = struct {
        source: Source,
        snapshot: Index.Snapshot,
        health: Health,
        fingerprint: ?[64]u8 = null,
    };

    pub const Health = struct {
        state: enum { disabled, active, degraded, unavailable },
        last_error: ?[]const u8 = null,
        last_success_at_ms: ?i64 = null,
        domain_count: usize = 0,
    };

    pub const Refresh = union(enum) {
        none,
        all,
        one: []const u8,
    };

    /// Prepared outside the publication guard. Source metadata must remain
    /// stable until commit/deinit: the caller serializes writers separately.
    /// Unchanged entries and their snapshots are never copied.
    pub const Plan = struct {
        const Change = struct {
            source: Source,
            names: ?parse.Names = null,
            snapshot: ?[][]const u8 = null,
            health: ?Health = null,
            fingerprint: ?[64]u8 = null,
        };

        allocator: std.mem.Allocator,
        changes: std.ArrayList(Change) = .empty,
        removals: std.ArrayList([]const u8) = .empty,
        additions: u32 = 0,
        incoming_names: u32 = 0,
        reserved: bool = false,
        committed: bool = false,

        pub fn deinit(self: *Plan) void {
            for (self.changes.items) |*change| {
                if (change.names) |*names| names.deinit();
                if (!self.committed) {
                    change.source.deinit(self.allocator);
                    if (change.snapshot) |snapshot| self.allocator.free(snapshot);
                }
            }
            self.changes.deinit(self.allocator);
            self.removals.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn changed(self: *const Plan) bool {
            return self.changes.items.len != 0 or self.removals.items.len != 0;
        }

        /// Hold the publication guard for reserve and commit. On failure only
        /// hash-table capacity may change, never metadata or memberships.
        pub fn reserve(self: *Plan, service: *Service) !void {
            std.debug.assert(!self.committed);
            self.reserved = false;
            if (self.additions != 0) {
                const total = std.math.add(u32, service.sources.count(), self.additions) catch return error.OutOfMemory;
                try service.sources.ensureTotalCapacity(self.allocator, total);
            }
            try service.index.reserve(self.incoming_names);
            self.reserved = true;
        }

        /// No allocation or failure after reserve. Acquire every new membership
        /// before releasing any old one, including domains moving between IDs.
        pub fn commit(self: *Plan, service: *Service) void {
            std.debug.assert(self.reserved and !self.committed);
            for (self.changes.items) |*change| {
                if (change.names) |*names| service.index.acquireReserved(names, change.snapshot.?);
            }
            for (self.changes.items) |*change| {
                if (service.sources.getPtr(change.source.id)) |entry| {
                    const old = entry.*;
                    // Preserve the key allocation used by the source hash map.
                    self.allocator.free(change.source.id);
                    change.source.id = old.source.id;
                    entry.* = .{
                        .source = change.source,
                        .snapshot = change.snapshot orelse old.snapshot,
                        .health = change.health orelse old.health,
                        .fingerprint = change.fingerprint,
                    };
                    if (change.snapshot != null) service.index.release(old.snapshot);
                    if (old.source.name) |name| self.allocator.free(name);
                    self.allocator.free(old.source.source.value);
                    if (old.source.access.file_root) |root| self.allocator.free(root);
                } else {
                    service.sources.putAssumeCapacityNoClobber(change.source.id, .{
                        .source = change.source,
                        .snapshot = change.snapshot.?,
                        .health = change.health.?,
                        .fingerprint = change.fingerprint,
                    });
                }
            }
            for (self.removals.items) |id| {
                var old = service.sources.fetchRemove(id).?.value;
                service.index.release(old.snapshot);
                old.source.deinit(self.allocator);
            }
            self.committed = true;
        }
    };

    allocator: std.mem.Allocator,
    sources: std.StringHashMapUnmanaged(Entry) = .empty,
    index: Index,
    /// Borrowed; owned by the process and assigned before startup imports.
    store: ?*Store = null,

    pub fn init(allocator: std.mem.Allocator) Service {
        return .{ .allocator = allocator, .index = Index.init(allocator) };
    }

    pub fn deinit(self: *Service) void {
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            self.index.release(entry.snapshot);
            entry.source.deinit(self.allocator);
        }
        self.sources.deinit(self.allocator);
        self.index.deinit();
        self.* = undefined;
    }

    pub fn contains(self: *const Service, canonical: []const u8) bool {
        return self.index.contains(canonical);
    }

    /// Borrowed runtime values; callers hold the state publication mutex.
    pub fn health(self: *const Service, id: []const u8) ?Health {
        return if (self.sources.get(id)) |entry| entry.health else null;
    }

    /// Compare definitions by ID, independent of order. Only additions,
    /// newly-enabled sources, changed locations/formats, or explicit refreshes
    /// perform I/O. Never reads the live domain index during preparation.
    /// Cache writes commit atomically during preparation, before publication.
    /// If a later RAM reserve/publication fails, durable successful snapshots
    /// may be newer than active RAM; the next import still fetches first.
    pub fn prepare(self: *const Service, io: std.Io, definitions: []const Source, base_dir: []const u8, requested: Refresh) !Plan {
        var plan: Plan = .{ .allocator = self.allocator };
        errdefer plan.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        // Validate the entire candidate before starting any source I/O.
        for (definitions) |source| {
            try source.validate();
            const result = try seen.getOrPut(self.allocator, source.id);
            if (result.found_existing) return error.DuplicateSourceId;
        }
        switch (requested) {
            .one => |id| if (!seen.contains(id)) return error.SourceNotFound,
            else => {},
        }
        const resolved_base = if (self.store != null and definitions.len != 0)
            try std.Io.Dir.cwd().realPathFileAlloc(io, base_dir, self.allocator)
        else
            null;
        defer if (resolved_base) |path| self.allocator.free(path);
        var transaction: ?Store.Transaction = if (self.store) |store| try store.begin() else null;
        defer if (transaction) |*tx| tx.deinit();
        for (definitions) |source| {
            const fingerprint_value = if (resolved_base) |path| fingerprint(source, path) else null;
            const old = self.sources.get(source.id);
            const explicit_refresh = source.enabled and switch (requested) {
                .none => false,
                .all => true,
                .one => |id| std.mem.eql(u8, source.id, id),
            };
            const content_changed = if (old) |entry|
                source.enabled != entry.source.enabled or !sameLocation(source, entry.source) or
                    !sameFingerprint(fingerprint_value, entry.fingerprint)
            else
                true;
            const metadata_changed = if (old) |entry|
                content_changed or !sameName(source.name, entry.source.name)
            else
                true;
            if (!metadata_changed and !explicit_refresh) continue;

            var change: Plan.Change = .{ .source = try source.clone(self.allocator) };
            change.fingerprint = fingerprint_value;
            errdefer change.source.deinit(self.allocator);
            errdefer if (change.names) |*names| names.deinit();
            errdefer if (change.snapshot) |snapshot| self.allocator.free(snapshot);
            if ((source.enabled and (content_changed or explicit_refresh)) or old == null or
                (old != null and old.?.source.enabled and !source.enabled))
            {
                const loaded = try self.loadNames(io, source, base_dir, if (transaction) |*tx| tx else null, fingerprint_value);
                change.names = loaded.names;
                change.health = loaded.health;
                change.snapshot = try self.allocator.alloc([]const u8, change.names.?.entries.count());
                plan.incoming_names = std.math.add(u32, plan.incoming_names, change.names.?.entries.count()) catch return error.OutOfMemory;
            }
            if (old == null) plan.additions = std.math.add(u32, plan.additions, 1) catch return error.OutOfMemory;
            try plan.changes.append(self.allocator, change);
        }
        var existing = self.sources.keyIterator();
        while (existing.next()) |id| {
            if (!seen.contains(id.*)) try plan.removals.append(self.allocator, id.*);
        }
        if (transaction) |*tx| {
            try tx.retain(&seen);
            try tx.commit();
        }
        return plan;
    }

    fn sameLocation(a: Source, b: Source) bool {
        return a.format == b.format and a.source.kind == b.source.kind and
            a.api_managed == b.api_managed and
            a.access.allow_private_sources == b.access.allow_private_sources and
            sameName(a.access.file_root, b.access.file_root) and
            std.mem.eql(u8, a.source.value, b.source.value);
    }

    fn sameName(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
        return b == null;
    }

    fn sameFingerprint(a: ?[64]u8, b: ?[64]u8) bool {
        if (a) |left| return if (b) |right| std.mem.eql(u8, &left, &right) else false;
        return b == null;
    }

    fn fingerprint(source: Source, resolved_base: []const u8) [64]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // Length-prefixed fields avoid delimiter collisions. A version prefix
        // prevents reusing snapshots if import/security semantics change.
        const fields = [_][]const u8{
            "block-import-v1", @tagName(source.source.kind), source.source.value,
            @tagName(source.format), if (source.api_managed) "managed" else "operator",
            if (source.access.allow_private_sources) "private" else "public",
            if (source.access.file_root != null) "root" else "no-root",
            source.access.file_root orelse "", resolved_base,
        };
        for (fields) |field| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(field.len), .little);
            hasher.update(&length);
            hasher.update(field);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }

    /// Definitions and snapshots are owned, including disabled definitions.
    pub fn add(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !void {
        try source.validate();
        if (self.sources.contains(source.id)) return error.DuplicateSourceId;
        var owned = try source.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.sources.ensureUnusedCapacity(self.allocator, 1);
        const loaded = try self.load(io, owned, base_dir);
        self.sources.putAssumeCapacityNoClobber(owned.id, .{ .source = owned, .snapshot = loaded.snapshot, .health = loaded.health, .fingerprint = loaded.fingerprint });
        self.report("added", owned, loaded.snapshot.len);
    }

    /// Replace metadata and content together, retaining the stable ID. Durable
    /// imports expose degraded/unavailable health on fetch or parse failure.
    pub fn replace(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !void {
        try source.validate();
        const entry = self.sources.getPtr(source.id) orelse return error.SourceNotFound;
        var owned = try source.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const loaded = try self.load(io, owned, base_dir);
        const old = entry.*;
        // Keep the hash table key allocation stable while replacing other fields.
        self.allocator.free(owned.id);
        owned.id = old.source.id;
        entry.* = .{ .source = owned, .snapshot = loaded.snapshot, .health = loaded.health, .fingerprint = loaded.fingerprint };
        self.index.release(old.snapshot);
        if (old.source.name) |name| self.allocator.free(name);
        self.allocator.free(old.source.source.value);
        if (old.source.access.file_root) |root| self.allocator.free(root);
        self.report("replaced", owned, loaded.snapshot.len);
    }

    pub fn refresh(self: *Service, id: []const u8, io: std.Io, base_dir: []const u8) !void {
        const entry = self.sources.getPtr(id) orelse return error.SourceNotFound;
        const loaded = try self.load(io, entry.source, base_dir);
        const old = entry.snapshot;
        entry.snapshot = loaded.snapshot;
        entry.health = loaded.health;
        entry.fingerprint = loaded.fingerprint;
        self.index.release(old);
        self.report("refreshed", entry.source, loaded.snapshot.len);
    }

    pub fn remove(self: *Service, id: []const u8) !void {
        if (!self.sources.contains(id)) return error.SourceNotFound;
        if (self.store) |store| {
            var transaction = try store.begin();
            defer transaction.deinit();
            try transaction.remove(id);
            try transaction.commit();
        }
        var entry = self.sources.fetchRemove(id).?.value;
        self.report("removed", entry.source, entry.snapshot.len);
        self.index.release(entry.snapshot);
        entry.source.deinit(self.allocator);
    }

    const Loaded = struct { names: parse.Names, health: Health };
    const LoadedSnapshot = struct { snapshot: Index.Snapshot, health: Health, fingerprint: ?[64]u8 };

    fn load(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !LoadedSnapshot {
        var transaction: ?Store.Transaction = if (self.store) |store| try store.begin() else null;
        defer if (transaction) |*tx| tx.deinit();
        const resolved_base = if (self.store != null)
            try std.Io.Dir.cwd().realPathFileAlloc(io, base_dir, self.allocator)
        else
            null;
        defer if (resolved_base) |path| self.allocator.free(path);
        const key = if (resolved_base) |path| fingerprint(source, path) else null;
        var loaded = try self.loadNames(io, source, base_dir, if (transaction) |*tx| tx else null, key);
        defer loaded.names.deinit();
        const snapshot = try self.index.acquire(&loaded.names);
        errdefer self.index.release(snapshot);
        if (transaction) |*tx| try tx.commit();
        return .{ .snapshot = snapshot, .health = loaded.health, .fingerprint = key };
    }

    fn loadNames(self: *const Service, io: std.Io, source: Source, base_dir: []const u8, transaction: ?*Store.Transaction, key: ?[64]u8) !Loaded {
        if (!source.enabled) return .{ .names = .{ .allocator = self.allocator }, .health = .{ .state = .disabled } };
        const tx = transaction orelse {
            const names = try self.fetchNames(io, source, base_dir);
            return .{ .names = names, .health = .{ .state = .active, .domain_count = names.entries.count(), .last_success_at_ms = std.Io.Clock.real.now(io).toMilliseconds() } };
        };
        var failure: ?anyerror = null;
        var fetched: ?parse.Names = self.fetchNames(io, source, base_dir) catch |err| blk: {
            switch (err) {
                error.OutOfMemory, error.Canceled, error.ConcurrencyUnavailable => return err,
                else => {},
            }
            failure = err;
            break :blk null;
        };
        defer if (fetched) |*names| names.deinit();
        const fingerprint_value = key.?;
        if (fetched) |*names| {
            try tx.replace(source.id, "block", &fingerprint_value, names, std.Io.Clock.real.now(io).toMilliseconds());
            names.deinit();
            fetched = null;
        }
        if (try tx.load(self.allocator, source.id, &fingerprint_value)) |saved| {
            return .{ .names = saved.names, .health = .{
                .state = if (failure != null) .degraded else .active,
                .last_error = if (failure) |err| @errorName(err) else null,
                .last_success_at_ms = saved.last_success_at_ms,
                .domain_count = saved.names.entries.count(),
            } };
        }
        if (failure == null) return error.SnapshotMissing;
        return .{ .names = .{ .allocator = self.allocator }, .health = .{ .state = .unavailable, .last_error = @errorName(failure.?) } };
    }

    fn fetchNames(self: *const Service, io: std.Io, source: Source, base_dir: []const u8) !parse.Names {
        const contents = try fetch.load(self.allocator, io, source, base_dir);
        defer self.allocator.free(contents);
        return parse.parse(self.allocator, contents, source.format);
    }

    fn report(self: *const Service, action: []const u8, source: Source, count: usize) void {
        log.info("source id={s} name={s} {s}: enabled={} domains={d} total_unique={d}", .{
            source.id, source.name orelse "(unnamed)", action, source.enabled, count, self.index.entries.count(),
        });
    }
};

test "service preserves overlapping membership and last known good on failed refresh and replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "common.test\nfirst.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "common.test\nsecond.test\n" });
    var service = Service.init(allocator);
    defer service.deinit();
    const first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    try service.add(io, first, base);
    try service.add(io, second, base);
    try std.testing.expectError(error.DuplicateSourceId, service.add(io, first, base));
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "new.test\n||invalid.test^\n" });
    try std.testing.expectError(error.InvalidListLine, service.refresh("first", io, base));
    try std.testing.expect(service.contains("first.test"));
    try std.testing.expect(!service.contains("new.test"));
    var replacement = first;
    replacement.name = "replacement";
    try std.testing.expectError(error.InvalidListLine, service.replace(io, replacement, base));
    try std.testing.expect(service.sources.get("first").?.source.name == null);
    try std.testing.expect(service.contains("first.test"));
    replacement.source.value = "missing";
    try std.testing.expectError(error.FileNotFound, service.replace(io, replacement, base));
    try std.testing.expect(service.contains("first.test"));
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "new.test\n" });
    try service.refresh("first", io, base);
    try std.testing.expect(!service.contains("first.test"));
    try std.testing.expect(service.contains("common.test"));
    try std.testing.expect(service.contains("new.test"));
    try service.remove("second");
    try std.testing.expect(!service.contains("common.test"));
    try std.testing.expect(!service.contains("second.test"));
    replacement.source.value = "first";
    replacement.enabled = false;
    try service.replace(io, replacement, base);
    try std.testing.expect(!service.contains("new.test"));
    try std.testing.expectEqualStrings("replacement", service.sources.get("first").?.source.name.?);
    try service.remove("first");
    try std.testing.expectError(error.SourceNotFound, service.remove("first"));
}

test "disabled sources are validated and registered without fetching" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    const source: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "does-not-exist" }, .format = .hosts };
    try service.add(std.testing.io, source, ".");
    try std.testing.expectEqual(@as(u32, 1), service.sources.count());
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());
    var invalid = source;
    invalid.id = "";
    try std.testing.expectError(error.InvalidSourceId, service.add(std.testing.io, invalid, "."));
}

test "plan reuses unavailable unchanged sources and updates metadata without fetching" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "common.test\nfirst.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "common.test\nsecond.test\n" });
    const first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    var service = Service.init(allocator);
    defer service.deinit();
    try service.add(io, first, base);
    try service.add(io, second, base);
    const original = service.sources.get("first").?;
    try temporary.dir.deleteFile(io, "first");
    try temporary.dir.deleteFile(io, "second");

    // A record-only reload passes unchanged source definitions, in any order.
    var unchanged = try service.prepare(io, &.{ second, first }, base, .none);
    defer unchanged.deinit();
    try std.testing.expect(!unchanged.changed());
    try unchanged.reserve(&service);
    unchanged.commit(&service);
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get("first").?.snapshot.ptr);
    try std.testing.expectEqual(original.source.source.value.ptr, service.sources.get("first").?.source.source.value.ptr);

    var renamed = first;
    renamed.name = "renamed";
    var metadata = try service.prepare(io, &.{ renamed, second }, base, .none);
    defer metadata.deinit();
    try std.testing.expect(metadata.changed());
    try std.testing.expect(service.sources.get("first").?.source.name == null);
    try metadata.reserve(&service);
    metadata.commit(&service);
    try std.testing.expectEqualStrings("renamed", service.sources.get("first").?.source.name.?);
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get("first").?.snapshot.ptr);
    try std.testing.expectEqual(original.source.id.ptr, service.sources.get("first").?.source.id.ptr);
    try std.testing.expect(service.contains("first.test"));
    try std.testing.expect(service.contains("second.test"));
}

test "multi-source preparation failure publishes no metadata or memberships" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "old", .data = "old.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "good", .data = "new.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "bad", .data = "partial.test\n||invalid.test^\n" });
    const old: Source = .{ .id = "existing", .source = .{ .kind = .file, .value = "old" }, .format = .domains };
    var service = Service.init(allocator);
    defer service.deinit();
    try service.add(io, old, base);
    const original = service.sources.get(old.id).?;
    var good = old;
    good.name = "new metadata";
    good.source.value = "good";
    const bad: Source = .{ .id = "new", .source = .{ .kind = .file, .value = "bad" }, .format = .domains };
    try std.testing.expectError(error.InvalidListLine, service.prepare(io, &.{ good, bad }, base, .none));
    try std.testing.expectEqual(@as(u32, 1), service.sources.count());
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(old.id).?.snapshot.ptr);
    try std.testing.expect(service.sources.get(old.id).?.source.name == null);
    try std.testing.expect(service.contains("old.test"));
    try std.testing.expect(!service.contains("new.test"));
    try std.testing.expect(!service.contains("partial.test"));
}

test "plan enable disable remove and format changes preserve overlapping memberships" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "common.test\nfirst.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "common.test\nsecond.test\n" });
    var first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    var second: Source = .{ .id = "second", .enabled = false, .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    var service = Service.init(allocator);
    defer service.deinit();
    var initial = try service.prepare(io, &.{ first, second }, base, .none);
    defer initial.deinit();
    try initial.reserve(&service);
    initial.commit(&service);
    const shared = service.index.entries.getKey("common.test").?;
    first.enabled = false;
    second.enabled = true;
    var toggled = try service.prepare(io, &.{ first, second }, base, .none);
    defer toggled.deinit();
    try toggled.reserve(&service);
    toggled.commit(&service);
    try std.testing.expect(!service.contains("first.test"));
    try std.testing.expect(service.contains("second.test"));
    try std.testing.expectEqual(shared.ptr, service.index.entries.getKey("common.test").?.ptr);
    try std.testing.expectEqual(@as(usize, 1), service.index.entries.get("common.test").?);

    // The same path with a changed format must be loaded, not reused.
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "0.0.0.0 common.test hosts.test\n" });
    second.format = .hosts;
    var reformatted = try service.prepare(io, &.{ first, second }, base, .none);
    defer reformatted.deinit();
    try reformatted.reserve(&service);
    reformatted.commit(&service);
    try std.testing.expect(!service.contains("second.test"));
    try std.testing.expect(service.contains("hosts.test"));

    // Removing the last enabled contributor releases its memberships.
    var removed = try service.prepare(io, &.{first}, base, .none);
    defer removed.deinit();
    try removed.reserve(&service);
    removed.commit(&service);
    try std.testing.expectEqual(@as(u32, 1), service.sources.count());
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());
    var empty = try service.prepare(io, &.{}, base, .none);
    defer empty.deinit();
    try empty.reserve(&service);
    empty.commit(&service);
    try std.testing.expectEqual(@as(u32, 0), service.sources.count());
}

test "explicit one and all refreshes are transactional and skip disabled sources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "old.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "second.test\n" });
    const first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    const disabled: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "missing" }, .format = .domains };
    const definitions = [_]Source{ first, second, disabled };
    var service = Service.init(allocator);
    defer service.deinit();
    var initial = try service.prepare(io, &definitions, base, .none);
    defer initial.deinit();
    try initial.reserve(&service);
    initial.commit(&service);
    const second_snapshot = service.sources.get("second").?.snapshot;
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "new.test\n" });
    try temporary.dir.deleteFile(io, "second");
    var one = try service.prepare(io, &definitions, base, .{ .one = "first" });
    defer one.deinit();
    try std.testing.expect(one.changed());
    try one.reserve(&service);
    one.commit(&service);
    try std.testing.expect(service.contains("new.test"));
    try std.testing.expect(!service.contains("old.test"));
    try std.testing.expectEqual(second_snapshot.ptr, service.sources.get("second").?.snapshot.ptr);
    try std.testing.expectError(error.SourceNotFound, service.prepare(io, &definitions, base, .{ .one = "unknown" }));
    var skipped = try service.prepare(io, &definitions, base, .{ .one = "disabled" });
    defer skipped.deinit();
    try std.testing.expect(!skipped.changed());
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "unpublished.test\n" });
    try std.testing.expectError(error.FileNotFound, service.prepare(io, &definitions, base, .all));
    try std.testing.expect(service.contains("new.test"));
    try std.testing.expect(!service.contains("unpublished.test"));
    try std.testing.expect(service.contains("second.test"));
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "||invalid.test^\n" });
    try std.testing.expectError(error.InvalidListLine, service.prepare(io, &definitions, base, .{ .one = "first" }));
    try std.testing.expect(service.contains("new.test"));
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "all-first.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "all-second.test\n" });
    var all = try service.prepare(io, &definitions, base, .all);
    defer all.deinit();
    try all.reserve(&service);
    all.commit(&service);
    try std.testing.expect(service.contains("all-first.test"));
    try std.testing.expect(service.contains("all-second.test"));
    try std.testing.expect(!service.contains("new.test"));
    try std.testing.expect(!service.contains("second.test"));
}

test "plan validates duplicate and disabled definitions before source loading" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    const source: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "missing" }, .format = .hosts };
    try std.testing.expectError(error.DuplicateSourceId, service.prepare(std.testing.io, &.{ source, source }, ".", .none));
    var invalid = source;
    invalid.source = .{ .kind = .url, .value = "https://example.test/list" };
    try std.testing.expectError(error.InvalidUrlFormat, service.prepare(std.testing.io, &.{invalid}, ".", .none));
    try std.testing.expectEqual(@as(u32, 0), service.sources.count());
}

test "failed plan reserves leave logical state intact and commit cannot allocate" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "new.test\n" });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var service = Service.init(failing.allocator());
    defer service.deinit();
    const source: Source = .{ .id = "new", .source = .{ .kind = .file, .value = "list" }, .format = .domains };
    var plan = try service.prepare(io, &.{source}, base, .none);
    defer plan.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, plan.reserve(&service));
    try std.testing.expectEqual(@as(u32, 0), service.sources.count());
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());

    // Let the source map grow, then fail the independent domain-index reserve.
    failing.fail_index = std.math.maxInt(usize);
    try service.sources.ensureUnusedCapacity(service.allocator, 1);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, plan.reserve(&service));
    try std.testing.expectEqual(@as(u32, 0), service.sources.count());
    try std.testing.expect(!service.contains("new.test"));
    try std.testing.expect(plan.changes.items[0].names.?.entries.contains("new.test"));
    failing.fail_index = std.math.maxInt(usize);
    try plan.reserve(&service);
    failing.fail_index = failing.alloc_index;
    plan.commit(&service);
    try std.testing.expect(service.contains("new.test"));
    try std.testing.expectEqual(@as(u32, 1), service.sources.count());
}

fn prepareWithFailingAllocator(allocator: std.mem.Allocator, base: []const u8) !void {
    var service = Service.init(allocator);
    defer service.deinit();
    const source: Source = .{ .id = "existing", .source = .{ .kind = .file, .value = "list" }, .format = .domains };
    try service.add(std.testing.io, source, base);
    const original = service.sources.get(source.id).?;
    var replacement = source;
    replacement.name = "replacement";
    const added: Source = .{ .id = "added", .source = source.source, .format = .domains };
    var plan = service.prepare(std.testing.io, &.{ replacement, added }, base, .all) catch |err| {
        try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(source.id).?.snapshot.ptr);
        try std.testing.expect(service.sources.get(source.id).?.source.name == null);
        try std.testing.expectEqual(@as(u32, 1), service.sources.count());
        try std.testing.expect(service.contains("shared.test"));
        return err;
    };
    defer plan.deinit();
    plan.reserve(&service) catch |err| {
        try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(source.id).?.snapshot.ptr);
        try std.testing.expect(service.sources.get(source.id).?.source.name == null);
        try std.testing.expectEqual(@as(u32, 1), service.sources.count());
        try std.testing.expectEqual(@as(usize, 1), service.index.entries.get("shared.test").?);
        return err;
    };
    plan.commit(&service);
    try std.testing.expectEqual(@as(usize, 2), service.index.entries.get("shared.test").?);
}

test "every preparation allocation failure releases staging and preserves active sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "list", .data = "shared.test\n" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareWithFailingAllocator, .{base});
}

test "durable restart fetches first and falls back to compatible saved memberships" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    const source: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    var successful_at: ?i64 = null;
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "saved.test\n" });
    {
        var store = try Store.init(allocator, io, path);
        defer store.deinit();
        var service = Service.init(allocator);
        defer service.deinit();
        service.store = &store;
        try service.add(io, source, base);
        try std.testing.expect(service.contains("saved.test"));
        try std.testing.expect(service.health(source.id).?.state == .active);
        successful_at = service.health(source.id).?.last_success_at_ms;
    }
    try temporary.dir.deleteFile(io, "first");
    {
        var store = try Store.init(allocator, io, path);
        defer store.deinit();
        var service = Service.init(allocator);
        defer service.deinit();
        service.store = &store;
        try service.add(io, source, base);
        try std.testing.expect(service.contains("saved.test"));
        const status = service.health(source.id).?;
        try std.testing.expect(status.state == .degraded);
        try std.testing.expectEqualStrings("FileNotFound", status.last_error.?);
        try std.testing.expectEqual(successful_at, status.last_success_at_ms);
        try std.testing.expectEqual(@as(usize, 1), status.domain_count);
        try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "fresh.test\n" });
    }
    {
        var store = try Store.init(allocator, io, path);
        defer store.deinit();
        var service = Service.init(allocator);
        defer service.deinit();
        service.store = &store;
        try service.add(io, source, base);
        try std.testing.expect(service.health(source.id).?.state == .active);
        try std.testing.expect(service.contains("fresh.test"));
        try std.testing.expect(!service.contains("saved.test"));
    }
}

test "durable overlap deletion disable retention and successful empty snapshots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    var store = try Store.init(allocator, io, path);
    defer store.deinit();
    var service = Service.init(allocator);
    defer service.deinit();
    service.store = &store;
    var first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "common.test\nfirst.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "common.test\nsecond.test\n" });
    try service.add(io, first, base);
    try service.add(io, second, base);
    try service.remove(second.id);
    try std.testing.expect(service.contains("common.test"));
    try std.testing.expect(!service.contains("second.test"));
    try std.testing.expectEqual(@as(i64, 1), (try store.db.one(i64, "SELECT count(*) FROM lists", .{}, .{})).?);
    first.enabled = false;
    var disabled = try service.prepare(io, &.{first}, base, .none);
    defer disabled.deinit();
    try disabled.reserve(&service);
    disabled.commit(&service);
    try std.testing.expect(service.health(first.id).?.state == .disabled);
    try std.testing.expect(!service.contains("common.test"));
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "SELECT count(*) FROM list_domains", .{}, .{})).?);
    try temporary.dir.deleteFile(io, "first");
    first.enabled = true;
    var enabled = try service.prepare(io, &.{first}, base, .none);
    defer enabled.deinit();
    try enabled.reserve(&service);
    enabled.commit(&service);
    try std.testing.expect(service.contains("common.test"));
    try std.testing.expect(service.health(first.id).?.state == .degraded);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "new.test\n||unsupported.test^\n" });
    try service.refresh(first.id, io, base);
    try std.testing.expect(service.health(first.id).?.state == .degraded);
    try std.testing.expectEqualStrings("InvalidListLine", service.health(first.id).?.last_error.?);
    try std.testing.expect(service.contains("first.test"));
    try std.testing.expect(!service.contains("new.test"));
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "" });
    try service.refresh(first.id, io, base);
    try std.testing.expect(service.health(first.id).?.state == .active);
    try std.testing.expectEqual(@as(usize, 0), service.health(first.id).?.domain_count);
    try temporary.dir.deleteFile(io, "first");
    try service.refresh(first.id, io, base);
    try std.testing.expect(service.health(first.id).?.state == .degraded);
    try std.testing.expect(!service.contains("first.test"));
    try std.testing.expectEqual(@as(i64, 1), (try store.db.one(i64, "SELECT count(*) FROM lists", .{}, .{})).?);
    try std.testing.expectEqual(@as(i64, 0), (try store.db.one(i64, "SELECT count(*) FROM domains", .{}, .{})).?);
    var removed = try service.prepare(io, &.{}, base, .none);
    defer removed.deinit();
    try removed.reserve(&service);
    removed.commit(&service);
    try std.testing.expectEqual(@as(i64, 0), (try store.db.one(i64, "SELECT count(*) FROM lists", .{}, .{})).?);
}

test "durable snapshots reject changed location format security context and resolved base" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    var store = try Store.init(allocator, io, path);
    defer store.deinit();
    const source: Source = .{ .id = "same", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "saved.test\n" });
    {
        var service = Service.init(allocator);
        defer service.deinit();
        service.store = &store;
        try service.add(io, source, base);
    }
    try temporary.dir.deleteFile(io, "first");
    try temporary.dir.createDirPath(io, "other");
    const other = try temporary.dir.realPathFileAlloc(io, "other", allocator);
    defer allocator.free(other);
    for (0..6) |variant| {
        var changed = source;
        switch (variant) {
            0 => changed.source.value = "missing",
            1 => changed.format = .hosts,
            2 => changed.api_managed = true,
            3 => changed.access.allow_private_sources = true,
            4 => changed.access.file_root = base,
            5 => {},
            else => unreachable,
        }
        var service = Service.init(allocator);
        defer service.deinit();
        service.store = &store;
        try service.add(io, changed, if (variant == 5) other else base);
        try std.testing.expect(service.sources.get(source.id).?.source.enabled);
        try std.testing.expect(service.health(source.id).?.state == .unavailable);
        try std.testing.expect(service.health(source.id).?.last_error != null);
        try std.testing.expect(service.health(source.id).?.last_success_at_ms == null);
        try std.testing.expect(!service.contains("saved.test"));
    }
    var service = Service.init(allocator);
    defer service.deinit();
    service.store = &store;
    try service.add(io, source, base);
    try std.testing.expect(service.health(source.id).?.state == .degraded);
    try std.testing.expect(service.contains("saved.test"));
    const missing: Source = .{ .id = "new", .source = .{ .kind = .file, .value = "missing" }, .format = .domains };
    try service.add(io, missing, base);
    try std.testing.expect(service.health(missing.id).?.state == .unavailable);
    try std.testing.expect(service.sources.get(missing.id).?.source.enabled);
}

test "durable refresh-all rolls back DB and preserves unpublished RAM on persistence failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    var store = try Store.init(allocator, io, path);
    defer store.deinit();
    var service = Service.init(allocator);
    defer service.deinit();
    service.store = &store;
    const first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "old-first.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "old-second.test\n" });
    try service.add(io, first, base);
    try service.add(io, second, base);
    const original = service.sources.get(first.id).?;
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "new-first.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "new-second.test\n" });
    // Reject preparation of the second write. Unlike an aborting SQL trigger,
    // authorization failure does not leave a stepped statement whose finalize
    // repeats the expected error through the dependency's error logger.
    const c = @import("sqlite").c;
    const Authorizer = struct {
        fn authorize(context: ?*anyopaque, action: c_int, table: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
            const writes: *usize = @ptrCast(@alignCast(context.?));
            if (action == c.SQLITE_INSERT and table != null and std.mem.eql(u8, std.mem.span(table), "lists")) {
                writes.* += 1;
                if (writes.* == 2) return c.SQLITE_DENY;
            }
            return c.SQLITE_OK;
        }
    };
    var writes: usize = 0;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(store.db.db, Authorizer.authorize, &writes));
    defer _ = c.sqlite3_set_authorizer(store.db.db, null, null);
    if (service.prepare(io, &.{ first, second }, base, .all)) |prepared| {
        var unexpected = prepared;
        unexpected.deinit();
        return error.ExpectedPersistenceFailure;
    } else |err| {
        try std.testing.expect(err != error.OutOfMemory);
    }
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(first.id).?.snapshot.ptr);
    try std.testing.expectEqual(original.health.last_success_at_ms, service.health(first.id).?.last_success_at_ms);
    try std.testing.expect(service.contains("old-first.test"));
    try std.testing.expect(service.contains("old-second.test"));
    try std.testing.expect(!service.contains("new-first.test"));
    try std.testing.expectEqual(@as(i64, 0), (try store.db.one(i64, "SELECT count(*) FROM domains WHERE name LIKE 'new-%'", .{}, .{})).?);
    try std.testing.expectEqual(@as(usize, 2), writes);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(store.db.db, null, null));
    try temporary.dir.deleteFile(io, "first");
    try temporary.dir.deleteFile(io, "second");
    var recovered = try service.prepare(io, &.{ first, second }, base, .all);
    defer recovered.deinit();
    // Background preparation cannot publish health or memberships.
    try std.testing.expect(service.health(first.id).?.state == .active);
    try recovered.reserve(&service);
    recovered.commit(&service);
    try std.testing.expect(service.health(first.id).?.state == .degraded);
    try std.testing.expect(service.contains("old-first.test"));
    try std.testing.expect(service.contains("old-second.test"));
}
