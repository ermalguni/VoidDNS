const std = @import("std");
const message = @import("message.zig");
const Name = @import("name.zig");

pub fn address(
    question: *const message.Question,
    data: []const u8,
    ttl_seconds: u32,
    buffer: []u8,
) ![]const u8 {
    const Flags = message.Flags;
    const preserved_flags = Flags.recursion_desired | Flags.checking_disabled;
    const response_flags = Flags.response | Flags.recursion_available |
        (question.flags & preserved_flags);

    var writer = std.Io.Writer.fixed(buffer);

    try writer.writeInt(u16, question.id, .big);
    try writer.writeInt(u16, response_flags, .big);
    try writer.writeInt(u16, 1, .big); // question count
    try writer.writeInt(u16, 1, .big); // answer count
    try writer.writeInt(u16, 0, .big); // authority count
    try writer.writeInt(u16, 0, .big); // additional count

    try writer.writeAll(question.name.wire[0..question.name.len]);
    try writer.writeInt(u16, @intFromEnum(question.qtype), .big);
    try writer.writeInt(u16, @intFromEnum(question.qclass), .big);

    const question_name_pointer =
        Name.compression_pointer_tag | message.Header.len;

    try writer.writeInt(u16, question_name_pointer, .big);
    try writer.writeInt(u16, @intFromEnum(question.qtype), .big);
    try writer.writeInt(u16, @intFromEnum(question.qclass), .big);
    try writer.writeInt(u32, ttl_seconds, .big);
    try writer.writeInt(u16, @intCast(data.len), .big);
    try writer.writeAll(data);

    return writer.buffered();
}
