const std = @import("std");
const Key = @import("key.zig");
const Entry = @import("entry.zig");
const Cache = @This();
const log = std.log.scoped(.cache);

allocator: std.mem.Allocator,
slots: []?Entry,
min_positive_ttl_seconds: u32 = 0,

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

/// Runtime mutex must be held by callers while inspecting or clearing slots.
pub fn occupied(self: *const Cache) usize {
    var count: usize = 0;
    for (self.slots) |slot| if (slot != null) {
        count += 1;
    };
    return count;
}

pub fn clear(self: *Cache) void {
    for (self.slots) |*slot| {
        if (slot.*) |entry| entry.deinit(self.allocator);
        slot.* = null;
    }
}

fn slotFor(self: *Cache, k: []const u8) *?Entry {
    return &self.slots[@intCast(std.hash.Wyhash.hash(0, k) % self.slots.len)];
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

    const entry = try Entry.init(self.allocator, k, response, now, self.min_positive_ttl_seconds) orelse return;

    const slot = self.slotFor(k);
    if (slot.*) |old| {
        log.debug("replacing occupied slot old_bytes={d}", .{old.packet_len});
        old.deinit(self.allocator);
    }

    slot.* = entry;
}

test "positive minimum extends reuse without extending original record TTLs" {
    const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x04home\x04test\x00\x00\x01\x00\x01";
    const response = "\x12\x34\x81\x80\x00\x01\x00\x02\x00\x00\x00\x00" ++
        query[12..] ++
        "\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x0a\x00\x04\xc0\x00\x02\x01" ++
        "\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x14\x00\x04\xc0\x00\x02\x02";
    for ([_]u32{ 0, 5, 30, std.math.maxInt(u32) }) |minimum| {
        var cache = try Cache.init(std.testing.allocator, 1);
        defer cache.deinit();
        cache.min_positive_ttl_seconds = minimum;
        try cache.put(Key.fromQuery(query).?, response, 100);
        var out: [512]u8 = undefined;
        for ([_]u32{ 0, 5, 10, 20 }) |age| {
            if (age >= @max(@as(u32, 10), minimum)) continue;
            const replay = cache.get(query, 100 + @as(i64, age), &out).?;
            try std.testing.expectEqual(@as(u32, 10) -| age, std.mem.readInt(u32, replay[query.len + 6 ..][0..4], .big));
            try std.testing.expectEqual(@as(u32, 20) -| age, std.mem.readInt(u32, replay[query.len + 22 ..][0..4], .big));
        }
        const lifetime: i64 = @max(@as(u32, 10), minimum);
        const last = cache.get(query, 100 + lifetime - 1, &out).?;
        try std.testing.expectEqual(@as(u32, 10) -| @as(u32, @intCast(lifetime - 1)), std.mem.readInt(u32, last[query.len + 6 ..][0..4], .big));
        try std.testing.expect(cache.get(query, 100 + lifetime, &out) == null);
    }
}

test "positive minimum never makes zero TTL packets cacheable" {
    const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x04home\x04test\x00\x00\x01\x00\x01";
    const response = "\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" ++
        query[12..] ++
        "\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04\xc0\x00\x02\x01";
    var cache = try Cache.init(std.testing.allocator, 1);
    defer cache.deinit();
    cache.min_positive_ttl_seconds = std.math.maxInt(u32);
    try cache.put(Key.fromQuery(query).?, response, 0);
    try std.testing.expectEqual(@as(usize, 0), cache.occupied());
}

test "positive minimum leaves NXDOMAIN and NODATA SOA lifetimes unchanged including CNAME chains" {
    const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x04home\x04test\x00\x00\x01\x00\x01";
    for ([_]u32{ 0, 300 }) |minimum| {
        for ([_]u16{ 0, 3 }) |rcode| {
            for ([_]bool{ false, true }) |cname| {
                for ([_]u32{ 0, 15 }) |negative_ttl| {
                    var packet: [512]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&packet);
                    try writer.writeAll(query);
                    std.mem.writeInt(u16, packet[2..4], 0x8180 | rcode, .big);
                    std.mem.writeInt(u16, packet[6..8], @intFromBool(cname), .big);
                    std.mem.writeInt(u16, packet[8..10], 1, .big);
                    if (cname) try writer.writeAll("\xc0\x0c\x00\x05\x00\x01\x00\x00\x00\x3c\x00\x02\xc0\x0c");
                    const soa_ttl_offset = writer.end + 6;
                    try writer.writeAll("\xc0\x0c\x00\x06\x00\x01\x00\x00\x00\x3c\x00\x16" ++
                        "\x00\x00" ++
                        "\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04");
                    try writer.writeInt(u32, negative_ttl, .big);
                    var cache = try Cache.init(std.testing.allocator, 1);
                    defer cache.deinit();
                    cache.min_positive_ttl_seconds = minimum;
                    try cache.put(Key.fromQuery(query).?, writer.buffered(), 100);
                    var out: [512]u8 = undefined;
                    if (negative_ttl == 0) {
                        try std.testing.expectEqual(@as(usize, 0), cache.occupied());
                        continue;
                    }
                    const replay = cache.get(query, 114, &out).?;
                    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, replay[soa_ttl_offset..][0..4], .big));
                    if (cname) try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, replay[query.len + 6 ..][0..4], .big));
                    try std.testing.expect(cache.get(query, 115, &out) == null);
                }
            }
        }
    }
}
