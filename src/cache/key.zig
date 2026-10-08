const std = @import("std");

pub const max_query = 512;

// Returns a borrowed slice; save it before the query buffer is overwritten.
// The resolver removes COOKIE options before lookup and insertion.
// Preserve all remaining query bytes except the transaction ID, including case.
// Other EDNS options still bypass caching.
pub fn fromQuery(query: []const u8) ?[]const u8 {
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

pub fn questionEnd(packet: []const u8) !usize {
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
