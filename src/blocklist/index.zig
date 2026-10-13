const std = @import("std");
const parse = @import("parse.zig");

/// Each source keeps only pointers to interned canonical names. The global hash
/// table owns one name allocation and a membership count, not one per source.
pub const Index = struct {
    pub const Snapshot = []const []const u8;

    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn contains(self: *const Index, canonical: []const u8) bool {
        return self.entries.contains(canonical);
    }

    /// All allocations precede mutation. Success consumes names' strings and
    /// empties its map; failure leaves both names and published index unchanged.
    /// names must use this index's allocator.
    pub fn acquire(self: *Index, names: *parse.Names) !Snapshot {
        const snapshot = try self.allocator.alloc([]const u8, names.entries.count());
        errdefer self.allocator.free(snapshot);
        try self.reserve(names.entries.count());
        self.acquireReserved(names, snapshot);
        return snapshot;
    }

    /// Reserve a conservative upper bound before publishing any source changes.
    /// Rehashing on failure is permitted; keys and membership counts are not.
    pub fn reserve(self: *Index, additional: u32) !void {
        if (additional == 0) return;
        const total = std.math.add(u32, self.entries.count(), additional) catch return error.OutOfMemory;
        try self.entries.ensureTotalCapacity(self.allocator, total);
    }

    /// Takes ownership of names without allocating. The caller provides the
    /// snapshot buffer and reserves capacity for every acquisition in the batch.
    pub fn acquireReserved(self: *Index, names: *parse.Names, snapshot: [][]const u8) void {
        std.debug.assert(snapshot.len == names.entries.count());
        var keys = names.entries.keyIterator();
        var i: usize = 0;
        while (keys.next()) |key| : (i += 1) {
            const entry = self.entries.getOrPutAssumeCapacity(key.*);
            if (entry.found_existing) {
                self.allocator.free(key.*);
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
            snapshot[i] = entry.key_ptr.*;
        }
        names.entries.clearRetainingCapacity();
        // The caller owns snapshot; names now owns only its temporary hash table.
    }

    /// Cannot fail. Release the previous snapshot only after acquiring its
    /// replacement, preserving common domains throughout the commit.
    pub fn release(self: *Index, snapshot: Snapshot) void {
        for (snapshot) |name| {
            const count = self.entries.getPtr(name).?;
            if (count.* == 1) {
                _ = self.entries.remove(name);
                self.allocator.free(name);
            } else {
                count.* -= 1;
            }
        }
        self.allocator.free(snapshot);
    }
};

test "overlapping source snapshots survive replacement and removal" {
    const allocator = std.testing.allocator;
    var index = Index.init(allocator);
    defer index.deinit();
    var first = try parse.parse(allocator, "common.test\nfirst.test\ncommon.test", .domains);
    defer first.deinit();
    const old = try index.acquire(&first);
    var second = try parse.parse(allocator, "common.test\nsecond.test", .domains);
    defer second.deinit();
    const other = try index.acquire(&second);
    var replacement = try parse.parse(allocator, "new.test", .domains);
    defer replacement.deinit();
    const fresh = try index.acquire(&replacement);
    index.release(old);
    try std.testing.expect(index.contains("common.test"));
    try std.testing.expect(!index.contains("first.test"));
    index.release(other);
    try std.testing.expect(!index.contains("common.test"));
    try std.testing.expect(index.contains("new.test"));
    index.release(fresh);
    try std.testing.expectEqual(@as(u32, 0), index.entries.count());
}

test "failed snapshot allocation preserves published and candidate names" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var index = Index.init(allocator);
    defer index.deinit();
    var first = try parse.parse(allocator, "old.test", .domains);
    defer first.deinit();
    const old = try index.acquire(&first);
    defer index.release(old);
    var replacement = try parse.parse(allocator, "new.test", .domains);
    defer replacement.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, index.acquire(&replacement));
    try std.testing.expect(index.contains("old.test"));
    try std.testing.expect(!index.contains("new.test"));
    try std.testing.expect(replacement.entries.contains("new.test"));
}
