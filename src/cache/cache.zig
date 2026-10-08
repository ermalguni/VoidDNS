const std = @import("std");
const Key = @import("key.zig");
const Entry = @import("entry.zig");
const Cache = @This();
const log = std.log.scoped(.cache);

allocator: std.mem.Allocator,
slots: []?Entry,

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Cache {
    const slots = try allocator.alloc(?Entry, capacity);
    @memset(slots, null);
    log.info("initialized slots={d}", .{capacity});
    return .{ .allocator = allocator, .slots = slots };
}

pub fn deinit(self: *Cache) void {
    for (self.slots) |slot| {
        if (slot) |entry| entry.deinit(self.allocator);
    }
    self.allocator.free(self.slots);
    log.debug("deinitialized", .{});
}

fn slotFor(self: *Cache, k: []const u8) *?Entry {
    return &self.slots[std.hash.Wyhash.hash(0, k) % self.slots.len];
}

pub fn get(self: *Cache, query: []const u8, now: i64, out: []u8) ?[]const u8 {
    const k = Key.fromQuery(query) orelse {
        log.debug("lookup bypass: unsupported query bytes={d}", .{query.len});
        return null;
    };
    const query_id = std.mem.readInt(u16, query[0..2], .big);
    if (self.slots.len == 0) {
        log.debug("lookup bypass: disabled id={d}", .{query_id});
        return null;
    }

    const slot = self.slotFor(k);
    const entry = slot.* orelse {
        log.debug("miss id={d}: empty slot", .{query_id});
        return null;
    };
    const elapsed = now - entry.inserted;

    if (elapsed < 0 or elapsed >= entry.lifetime) {
        log.debug("miss id={d}: expired slot age={d}s ttl={d}s", .{
            query_id, elapsed, entry.lifetime,
        });
        entry.deinit(self.allocator);
        slot.* = null;
        return null;
    }

    if (!entry.matches(k)) {
        log.debug("miss id={d}: slot contains another key", .{query_id});
        return null;
    }
    if (out.len < entry.packet_len) {
        log.debug("lookup bypass id={d}: output buffer too small", .{query_id});
        return null;
    }

    const response = entry.replay(query_id, @intCast(elapsed), out);
    log.debug("hit id={d} bytes={d} remaining={d}s", .{
        query_id, response.len, @as(i64, entry.lifetime) - elapsed,
    });
    return response;
}

// k must be saved before resolution: the response overwrites the query buffer.
pub fn put(self: *Cache, k: []const u8, response: []const u8, now: i64) !void {
    if (self.slots.len == 0) {
        log.debug("insertion bypass: disabled", .{});
        return;
    }

    const entry = try Entry.init(self.allocator, k, response, now) orelse return;

    const slot = self.slotFor(k);
    if (slot.*) |old| {
        log.debug("replacing occupied slot old_bytes={d}", .{old.packet_len});
        old.deinit(self.allocator);
    }

    slot.* = entry;
}
