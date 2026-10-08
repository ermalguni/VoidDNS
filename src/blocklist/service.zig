const std = @import("std");
const Source = @import("source.zig").Source;
const fetch = @import("fetch.zig");
const parse = @import("parse.zig");
const Index = @import("index.zig").Index;
const log = std.log.scoped(.blocklist);

/// Mutations run before serving, or under the caller's exclusive publication
/// lock. Queries borrow immutable state and perform a single RAM hash lookup.
pub const Service = struct {
    const Entry = struct {
        source: Source,
        snapshot: Index.Snapshot,
    };

    allocator: std.mem.Allocator,
    sources: std.StringHashMapUnmanaged(Entry) = .empty,
    index: Index,

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

    /// Definitions and snapshots are owned, including disabled definitions.
    pub fn add(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !void {
        try source.validate();
        if (self.sources.contains(source.id)) return error.DuplicateSourceId;
        var owned = try source.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        try self.sources.ensureUnusedCapacity(self.allocator, 1);
        const snapshot = try self.load(io, owned, base_dir);
        self.sources.putAssumeCapacityNoClobber(owned.id, .{ .source = owned, .snapshot = snapshot });
        self.report("added", owned, snapshot.len);
    }

    /// Replace metadata and content together, retaining the stable ID. Failed
    /// validation, fetch, parse, or allocation leaves the last known good entry.
    pub fn replace(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !void {
        try source.validate();
        const entry = self.sources.getPtr(source.id) orelse return error.SourceNotFound;
        var owned = try source.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const snapshot = try self.load(io, owned, base_dir);
        const old = entry.*;
        // Keep the hash table key allocation stable while replacing other fields.
        self.allocator.free(owned.id);
        owned.id = old.source.id;
        entry.* = .{ .source = owned, .snapshot = snapshot };
        self.index.release(old.snapshot);
        if (old.source.name) |name| self.allocator.free(name);
        self.allocator.free(old.source.source.value);
        self.report("replaced", owned, snapshot.len);
    }

    pub fn refresh(self: *Service, id: []const u8, io: std.Io, base_dir: []const u8) !void {
        const entry = self.sources.getPtr(id) orelse return error.SourceNotFound;
        const snapshot = try self.load(io, entry.source, base_dir);
        const old = entry.snapshot;
        entry.snapshot = snapshot;
        self.index.release(old);
        self.report("refreshed", entry.source, snapshot.len);
    }

    pub fn remove(self: *Service, id: []const u8) !void {
        var entry = (self.sources.fetchRemove(id) orelse return error.SourceNotFound).value;
        self.report("removed", entry.source, entry.snapshot.len);
        self.index.release(entry.snapshot);
        entry.source.deinit(self.allocator);
    }

    fn load(self: *Service, io: std.Io, source: Source, base_dir: []const u8) !Index.Snapshot {
        errdefer log.warn("source id={s} name={s}: import failed; published state unchanged", .{ source.id, source.name orelse "(unnamed)" });
        if (!source.enabled) return self.allocator.alloc([]const u8, 0);
        const contents = try fetch.load(self.allocator, io, source, base_dir);
        defer self.allocator.free(contents);
        var names = try parse.parse(self.allocator, contents, source.format);
        defer names.deinit();
        return self.index.acquire(&names);
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
