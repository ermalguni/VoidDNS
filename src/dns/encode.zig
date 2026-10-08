const std = @import("std");
const message = @import("message.zig");
const Name = @import("name.zig");

pub fn address(
    question: *const message.Question,
    data: []const u8,
    ttl_seconds: u32,
    buffer: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeQuestion(&writer, question, 1);

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

// NODATA: NOERROR with the original question and no answer or authority RRs.
// In particular, this emits no SOA negative-cache lifetime for policy responses.
pub fn nodata(question: *const message.Question, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeQuestion(&writer, question, 0);
    return writer.buffered();
}

fn writeQuestion(writer: *std.Io.Writer, question: *const message.Question, answers: u16) !void {
    const Flags = message.Flags;
    const preserved_flags = Flags.recursion_desired | Flags.checking_disabled;
    const response_flags = Flags.response | Flags.recursion_available |
        (question.flags & preserved_flags);

    try writer.writeInt(u16, question.id, .big);
    try writer.writeInt(u16, response_flags, .big);
    try writer.writeInt(u16, 1, .big);
    try writer.writeInt(u16, answers, .big);
    try writer.writeInt(u16, 0, .big);
    try writer.writeInt(u16, 0, .big);
    try writer.writeAll(question.name.wire[0..question.name.len]);
    try writer.writeInt(u16, @intFromEnum(question.qtype), .big);
    try writer.writeInt(u16, @intFromEnum(question.qclass), .big);
}
