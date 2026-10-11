const std = @import("std");
const message = @import("message.zig");
const Name = @import("name.zig");
const Record = @import("../domains/record.zig");

pub fn address(
    question: *const message.Question,
    data: []const u8,
    ttl_seconds: u32,
    buffer: []u8,
) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeQuestion(&writer, question, 1, false);
    try writeAddress(&writer, question, data, ttl_seconds);

    return writer.buffered();
}

// The caller caps buffer to the client's UDP limit before entering the encoder.
// An RRset is atomic: return only the question with TC if any answer would not fit.
pub fn rrset(
    question: *const message.Question,
    record: *const Record,
    buffer: []u8,
) ![]const u8 {
    const question_len = message.Header.len + question.name.len + 4;
    const count, const data_len = switch (record.addresses) {
        .a => |addresses| .{ addresses.len, @as(usize, Record.ipv4_address_len) },
        .aaaa => |addresses| .{ addresses.len, @as(usize, Record.ipv6_address_len) },
    };
    const truncated = question_len > buffer.len or
        count > (buffer.len - question_len) / (12 + data_len);
    var writer = std.Io.Writer.fixed(buffer);
    try writeQuestion(&writer, question, if (truncated) 0 else @intCast(count), truncated);
    if (!truncated) {
        switch (record.addresses) {
            inline else => |addresses| {
                for (addresses) |*data| {
                    try writeAddress(&writer, question, data, record.ttl_seconds);
                }
            },
        }
    }
    return writer.buffered();
}

fn writeAddress(
    writer: *std.Io.Writer,
    question: *const message.Question,
    data: []const u8,
    ttl_seconds: u32,
) !void {
    const question_name_pointer =
        Name.compression_pointer_tag | message.Header.len;
    try writer.writeInt(u16, question_name_pointer, .big);
    try writer.writeInt(u16, @intFromEnum(question.qtype), .big);
    try writer.writeInt(u16, @intFromEnum(question.qclass), .big);
    try writer.writeInt(u32, ttl_seconds, .big);
    try writer.writeInt(u16, @intCast(data.len), .big);
    try writer.writeAll(data);
}

// NODATA: NOERROR with the original question and no answer or authority RRs.
// In particular, this emits no SOA negative-cache lifetime for policy responses.
pub fn nodata(question: *const message.Question, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writeQuestion(&writer, question, 0, false);
    return writer.buffered();
}

fn writeQuestion(writer: *std.Io.Writer, question: *const message.Question, answers: u16, truncated: bool) !void {
    const Flags = message.Flags;
    const preserved_flags = Flags.recursion_desired | Flags.checking_disabled;
    const response_flags = Flags.response | Flags.recursion_available |
        (question.flags & preserved_flags) |
        (if (truncated) Flags.truncated else @as(u16, 0));

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
