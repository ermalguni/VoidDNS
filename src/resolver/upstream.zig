const std = @import("std");
const Io = std.Io;
const net = Io.net;
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const log = std.log.scoped(.upstream);

const automatic_port: u16 = 0;
const response_timeout: Io.Clock.Duration = .{
    .raw = .fromSeconds(3),
    .clock = .awake,
};

pub fn forward(io: Io, query: []const u8, buffer: []u8) ![]const u8 {
    if (query.len < message.Header.len) {
        log.debug("forwarding bypass: query too short bytes={d}", .{query.len});
        return error.InvalidQuestion;
    }

    const upstream = try net.IpAddress.parseIp4("1.1.1.1", message.port);
    const query_id = decode.id(query);
    log.debug("forwarding id={d} to={f} bytes={d}", .{ query_id, upstream, query.len });
    errdefer |err| log.warn("forwarding failed id={d} to={f}: {s}", .{
        query_id, upstream, @errorName(err),
    });
    const local = try net.IpAddress.parseIp4("0.0.0.0", automatic_port);
    const socket = try local.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer socket.close(io);

    try socket.send(io, &upstream, query);

    const timeout: Io.Timeout = .{
        .deadline = Io.Clock.Timestamp.fromNow(io, response_timeout),
    };

    while (true) {
        const response = try socket.receiveTimeout(io, buffer, timeout);

        if (!response.from.eql(&upstream)) {
            log.debug("ignored packet id={d}: unexpected sender={f}", .{ query_id, response.from });
            continue;
        }
        if (response.data.len < message.Header.len) {
            log.debug("ignored packet id={d}: short header bytes={d}", .{ query_id, response.data.len });
            continue;
        }
        const response_id = decode.id(response.data);
        if (response_id != query_id) {
            log.debug("ignored packet id={d}: mismatched response id={d}", .{ query_id, response_id });
            continue;
        }
        if (decode.flags(response.data) & message.Flags.response == 0) {
            log.debug("ignored packet id={d}: response flag not set", .{query_id});
            continue;
        }

        log.debug("received id={d} from={f} bytes={d} rcode={d}", .{
            query_id, response.from, response.data.len, decode.flags(response.data) & 0x000f,
        });
        return response.data;
    }
}
