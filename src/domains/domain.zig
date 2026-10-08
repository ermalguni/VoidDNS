const std = @import("std");
const Name = @import("../dns/name.zig");

/// Exact ASCII DNS names, including underscore labels; no wildcard or IP literals.
/// The returned slice borrows buffer. A single final root dot is optional.
pub fn normalize(input: []const u8, buffer: *[253]u8) ![]const u8 {
    const text = if (std.mem.endsWith(u8, input, ".")) input[0 .. input.len - 1] else input;
    if (text.len == 0 or text.len > buffer.len) return error.InvalidDomain;
    if (std.Io.net.IpAddress.parse(text, 0)) |_| {
        return error.InvalidDomain;
    } else |_| {}
    var labels = std.mem.splitScalar(u8, text, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-')
            return error.InvalidDomain;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
                return error.InvalidDomain;
        }
    }
    for (text, 0..) |byte, i| buffer[i] = std.ascii.toLower(byte);
    return buffer[0..text.len];
}

/// Converts the expanded wire name without allocating. Unmanaged DNS names
/// (root, arbitrary binary labels, or literal IP names) do not match policy.
pub fn fromWire(name: *const Name, buffer: *[253]u8) ?[]const u8 {
    if (name.len > name.wire.len) return null;
    var cursor: usize = 0;
    var used: usize = 0;
    while (cursor < name.len) {
        const length = name.wire[cursor];
        cursor += 1;
        if (length == 0) {
            if (cursor != name.len) return null;
            return normalize(buffer[0..used], buffer) catch null;
        }
        if (length > 63 or length > name.len - cursor) return null;
        if (used != 0) {
            if (used == buffer.len) return null;
            buffer[used] = '.';
            used += 1;
        }
        if (length > buffer.len - used) return null;
        for (name.wire[cursor..][0..length], 0..) |byte, i| {
            if (byte == '.') return null;
            buffer[used + i] = byte;
        }
        used += length;
        cursor += length;
    }
    return null;
}

test "canonical names and invalid syntax" {
    var buffer: [253]u8 = undefined;
    try std.testing.expectEqualStrings("_https._tcp.example", try normalize("_HTTPS._TCP.Example.", &buffer));
    for ([_][]const u8{ "", ".", "a..b", "-a.test", "a-.test", "*.test", "a b", "a/b", "a..", "127.0.0.1", "::1", "caf\xc3\xa9.test" }) |invalid| {
        try std.testing.expectError(error.InvalidDomain, normalize(invalid, &buffer));
    }
    const long_label = [_]u8{'a'} ** 64;
    try std.testing.expectError(error.InvalidDomain, normalize(&long_label, &buffer));
    const longest = ([_]u8{'a'} ** 63) ++ "." ++ ([_]u8{'b'} ** 63) ++ "." ++ ([_]u8{'c'} ** 63) ++ "." ++ ([_]u8{'d'} ** 61);
    try std.testing.expectEqual(@as(usize, 253), (try normalize(longest, &buffer)).len);
}

test "wire canonicalization preserves label boundaries" {
    var buffer: [253]u8 = undefined;
    var cursor: usize = 0;
    const name = try Name.read("\x03WWW\x07Example\x00", &cursor);
    try std.testing.expectEqualStrings("www.example", fromWire(&name, &buffer).?);
    cursor = 0;
    const binary_label = try Name.read("\x03a.b\x00", &cursor);
    try std.testing.expect(fromWire(&binary_label, &buffer) == null);
}
