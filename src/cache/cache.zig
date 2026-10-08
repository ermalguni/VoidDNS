const std = @import("std");
const Name = @import("../dns/name.zig");
const Cache = @This();
const log = std.log.scoped(.cache);

pub const max_packet = 4096;
pub const max_query = 512;
const max_records = max_packet / 11;

const Entry = struct {
    bytes: []u8,
    inserted: i64,
    lifetime: u32,
    key_len: u16,
    packet_len: u16,
    ttl_count: u16,
};

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
        if (slot) |entry| self.allocator.free(entry.bytes);
    }
    self.allocator.free(self.slots);
    log.debug("deinitialized", .{});
}

fn slotFor(self: *Cache, k: []const u8) *?Entry {
    return &self.slots[std.hash.Wyhash.hash(0, k) % self.slots.len];
}

// The resolver removes COOKIE options before lookup and insertion.
// Preserve all remaining query bytes except the transaction ID, including case.
// Other EDNS options still bypass caching.
pub fn key(query: []const u8) ?[]const u8 {
    if (query.len < 12 or query.len > max_query) return null;
    if (u16At(query, 2) & ~@as(u16, 0x0130) != 0) return null;
    if (u16At(query, 4) != 1 or u16At(query, 6) != 0 or u16At(query, 8) != 0)
        return null;

    const end = questionEnd(query) catch return null;
    const additional = u16At(query, 10);

    if (additional == 0) {
        if (end != query.len) return null;
    } else if (additional == 1) {
        if (query.len != end + 11 or query[end] != 0 or
            u16At(query, end + 1) != 41 or
            u32At(query, end + 5) & ~@as(u32, 0x8000) != 0 or
            u16At(query, end + 9) != 0) return null;
    } else return null;

    return query[2..];
}

pub fn get(self: *Cache, query: []const u8, now: i64, out: []u8) ?[]const u8 {
    const k = key(query) orelse {
        log.debug("lookup bypass: unsupported query bytes={d}", .{query.len});
        return null;
    };
    const query_id = u16At(query, 0);
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
        self.allocator.free(entry.bytes);
        slot.* = null;
        return null;
    }

    if (!std.mem.eql(u8, k, entry.bytes[0..entry.key_len])) {
        log.debug("miss id={d}: slot contains another key", .{query_id});
        return null;
    }
    if (out.len < entry.packet_len) {
        log.debug("lookup bypass id={d}: output buffer too small", .{query_id});
        return null;
    }

    const id = u16At(query, 0); // query and out may alias.
    const packet_end = @as(usize, entry.key_len) + entry.packet_len;
    const packet = entry.bytes[entry.key_len..packet_end];

    @memcpy(out[0..packet.len], packet);
    std.mem.writeInt(u16, out[0..2], id, .big);

    for (0..entry.ttl_count) |i| {
        const offset = u16At(entry.bytes, packet_end + i * 2);
        const ttl = u32At(packet, offset) - @as(u32, @intCast(elapsed));
        std.mem.writeInt(u32, out[offset..][0..4], ttl, .big);
    }

    log.debug("hit id={d} bytes={d} remaining={d}s", .{
        id, packet.len, @as(i64, entry.lifetime) - elapsed,
    });
    return out[0..packet.len];
}

// k must be saved before resolution: the response overwrites the query buffer.
pub fn put(self: *Cache, k: []const u8, response: []const u8, now: i64) !void {
    if (self.slots.len == 0) {
        log.debug("insertion bypass: disabled", .{});
        return;
    }

    var offsets: [max_records]u16 = undefined;
    const info = inspect(k, response, &offsets) catch |err| {
        log.debug("insertion bypass: {s} bytes={d}", .{ @errorName(err), response.len });
        return;
    };

    const bytes = try self.allocator.alloc(
        u8,
        k.len + response.len + info.count * 2,
    );

    @memcpy(bytes[0..k.len], k);
    @memcpy(bytes[k.len..][0..response.len], response);

    for (offsets[0..info.count], 0..) |offset, i| {
        std.mem.writeInt(
            u16,
            bytes[k.len + response.len + i * 2 ..][0..2],
            offset,
            .big,
        );
    }

    // Negative responses must not advertise a TTL beyond their SOA-derived limit.
    if (info.soa_limited) {
        for (offsets[0..info.count]) |offset| {
            const ttl = @min(u32At(response, offset), info.lifetime);
            std.mem.writeInt(u32, bytes[k.len + offset ..][0..4], ttl, .big);
        }
    }

    const slot = self.slotFor(k);
    if (slot.*) |old| {
        log.debug("replacing occupied slot old_bytes={d}", .{old.packet_len});
        self.allocator.free(old.bytes);
    }

    slot.* = .{
        .bytes = bytes,
        .inserted = now,
        .lifetime = info.lifetime,
        .key_len = @intCast(k.len),
        .packet_len = @intCast(response.len),
        .ttl_count = @intCast(info.count),
    };
    log.debug("inserted id={d} bytes={d} ttl={d}s soa_limited={}", .{
        u16At(response, 0), response.len, info.lifetime, info.soa_limited,
    });
}

const Info = struct {
    lifetime: u32,
    count: usize,
    soa_limited: bool,
};

fn inspect(k: []const u8, packet: []const u8, offsets: []u16) !Info {
    if (packet.len < 12 or packet.len > max_packet or k.len < 10)
        return error.NotCacheable;

    const flags = u16At(packet, 2);
    const rcode = flags & 15;

    if (flags & 0x8000 == 0 or flags & 0x7a00 != 0 or
        (rcode != 0 and rcode != 3) or u16At(packet, 4) != 1 or
        flags & 0x0110 != u16At(k, 0) & 0x0110)
        return error.NotCacheable;

    const qend = try questionEnd(packet);
    if (k.len < qend - 2 or
        !std.mem.eql(u8, packet[12..qend], k[10 .. qend - 2]))
        return error.NotCacheable;

    const answers = u16At(packet, 6);
    const authority = u16At(packet, 8);
    const total = @as(usize, answers) + authority + u16At(packet, 10);

    var cursor = qend;
    var lifetime: u32 = std.math.maxInt(u31);
    var negative_ttl: ?u32 = null;
    var count: usize = 0;
    var seen_opt = false;

    for (0..total) |i| {
        const owner = try Name.read(packet, &cursor);
        if (packet.len - cursor < 10) return error.NotCacheable;

        const kind = u16At(packet, cursor);
        const ttl_offset = cursor + 4;
        const raw_ttl = u32At(packet, ttl_offset);
        const ttl = if (raw_ttl > std.math.maxInt(u31)) 0 else raw_ttl;
        const data_start = cursor + 10;
        const end = data_start + u16At(packet, cursor + 8);

        if (end > packet.len) return error.NotCacheable;

        if (kind == 41) {
            // OPT TTL is metadata. Stateful/unknown EDNS options bypass caching.
            if (seen_opt or i < @as(usize, answers) + authority or
                owner.len != 1 or raw_ttl & ~@as(u32, 0x8000) != 0 or
                end != data_start or u16At(k, 8) != 1)
                return error.NotCacheable;

            seen_opt = true;
        } else {
            // Transaction authentication cannot be replayed under a new ID.
            if (kind == 250 or kind == 24 or count == offsets.len)
                return error.NotCacheable;

            offsets[count] = @intCast(ttl_offset);
            count += 1;
            lifetime = @min(lifetime, ttl);

            if (kind == 6 and
                i >= answers and i < @as(usize, answers) + authority)
            {
                var soa = data_start;
                _ = try Name.read(packet, &soa);
                _ = try Name.read(packet, &soa);

                if (soa + 20 != end) return error.NotCacheable;

                const value = @min(ttl, u32At(packet, soa + 16));
                negative_ttl = @min(negative_ttl orelse value, value);
            }
        }

        cursor = end;
    }

    if (cursor != packet.len or count == 0) return error.NotCacheable;

    if ((rcode == 3 or answers == 0) and negative_ttl == null)
        return error.NotCacheable;

    // Also covers NODATA responses with a CNAME chain in the answer section.
    if (negative_ttl) |limit| lifetime = @min(lifetime, limit);

    if (lifetime == 0) return error.NotCacheable;

    return .{
        .lifetime = lifetime,
        .count = count,
        .soa_limited = negative_ttl != null,
    };
}

fn questionEnd(packet: []const u8) !usize {
    var cursor: usize = 12;

    // Require an uncompressed question so replay never depends on other fields.
    while (true) {
        if (cursor >= packet.len) return error.NotCacheable;

        const size = packet[cursor];
        if (size > 63) return error.NotCacheable;

        cursor += 1 + @as(usize, size);

        if (cursor > packet.len or cursor - 12 > 255)
            return error.NotCacheable;

        if (size == 0) break;
    }

    if (packet.len - cursor < 4) return error.NotCacheable;
    return cursor + 4;
}

fn u16At(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn u32At(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
