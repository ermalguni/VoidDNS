const std = @import("std");
const Record = @import("../domains/record.zig");
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const resolver = @import("../resolver/resolver.zig");

pub fn serve(
    io: std.Io,
    listener: *const std.Io.net.Socket,
    records: []const Record,
    buffer: []u8,
) !void {
    while (true) {
        const query = try listener.receive(io, buffer);

        if (query.data.len < message.Header.len) continue;
        if (decode.flags(query.data) & message.Flags.response != 0) continue;

        const response = resolver.resolve(
            io,
            query.data,
            buffer,
            records,
        ) catch |err| {
            std.log.warn("resolution failed: {s}", .{@errorName(err)});
            continue;
        };

        listener.send(io, &query.from, response) catch |err| {
            std.log.warn("reply failed: {s}", .{@errorName(err)});
        };
    }
}
