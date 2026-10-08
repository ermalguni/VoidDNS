const std = @import("std");
const domain = @import("domain.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    blocks: std.StringHashMapUnmanaged(void) = .empty,
    allows: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.freeSet(&self.blocks);
        self.freeSet(&self.allows);
        self.* = undefined;
    }

    pub fn block(self: *Store, text: []const u8) !void {
        try self.insert(&self.blocks, text);
    }

    pub fn allow(self: *Store, text: []const u8) !void {
        try self.insert(&self.allows, text);
    }

    pub fn isBlocked(self: *const Store, canonical: []const u8) bool {
        return self.blocks.contains(canonical);
    }

    pub fn isAllowed(self: *const Store, canonical: []const u8) bool {
        return self.allows.contains(canonical);
    }

    fn insert(self: *Store, set: *std.StringHashMapUnmanaged(void), text: []const u8) !void {
        var buffer: [253]u8 = undefined;
        const canonical = try domain.normalize(text, &buffer);
        if (set.contains(canonical)) return;
        const owned = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(owned);
        try set.put(self.allocator, owned, {});
    }

    fn freeSet(self: *Store, set: *std.StringHashMapUnmanaged(void)) void {
        var keys = set.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        set.deinit(self.allocator);
    }
};

test "explicit lists normalize deduplicate and remain independent" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.block("EXAMPLE.test.");
    try store.block("example.test");
    try store.allow("Example.Test");
    try std.testing.expectEqual(@as(u32, 1), store.blocks.count());
    try std.testing.expect(store.isBlocked("example.test"));
    try std.testing.expect(store.isAllowed("example.test"));
    try std.testing.expect(!store.isBlocked("child.example.test"));
    try std.testing.expectError(error.InvalidDomain, store.allow("*.test"));
}
