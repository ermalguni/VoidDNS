const std = @import("std");
const Record = @import("../domains/record.zig");
const decode = @import("../dns/decode.zig");
const encode = @import("../dns/encode.zig");
const upstream = @import("upstream.zig");

pub fn resolve(
    io: std.Io,
    query: []const u8,
    buffer: []u8,
    records: []const Record,
) ![]const u8 {
    const question = decode.question(query) catch
        return upstream.forward(io, query, buffer);

    if (question.qclass != .internet)
        return upstream.forward(io, query, buffer);

    switch (question.qtype) {
        .a, .aaaa => {
            for (records) |*record| {
                if (!question.name.matches(record.name)) continue;

                const data = record.data(question.qtype) orelse continue;
                return encode.address(
                    &question,
                    data,
                    record.ttl_seconds,
                    buffer,
                );
            }
        },
        else => {},
    }

    return upstream.forward(io, query, buffer);
}
