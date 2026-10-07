const std = @import("std");
const message = @import("message.zig");
const Name = @import("name.zig");

// Callers first check packet.len >= message.Header.len.
pub fn id(packet: []const u8) u16 {
    return std.mem.readInt(
        u16,
        packet[message.Header.id_offset..][0..@sizeOf(u16)],
        .big,
    );
}

pub fn flags(packet: []const u8) u16 {
    return std.mem.readInt(
        u16,
        packet[message.Header.flags_offset..][0..@sizeOf(u16)],
        .big,
    );
}

pub fn question(packet: []const u8) !message.Question {
    if (packet.len < message.Header.len) return error.InvalidQuestion;

    const query_flags = flags(packet);
    const count = std.mem.readInt(
        u16,
        packet[message.Header.question_count_offset..][0..@sizeOf(u16)],
        .big,
    );

    if (query_flags & (message.Flags.response | message.Flags.opcode_mask) != 0 or
        count != 1)
    {
        return error.UnsupportedQuestion;
    }

    var offset: usize = message.Header.len;
    const name = try Name.read(packet, &offset);

    const question_fields_len = @sizeOf(u16) + @sizeOf(u16);
    if (offset + question_fields_len > packet.len)
        return error.InvalidQuestion;

    var reader = std.Io.Reader.fixed(packet[offset..]);

    return .{
        .id = id(packet),
        .flags = query_flags,
        .name = name,
        .qtype = @enumFromInt(try reader.takeInt(u16, .big)),
        .qclass = @enumFromInt(try reader.takeInt(u16, .big)),
    };
}
