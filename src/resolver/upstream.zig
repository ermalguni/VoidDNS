const std = @import("std");
const Io = std.Io;
const net = Io.net;
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");

const automatic_port: u16 = 0;
const response_timeout: Io.Clock.Duration = .{
    .raw = .fromSeconds(3),
    .clock = .awake,
};

pub fn forward(io: Io, query: []const u8, buffer: []u8) ![]const u8 {
    if (query.len < message.Header.len) return error.InvalidQuestion;

    const upstream = try net.IpAddress.parseIp4("1.1.1.1", message.port);
    const local = try net.IpAddress.parseIp4("0.0.0.0", automatic_port);
    const socket = try local.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer socket.close(io);

    const query_id = decode.id(query);
    try socket.send(io, &upstream, query);

    const timeout: Io.Timeout = .{
        .deadline = Io.Clock.Timestamp.fromNow(io, response_timeout),
    };

    while (true) {
        const response = try socket.receiveTimeout(io, buffer, timeout);

        if (!response.from.eql(&upstream)) continue;
        if (response.data.len < message.Header.len) continue;
        if (decode.id(response.data) != query_id) continue;
        if (decode.flags(response.data) & message.Flags.response == 0) continue;

        return response.data;
    }
}
