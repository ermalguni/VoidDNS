const std = @import("std");
const Name = @import("name.zig");
const message = @import("message.zig");

const opt_type = 41;
const cookie_code = 10;
const padding_code = 12;

pub const Result = struct {
    packet: []const u8,
    cookies_removed: usize = 0,
};

// Output may be the same buffer as input, or a separate, non-overlapping buffer.
// No copy or allocation is needed when no COOKIE option is present.
pub fn stripCookies(packet: []const u8, output: []u8) !Result {
    if (packet.len < message.Header.len) return error.InvalidMessage;
    const additional = read16(packet, 10);
    if (additional == 0) return .{ .packet = packet };

    var cursor: usize = message.Header.len;
    for (0..read16(packet, 4)) |_| {
        _ = try Name.read(packet, &cursor);
        if (packet.len - cursor < 4) return error.InvalidMessage;
        cursor += 4;
    }

    const ordinary = @as(usize, read16(packet, 6)) + read16(packet, 8);
    var opt: ?struct { fields: usize, start: usize, end: usize } = null;
    var authenticated = false;
    for (0..ordinary + additional) |i| {
        const owner = try Name.read(packet, &cursor);
        if (packet.len - cursor < 10) return error.InvalidMessage;
        const kind = read16(packet, cursor);
        const start = cursor + 10;
        const end = start + read16(packet, cursor + 8);
        if (end > packet.len) return error.InvalidMessage;
        if (kind == opt_type) {
            if (opt != null or i < ordinary or owner.len != 1)
                return error.InvalidOpt;
            opt = .{ .fields = cursor, .start = start, .end = end };
        }
        // Modifying a signed message would invalidate its authentication.
        if (kind == 250 or kind == 24) authenticated = true;
        cursor = end;
    }
    if (cursor != packet.len) return error.InvalidMessage;
    const record = opt orelse return .{ .packet = packet };

    // Validate every option before modifying an aliased receive buffer.
    var cookies: usize = 0;
    cursor = record.start;
    while (cursor < record.end) {
        if (record.end - cursor < 4) return error.InvalidOption;
        const end = cursor + 4 + read16(packet, cursor + 2);
        if (end > record.end) return error.InvalidOption;
        if (read16(packet, cursor) == cookie_code) cookies += 1;
        cursor = end;
    }
    if (cookies == 0) return .{ .packet = packet };
    if (authenticated) return error.AuthenticatedCookie;
    // A response must not gain unsolicited Padding. A non-final OPT cannot
    // shrink safely without relocating later compressed records, so reject this
    // unsolicited-cookie response instead of returning client-specific data.
    if (record.end != packet.len and read16(packet, 2) & message.Flags.response != 0)
        return error.NonFinalResponseCookie;
    if (output.len < packet.len) return error.NoSpaceLeft;
    if (output.ptr != packet.ptr) @memcpy(output[0..packet.len], packet);

    var destination = record.start;
    cursor = record.start;
    while (cursor < record.end) {
        const size = 4 + @as(usize, read16(packet, cursor + 2));
        const end = cursor + size;
        if (read16(packet, cursor) == cookie_code) {
            if (record.end != packet.len) {
                // Keep later records and their compression targets at the same
                // offsets. Replace COOKIE with zero-filled EDNS Padding instead.
                std.mem.writeInt(u16, output[cursor..][0..2], padding_code, .big);
                @memset(output[cursor + 4 .. end], 0);
            }
        } else if (record.end == packet.len) {
            std.mem.copyForwards(u8, output[destination..][0..size], packet[cursor..end]);
            destination += size;
        }
        cursor = end;
    }
    if (record.end != packet.len)
        return .{ .packet = output[0..packet.len], .cookies_removed = cookies };

    std.mem.writeInt(u16, output[record.fields + 8 ..][0..2], @intCast(destination - record.start), .big);
    return .{ .packet = output[0..destination], .cookies_removed = cookies };
}

fn read16(packet: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, packet[offset..][0..2], .big);
}

const test_question = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x01" ++
    "\x04home\x04test\x00\x00\x01\x00\x01";
const test_cookie = "\x00\x0a\x00\x08abcdefgh";

fn testPacket(buffer: []u8, options: []const u8) ![]u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll(test_question);
    // Retain the advertised 1232-byte payload size and DNSSEC DO flag.
    try writer.writeAll("\x00\x00\x29\x04\xd0\x00\x00\x80\x00");
    try writer.writeInt(u16, @intCast(options.len), .big);
    try writer.writeAll(options);
    return buffer[0..writer.end];
}

test "cookie removal preserves EDNS settings and works in place" {
    var buffer: [512]u8 = undefined;
    var expected_buffer: [512]u8 = undefined;
    const packet = try testPacket(&buffer, test_cookie);
    const expected = try testPacket(&expected_buffer, "");
    const result = try stripCookies(packet, &buffer);
    try std.testing.expectEqual(@as(usize, 1), result.cookies_removed);
    try std.testing.expectEqualSlices(u8, expected, result.packet);
    const unchanged = try stripCookies(result.packet, &expected_buffer);
    try std.testing.expect(unchanged.packet.ptr == result.packet.ptr);
}

test "remove all cookies while preserving other options in order" {
    const first = "\xfd\xe8\x00\x02XY";
    const second = "\xfd\xe9\x00\x01Z";
    var buffer: [512]u8 = undefined;
    var expected_buffer: [512]u8 = undefined;
    const packet = try testPacket(&buffer, test_cookie ++ first ++ test_cookie ++ second ++ test_cookie);
    const expected = try testPacket(&expected_buffer, first ++ second);
    const result = try stripCookies(packet, &buffer);
    try std.testing.expectEqual(@as(usize, 3), result.cookies_removed);
    try std.testing.expectEqualSlices(u8, expected, result.packet);
}

test "truncated options fail before modifying the input" {
    var buffer: [512]u8 = undefined;
    const packet = try testPacket(&buffer, test_cookie ++ "\x00\x0a\x00\x08x");
    const before = buffer;
    try std.testing.expectError(error.InvalidOption, stripCookies(packet, &buffer));
    try std.testing.expectEqualSlices(u8, before[0..packet.len], packet);
}

test "non-final OPT uses padding without moving compressed records" {
    var buffer: [512]u8 = undefined;
    const packet = try testPacket(&buffer, test_cookie);
    const address = "\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xc0\x00\x02\x01";
    @memcpy(buffer[packet.len..][0..address.len], address);
    buffer[11] = 2;
    buffer[2] |= 0x80;
    try std.testing.expectError(error.NonFinalResponseCookie, stripCookies(buffer[0 .. packet.len + address.len], &buffer));
    buffer[2] &= 0x7f;
    const result = try stripCookies(buffer[0 .. packet.len + address.len], &buffer);
    try std.testing.expectEqualSlices(u8, address, result.packet[packet.len..]);
    try std.testing.expectEqualSlices(u8, "\x00\x0c\x00\x08" ++ "\x00" ** 8, result.packet[38..packet.len]);
    var cursor = packet.len;
    const owner = try Name.read(result.packet, &cursor);
    try std.testing.expect(owner.matches("home.test"));
}

test "signed packets with cookies are not silently modified" {
    var buffer: [512]u8 = undefined;
    const packet = try testPacket(&buffer, test_cookie);
    const tsig = "\x00\x00\xfa\x00\xff\x00\x00\x00\x00\x00\x00";
    @memcpy(buffer[packet.len..][0..tsig.len], tsig);
    buffer[11] = 2;
    try std.testing.expectError(error.AuthenticatedCookie, stripCookies(buffer[0 .. packet.len + tsig.len], &buffer));
}

test "response cookies are stripped without changing compressed answers or TTLs" {
    var buffer: [512]u8 = undefined;
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll(test_question);
    buffer[2] = 0x81;
    buffer[3] = 0x80;
    buffer[7] = 1;
    const answer = "\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xc0\x00\x02\x01";
    try writer.writeAll(answer);
    try writer.writeAll("\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x1c");
    try writer.writeAll("\x00\x0a\x00\x18abcdefgh" ++ "s" ** 16);
    const packet = writer.buffered();
    const result = try stripCookies(packet, &output);
    try std.testing.expectEqual(@as(usize, 1), result.cookies_removed);
    try std.testing.expectEqual(@as(usize, 54), result.packet.len);
    try std.testing.expectEqualSlices(u8, answer, result.packet[27..43]);
    try std.testing.expectEqual(@as(u16, 0), read16(result.packet, 52));
    try std.testing.expectEqual(@as(u16, 28), read16(packet, 52));
}
