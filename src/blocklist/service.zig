const std = @import("std");
const Source = @import("source.zig").Source;
const fetch = @import("fetch.zig");
const parse = @import("parse.zig");
const Index = @import("index.zig").Index;
const Store = @import("../lists/store.zig").Store;
const Policy = @import("refresh.zig").Policy;
const log = std.log.scoped(.blocklist);
var volatile_version = std.atomic.Value(u32).init(1);

/// Mutations run before serving, or under the caller's exclusive publication
/// lock. Queries borrow immutable state and perform a single RAM hash lookup.
pub const Service = struct {
    const Entry = struct {
        source: Source,
        snapshot: Index.Snapshot,
        health: Health,
        fingerprint: ?[64]u8 = null,
        version: ?[32]u8 = null,
        active_last_success_at_ms: ?i64 = null,
        schedule_policy: ?Policy = null,
        next_due_ms: ?i64 = null,
    };

    pub const Health = struct {
        state: enum { active, degraded, unavailable },
        last_error: ?[]const u8 = null,
        last_success_at_ms: ?i64 = null,
        /// Compatibility: domains currently contributing DNS memberships.
        domain_count: usize = 0,
        snapshot_domain_count: usize = 0,
        active_domain_count: usize = 0,
        last_attempt_at_ms: ?i64 = null,
        last_completed_at_ms: ?i64 = null,
        consecutive_failures: u32 = 0,
        next_refresh_at_ms: ?i64 = null,
        refreshing: bool = false,
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
            version: ?[32]u8 = null,
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
                        .health = if (change.health) |status| importHealth(status, old.health) else old.health,
                        .fingerprint = change.fingerprint,
                        .version = if (change.snapshot != null) change.version else old.version,
                        .active_last_success_at_ms = if (change.snapshot != null)
                            (if (change.source.enabled) change.health.?.last_success_at_ms else null)
                        else
                            old.active_last_success_at_ms,
                        .schedule_policy = if (change.health != null and !old.health.refreshing) null else old.schedule_policy,
                        .next_due_ms = if (change.health != null and !old.health.refreshing) null else old.next_due_ms,
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
                        .version = change.version,
                        .active_last_success_at_ms = if (change.source.enabled) change.health.?.last_success_at_ms else null,
                    });
                }
            }
            for (self.removals.items) |id| {
                var old = service.sources.fetchRemove(id).?.value;
                service.index.release(old.snapshot);
                old.source.deinit(self.allocator);
            }
            if (self.changed()) service.generation +%= 1;
            self.committed = true;
        }
    };

    allocator: std.mem.Allocator,
    sources: std.StringHashMapUnmanaged(Entry) = .empty,
    index: Index,
    generation: u64 = 1,
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

    /// Called under the publication guard after startup or configuration changes.
    /// The DNS enabled flag does not control background snapshot maintenance.
    pub fn initializeSchedules(self: *Service, io: std.Io, policy: Policy) void {
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            if (entry.schedule_policy) |previous| {
                if (std.meta.eql(previous, policy)) continue;
            }
            entry.schedule_policy = policy;
            schedule(entry, io, policy);
        }
    }

    /// Returns a borrowed ID only when its earliest monotonic deadline is due.
    pub fn nextDue(self: *const Service, io: std.Io) ?[]const u8 {
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        var earliest: ?i64 = null;
        var id: ?[]const u8 = null;
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            if (entry.health.refreshing) continue;
            const due = entry.next_due_ms orelse continue;
            if (due > now) continue;
            if (earliest == null or due < earliest.? or
                (due == earliest.? and std.mem.lessThan(u8, entry.source.id, id.?)))
            {
                earliest = due;
                id = entry.source.id;
            }
        }
        return id;
    }

    pub fn beginRefresh(self: *Service, io: std.Io, selection: Refresh) void {
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            if (!selected(selection, entry.source.id)) continue;
            entry.health.refreshing = true;
            entry.health.last_attempt_at_ms = now;
            entry.health.next_refresh_at_ms = null;
            entry.next_due_ms = null;
        }
    }

    /// Publish completion under the guard, including preparation/storage errors.
    /// A durable fallback is useful data, but still a failed refresh attempt.
    pub fn finishRefresh(self: *Service, io: std.Io, selection: Refresh, failure: ?anyerror, policy: Policy) void {
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        var entries = self.sources.valueIterator();
        while (entries.next()) |entry| {
            if (!selected(selection, entry.source.id)) continue;
            if (failure) |err| {
                entry.health.last_error = @errorName(err);
                entry.health.state = if (entry.health.last_success_at_ms != null) .degraded else .unavailable;
            }
            entry.health.last_completed_at_ms = now;
            entry.health.refreshing = false;
            if (failure != null or entry.health.state != .active) {
                entry.health.consecutive_failures +|= 1;
            } else {
                entry.health.consecutive_failures = 0;
            }
            entry.schedule_policy = policy;
            schedule(entry, io, policy);
        }
    }

    fn selected(selection: Refresh, id: []const u8) bool {
        return switch (selection) {
            .none => false,
            .all => true,
            .one => |wanted| std.mem.eql(u8, wanted, id),
        };
    }

    fn schedule(entry: *Entry, io: std.Io, policy: Policy) void {
        entry.next_due_ms = null;
        entry.health.next_refresh_at_ms = null;
        if (!policy.enabled or entry.health.refreshing) return;
        const entropy_value = if (policy.jitter_percent != 0) blk: {
            var entropy: [8]u8 = undefined;
            io.random(&entropy);
            break :blk std.mem.readInt(u64, &entropy, .little);
        } else @as(u64, 0);
        const delay_ms: i64 = @intCast(@import("refresh.zig").delaySeconds(
            policy,
            entry.health.consecutive_failures,
            entropy_value,
        ) * std.time.ms_per_s);
        const real_now = std.Io.Clock.real.now(io).toMilliseconds();
        // Import completion can precede schedule initialization at startup.
        const elapsed = if (entry.health.last_completed_at_ms) |completed|
            @max(0, real_now -| completed)
        else
            0;
        const remaining = @max(0, delay_ms -| elapsed);
        entry.next_due_ms = std.Io.Clock.awake.now(io).toMilliseconds() +| remaining;
        entry.health.next_refresh_at_ms = real_now +| remaining;
    }

    fn retainRuntime(status: Health, previous: Health) Health {
        var result = status;
        result.last_attempt_at_ms = previous.last_attempt_at_ms;
        result.last_completed_at_ms = previous.last_completed_at_ms;
        result.consecutive_failures = previous.consecutive_failures;
        result.next_refresh_at_ms = previous.next_refresh_at_ms;
        result.refreshing = previous.refreshing;
        return result;
    }

    fn importHealth(status: Health, previous: Health) Health {
        if (previous.refreshing) return retainRuntime(status, previous);
        var result = status;
        result.consecutive_failures = if (status.state == .active) 0 else previous.consecutive_failures +| 1;
        return result;
    }

    fn retainContent(status: Health, previous: Health, active_count: usize) Health {
        var result = status;
        result.last_success_at_ms = status.last_success_at_ms orelse previous.last_success_at_ms;
        result.state = if (result.last_success_at_ms != null) .degraded else .unavailable;
        if (status.last_success_at_ms == null) result.snapshot_domain_count = previous.snapshot_domain_count;
        result.active_domain_count = active_count;
        result.domain_count = active_count;
        return result;
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
            const explicit_refresh = switch (requested) {
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
            if (content_changed or explicit_refresh) {
                var loaded = try self.loadNames(io, source, base_dir, if (transaction) |*tx| tx else null, fingerprint_value);
                // Never publish stale RAM from a different content/security context.
                if (source.enabled and old != null and old.?.source.enabled and
                    sameLocation(source, old.?.source) and
                    sameFingerprint(fingerprint_value, old.?.fingerprint) and
                    loaded.health.state != .active)
                {
                    loaded.names.deinit();
                    loaded.health = retainContent(loaded.health, old.?.health, old.?.snapshot.len);
                } else {
                    if (!source.enabled) {
                        loaded.names.deinit();
                        loaded.names = .{ .allocator = self.allocator };
                    }
                    change.names = loaded.names;
                    change.snapshot = try Index.prepareSnapshot(self.allocator, &change.names.?);
                    plan.incoming_names = std.math.add(u32, plan.incoming_names, change.names.?.entries.count()) catch return error.OutOfMemory;
                }
                change.health = loaded.health;
                change.version = loaded.version;
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
        const loaded = try self.load(io, owned, base_dir, null);
        self.sources.putAssumeCapacityNoClobber(owned.id, .{
            .source = owned,
            .snapshot = loaded.snapshot,
            .health = loaded.health,
            .fingerprint = loaded.fingerprint,
            .version = loaded.version,
            .active_last_success_at_ms = if (owned.enabled) loaded.health.last_success_at_ms else null,
        });
        self.generation +%= 1;
        self.report("added", owned, loaded.snapshot.len);
    }

    /// Replace metadata and content together, retaining the stable ID. Durable
    /// imports expose degraded/unavailable health on fetch or parse failure.
    pub fn replace(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !void {
        try source.validate();
        const entry = self.sources.getPtr(source.id) orelse return error.SourceNotFound;
        var owned = try source.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const loaded = self.load(io, owned, base_dir, entry.*) catch |err| {
            directFailure(entry, io, err);
            return err;
        };
        const old = entry.*;
        // Keep the hash table key allocation stable while replacing other fields.
        self.allocator.free(owned.id);
        owned.id = old.source.id;
        entry.* = .{
            .source = owned,
            .snapshot = loaded.snapshot,
            .health = importHealth(loaded.health, old.health),
            .fingerprint = loaded.fingerprint,
            .version = loaded.version,
            .active_last_success_at_ms = if (loaded.reused)
                old.active_last_success_at_ms
            else if (owned.enabled)
                loaded.health.last_success_at_ms
            else
                null,
            .schedule_policy = old.schedule_policy,
        };
        if (entry.schedule_policy) |policy| schedule(entry, io, policy);
        self.generation +%= 1;
        if (!loaded.reused) self.index.release(old.snapshot);
        if (old.source.name) |name| self.allocator.free(name);
        self.allocator.free(old.source.source.value);
        if (old.source.access.file_root) |root| self.allocator.free(root);
        self.report("replaced", owned, loaded.snapshot.len);
    }

    pub fn refresh(self: *Service, id: []const u8, io: std.Io, base_dir: []const u8) !void {
        const entry = self.sources.getPtr(id) orelse return error.SourceNotFound;
        const loaded = self.load(io, entry.source, base_dir, entry.*) catch |err| {
            directFailure(entry, io, err);
            return err;
        };
        const old = entry.snapshot;
        entry.snapshot = loaded.snapshot;
        entry.health = importHealth(loaded.health, entry.health);
        entry.fingerprint = loaded.fingerprint;
        entry.version = loaded.version;
        if (!loaded.reused) entry.active_last_success_at_ms = if (entry.source.enabled) loaded.health.last_success_at_ms else null;
        self.generation +%= 1;
        if (!loaded.reused) self.index.release(old);
        if (entry.schedule_policy) |policy| schedule(entry, io, policy);
        self.report("refreshed", entry.source, loaded.snapshot.len);
    }

    fn directFailure(entry: *Entry, io: std.Io, failure: anyerror) void {
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        entry.health.state = if (entry.health.last_success_at_ms != null) .degraded else .unavailable;
        entry.health.last_error = @errorName(failure);
        entry.health.last_attempt_at_ms = now;
        entry.health.last_completed_at_ms = now;
        entry.health.consecutive_failures +|= 1;
        entry.health.refreshing = false;
        if (entry.schedule_policy) |policy| schedule(entry, io, policy);
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
        self.generation +%= 1;
    }

    const Loaded = struct { names: parse.Names, health: Health, version: ?[32]u8 = null };
    const LoadedSnapshot = struct { snapshot: Index.Snapshot, health: Health, fingerprint: ?[64]u8, version: ?[32]u8, reused: bool = false };

    fn load(self: *Service, io: std.Io, source: Source, base_dir: []const u8, previous: ?Entry) !LoadedSnapshot {
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
        if (previous) |old| {
            if (source.enabled and old.source.enabled and sameLocation(source, old.source) and
                sameFingerprint(key, old.fingerprint) and loaded.health.state != .active)
            {
                if (transaction) |*tx| try tx.commit();
                return .{
                    .snapshot = old.snapshot,
                    .health = retainContent(loaded.health, old.health, old.snapshot.len),
                    .fingerprint = key,
                    .version = old.version,
                    .reused = true,
                };
            }
        }
        // Disabled sources retain only durable data and health, not DNS names.
        if (!source.enabled) {
            loaded.names.deinit();
            loaded.names = .{ .allocator = self.allocator };
        }
        const snapshot = try self.index.acquire(&loaded.names);
        errdefer self.index.release(snapshot);
        if (transaction) |*tx| try tx.commit();
        return .{ .snapshot = snapshot, .health = loaded.health, .fingerprint = key, .version = loaded.version };
    }

    fn loadNames(self: *const Service, io: std.Io, source: Source, base_dir: []const u8, transaction: ?*Store.Transaction, key: ?[64]u8) !Loaded {
        const attempted = std.Io.Clock.real.now(io).toMilliseconds();
        var loaded = try self.importNames(io, source, base_dir, transaction, key);
        loaded.health.last_attempt_at_ms = attempted;
        loaded.health.last_completed_at_ms = std.Io.Clock.real.now(io).toMilliseconds();
        loaded.health.consecutive_failures = if (loaded.health.state == .active) 0 else 1;
        loaded.health.snapshot_domain_count = loaded.names.entries.count();
        loaded.health.active_domain_count = if (source.enabled) loaded.names.entries.count() else 0;
        loaded.health.domain_count = loaded.health.active_domain_count;
        return loaded;
    }

    fn importNames(self: *const Service, io: std.Io, source: Source, base_dir: []const u8, transaction: ?*Store.Transaction, key: ?[64]u8) !Loaded {
        const tx = transaction orelse {
            const names = try self.fetchNames(io, source, base_dir);
            const at_ms = std.Io.Clock.real.now(io).toMilliseconds();
            var version: [32]u8 = undefined;
            _ = try std.fmt.bufPrint(&version, "{x:0>16}{x:0>16}", .{ @as(u64, @intCast(@max(0, at_ms))), @as(u64, volatile_version.fetchAdd(1, .monotonic)) });
            return .{ .names = names, .health = .{ .state = .active, .domain_count = names.entries.count(), .last_success_at_ms = at_ms }, .version = version };
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
            return .{ .names = saved.names, .version = saved.version, .health = .{
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

test "disabled sources import health without acquiring DNS memberships" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "disabled", .data = "0.0.0.0 disabled.test\n" });
    var service = Service.init(allocator);
    defer service.deinit();
    const source: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "disabled" }, .format = .hosts };
    try service.add(io, source, base);
    try std.testing.expectEqual(@as(u32, 1), service.sources.count());
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());
    const status = service.health(source.id).?;
    try std.testing.expect(status.state == .active);
    try std.testing.expectEqual(@as(usize, 1), status.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 0), status.active_domain_count);
    try std.testing.expectEqual(@as(usize, 0), status.domain_count);
    try std.testing.expect(status.last_attempt_at_ms != null);
    try std.testing.expect(status.last_completed_at_ms != null);
    var invalid = source;
    invalid.id = "";
    try std.testing.expectError(error.InvalidSourceId, service.add(io, invalid, base));
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

test "explicit one and all refreshes are transactional and import disabled sources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "old.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second", .data = "second.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "disabled", .data = "disabled.test\n" });
    const first: Source = .{ .id = "first", .source = .{ .kind = .file, .value = "first" }, .format = .domains };
    const second: Source = .{ .id = "second", .source = .{ .kind = .file, .value = "second" }, .format = .domains };
    const disabled: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "disabled" }, .format = .domains };
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
    try temporary.dir.writeFile(io, .{ .sub_path = "disabled", .data = "disabled-one.test\n" });
    var disabled_refresh = try service.prepare(io, &definitions, base, .{ .one = "disabled" });
    defer disabled_refresh.deinit();
    try std.testing.expect(disabled_refresh.changed());
    try disabled_refresh.reserve(&service);
    disabled_refresh.commit(&service);
    try std.testing.expect(!service.contains("disabled-one.test"));
    try std.testing.expectEqual(@as(usize, 1), service.health(disabled.id).?.snapshot_domain_count);
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
    try std.testing.expect(service.health(first.id).?.state == .active);
    try std.testing.expectEqual(@as(usize, 2), service.health(first.id).?.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 0), service.health(first.id).?.active_domain_count);
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

test "disabled durable startup manual and scheduled imports never acquire DNS memberships" {
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
    var source: Source = .{ .id = "disabled", .enabled = false, .source = .{ .kind = .file, .value = "list" }, .format = .domains };
    const policy: Policy = .{ .interval_seconds = 60, .jitter_percent = 0, .retry_initial_seconds = 5, .retry_max_seconds = 20 };
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "startup.test\n" });
    try service.add(io, source, base);
    service.initializeSchedules(io, policy);
    try std.testing.expect(service.health(source.id).?.state == .active);
    try std.testing.expectEqual(@as(usize, 1), service.health(source.id).?.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 0), service.health(source.id).?.active_domain_count);
    try std.testing.expect(service.health(source.id).?.next_refresh_at_ms != null);
    try std.testing.expectEqual(@as(i64, 1), (try store.db.one(i64, "SELECT count(*) FROM list_domains", .{}, .{})).?);
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());

    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "manual.test\nsecond.test\n" });
    const selection: Service.Refresh = .{ .one = source.id };
    service.beginRefresh(io, selection);
    const attempted = service.health(source.id).?.last_attempt_at_ms;
    var manual = try service.prepare(io, &.{source}, base, selection);
    defer manual.deinit();
    try manual.reserve(&service);
    manual.commit(&service);
    try std.testing.expect(service.health(source.id).?.refreshing);
    try std.testing.expectEqual(attempted, service.health(source.id).?.last_attempt_at_ms);
    try std.testing.expect(service.health(source.id).?.next_refresh_at_ms == null);
    service.finishRefresh(io, selection, null, policy);
    const successful = service.health(source.id).?;
    const version = service.sources.get(source.id).?.version;
    try std.testing.expectEqual(@as(usize, 2), successful.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 0), successful.domain_count);
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "SELECT count(*) FROM list_domains", .{}, .{})).?);
    try std.testing.expect(!service.contains("manual.test"));

    // An automatic attempt uses the same import path even while DNS-disabled.
    service.sources.getPtr(source.id).?.next_due_ms = std.Io.Clock.awake.now(io).toMilliseconds() - 1;
    try std.testing.expectEqualStrings(source.id, service.nextDue(io).?);
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "partial.test\n||invalid.test^\n" });
    service.beginRefresh(io, selection);
    try std.testing.expect(service.nextDue(io) == null);
    var scheduled = try service.prepare(io, &.{source}, base, selection);
    defer scheduled.deinit();
    try scheduled.reserve(&service);
    scheduled.commit(&service);
    service.finishRefresh(io, selection, null, policy);
    const failed = service.health(source.id).?;
    try std.testing.expect(failed.state == .degraded);
    try std.testing.expectEqualStrings("InvalidListLine", failed.last_error.?);
    try std.testing.expectEqual(successful.last_success_at_ms, failed.last_success_at_ms);
    try std.testing.expectEqual(@as(u32, 1), failed.consecutive_failures);
    try std.testing.expectEqual(@as(usize, 2), failed.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 0), failed.active_domain_count);
    try std.testing.expectEqualDeep(version, service.sources.get(source.id).?.version);
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "SELECT count(*) FROM list_domains", .{}, .{})).?);
    try std.testing.expectEqual(@as(i64, 0), (try store.db.one(i64, "SELECT count(*) FROM domains WHERE name = 'partial.test'", .{}, .{})).?);
    try std.testing.expect(failed.next_refresh_at_ms.? - failed.last_completed_at_ms.? >= 5000);

    // Enabling after the source disappears proves the disabled refresh persisted.
    try temporary.dir.deleteFile(io, "list");
    source.enabled = true;
    var enabled = try service.prepare(io, &.{source}, base, .none);
    defer enabled.deinit();
    try enabled.reserve(&service);
    enabled.commit(&service);
    try std.testing.expect(service.contains("manual.test"));
    try std.testing.expect(service.contains("second.test"));
    try std.testing.expect(!service.contains("startup.test"));
    try std.testing.expect(!service.contains("partial.test"));
    try std.testing.expectEqual(@as(usize, 2), service.health(source.id).?.active_domain_count);
}

test "global policy applies to all schedules and metadata preserves deadlines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "scheduled.test\n" });
    var service = Service.init(allocator);
    defer service.deinit();
    var first: Source = .{
        .id = "first",
        .enabled = false,
        .source = .{ .kind = .file, .value = "list" },
        .format = .domains,
    };
    const second: Source = .{
        .id = "second",
        .enabled = false,
        .source = first.source,
        .format = .domains,
    };
    var defaults: Policy = .{ .interval_seconds = 60, .jitter_percent = 0, .retry_initial_seconds = 5, .retry_max_seconds = 20 };
    try service.add(io, first, base);
    try service.add(io, second, base);
    service.initializeSchedules(io, defaults);
    const original = service.sources.get(first.id).?;
    try std.testing.expect(original.next_due_ms != null);
    try std.testing.expect(service.sources.get(second.id).?.next_due_ms != null);
    service.initializeSchedules(io, defaults);
    try std.testing.expectEqual(original.next_due_ms, service.sources.get(first.id).?.next_due_ms);
    defaults.interval_seconds = 120;
    service.initializeSchedules(io, defaults);
    try std.testing.expect(service.sources.get(first.id).?.next_due_ms.? >= original.next_due_ms.? + 59000);
    try std.testing.expect(service.sources.get(second.id).?.next_due_ms.? >= original.next_due_ms.? + 59000);
    try std.testing.expectEqual(@as(u32, 120), service.sources.get(first.id).?.schedule_policy.?.interval_seconds);
    try std.testing.expectEqual(@as(u32, 120), service.sources.get(second.id).?.schedule_policy.?.interval_seconds);

    // Source metadata and global schedule changes must not fetch missing files.
    try temporary.dir.deleteFile(io, "list");
    first.name = "Renamed";
    var metadata = try service.prepare(io, &.{ first, second }, base, .none);
    defer metadata.deinit();
    try std.testing.expect(metadata.changes.items[0].health == null);
    try metadata.reserve(&service);
    metadata.commit(&service);
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(first.id).?.snapshot.ptr);
    try std.testing.expectEqual(original.health.last_attempt_at_ms, service.health(first.id).?.last_attempt_at_ms);
    service.sources.getPtr(first.id).?.next_due_ms = 0;
    defaults.interval_seconds = 180;
    service.initializeSchedules(io, defaults);
    try std.testing.expect(service.sources.get(first.id).?.next_due_ms.? > 0);
    try std.testing.expectEqual(@as(u32, 180), service.sources.get(first.id).?.schedule_policy.?.interval_seconds);

    // Due selection uses monotonic runtime state, not the displayed wall clock.
    service.sources.getPtr(first.id).?.next_due_ms = std.Io.Clock.awake.now(io).toMilliseconds() - 1;
    service.sources.getPtr(first.id).?.health.next_refresh_at_ms = std.math.maxInt(i64);
    try std.testing.expectEqualStrings(first.id, service.nextDue(io).?);
    const selection: Service.Refresh = .{ .one = first.id };
    service.beginRefresh(io, selection);
    try std.testing.expect(service.health(first.id).?.refreshing);
    try std.testing.expect(service.health(first.id).?.next_refresh_at_ms == null);
    try std.testing.expect(service.nextDue(io) == null);
    const attempted = service.health(first.id).?.last_attempt_at_ms;
    try std.testing.expectError(error.FileNotFound, service.prepare(io, &.{ first, second }, base, selection));
    service.finishRefresh(io, selection, error.FileNotFound, defaults);
    const failed = service.health(first.id).?;
    try std.testing.expect(!failed.refreshing);
    try std.testing.expectEqual(attempted, failed.last_attempt_at_ms);
    try std.testing.expect(failed.state == .degraded);
    try std.testing.expectEqualStrings("FileNotFound", failed.last_error.?);
    try std.testing.expectEqual(original.health.last_success_at_ms, failed.last_success_at_ms);
    try std.testing.expectEqual(@as(u32, 1), failed.consecutive_failures);
    try std.testing.expect(service.sources.get(second.id).?.health.consecutive_failures == 0);
    try std.testing.expectEqual(original.snapshot.ptr, service.sources.get(first.id).?.snapshot.ptr);

    service.beginRefresh(io, selection);
    service.finishRefresh(io, selection, error.AccessDenied, defaults);
    try std.testing.expectEqual(@as(u32, 2), service.health(first.id).?.consecutive_failures);
    service.sources.getPtr(first.id).?.health.consecutive_failures = std.math.maxInt(u32);
    service.beginRefresh(io, selection);
    service.finishRefresh(io, selection, error.AccessDenied, defaults);
    try std.testing.expectEqual(std.math.maxInt(u32), service.health(first.id).?.consecutive_failures);

    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "recovered.test\n" });
    service.beginRefresh(io, selection);
    var recovered = try service.prepare(io, &.{ first, second }, base, selection);
    defer recovered.deinit();
    try recovered.reserve(&service);
    recovered.commit(&service);
    try std.testing.expect(service.health(first.id).?.refreshing);
    service.finishRefresh(io, selection, null, defaults);
    try std.testing.expectEqual(@as(u32, 0), service.health(first.id).?.consecutive_failures);
    try std.testing.expect(service.health(first.id).?.last_error == null);
    try std.testing.expectEqual(@as(u32, 0), service.index.entries.count());

    defaults.enabled = false;
    service.initializeSchedules(io, defaults);
    try std.testing.expect(service.health(first.id).?.next_refresh_at_ms == null);
    try std.testing.expect(service.health(second.id).?.next_refresh_at_ms == null);
    try std.testing.expect(service.nextDue(io) == null);
}

test "failed refresh retains active RAM while reporting newer compatible durable snapshot" {
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
    var source: Source = .{ .id = "source", .source = .{ .kind = .file, .value = "list" }, .format = .domains };
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "active.test\n" });
    try service.add(io, source, base);
    const original = service.sources.get(source.id).?;
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "durable.test\nsecond.test\n" });
    var saved_at: ?i64 = null;
    {
        // Durable preparation may complete without subsequent RAM publication.
        var unpublished = try service.prepare(io, &.{source}, base, .all);
        defer unpublished.deinit();
        saved_at = unpublished.changes.items[0].health.?.last_success_at_ms;
    }
    try std.testing.expect(service.contains("active.test"));
    try std.testing.expect(!service.contains("durable.test"));
    try temporary.dir.writeFile(io, .{ .sub_path = "list", .data = "partial.test\n||invalid.test^\n" });
    const selection: Service.Refresh = .{ .one = source.id };
    service.beginRefresh(io, selection);
    var fallback = try service.prepare(io, &.{source}, base, selection);
    defer fallback.deinit();
    try std.testing.expect(fallback.changes.items[0].snapshot == null);
    try fallback.reserve(&service);
    fallback.commit(&service);
    service.finishRefresh(io, selection, null, .{});
    const current = service.sources.get(source.id).?;
    try std.testing.expectEqual(original.snapshot.ptr, current.snapshot.ptr);
    try std.testing.expectEqualDeep(original.version, current.version);
    try std.testing.expectEqual(original.active_last_success_at_ms, current.active_last_success_at_ms);
    try std.testing.expectEqual(saved_at, current.health.last_success_at_ms);
    try std.testing.expectEqual(@as(usize, 2), current.health.snapshot_domain_count);
    try std.testing.expectEqual(@as(usize, 1), current.health.active_domain_count);
    try std.testing.expectEqual(@as(usize, 1), current.health.domain_count);
    try std.testing.expect(current.health.state == .degraded);
    try std.testing.expectEqual(@as(u32, 1), current.health.consecutive_failures);
    try std.testing.expect(service.contains("active.test"));
    try std.testing.expect(!service.contains("durable.test"));

    // A changed location cannot retain memberships from the old fingerprint.
    source.source.value = "missing";
    var incompatible = try service.prepare(io, &.{source}, base, .none);
    defer incompatible.deinit();
    try incompatible.reserve(&service);
    incompatible.commit(&service);
    try std.testing.expect(service.health(source.id).?.state == .unavailable);
    try std.testing.expect(service.health(source.id).?.last_success_at_ms == null);
    try std.testing.expect(service.sources.get(source.id).?.active_last_success_at_ms == null);
    try std.testing.expect(!service.contains("active.test"));
}
