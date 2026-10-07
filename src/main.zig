const std = @import("std");

const Io = std.Io;
const net = Io.net;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try net.IpAddress.parseIp4("127.0.0.1", 53);
    const listener = try address.bind(
        io,
        .{
            .mode = .dgram,
            .protocol = .udp,
        },
    );

    var buffer: [64 * 1024]u8 = undefined;
    std.log.info("DNS Server listening on: {f} and is forwarding to 1.1.1.1:53", .{address});

    while (true) {
        const query = try listener.receive(io, &buffer);
        if (query.data.len < 12 or query.data[2] & 0x80 != 0) continue;

        const response = forward(io, query.data, &buffer) catch |err| {
            std.log.warn("upstream request failed: {s}", .{@errorName(err)});
            continue;
        };

        listener.send(io, &query.from, response) catch |err| {
            std.log.warn("reply failed: {s}", .{@errorName(err)});
            continue;
        };
    }
}

fn forward(io: Io, query: []const u8, buffer: []u8) ![]const u8 {
    const upstream = try net.IpAddress.parseIp4("1.1.1.1", 53);
    const local = try net.IpAddress.parseIp4("0.0.0.0", 0);
    const socket = try local.bind(
        io,
        .{
            .mode = .dgram,
            .protocol = .udp,
        },
    );
    defer socket.close(io);

    const id = [2]u8{ query[0], query[1] };
    try socket.send(io, &upstream, query);

    const timeout: Io.Timeout = .{
        .deadline = Io.Clock.Timestamp.fromNow(
            io,
            .{
                .raw = .fromSeconds(3),
                .clock = .awake,
            },
        ),
    };

    while (true) {
        const response = try socket.receiveTimeout(io, buffer, timeout);
        if (!response.from.eql(&upstream)) continue;
        if (response.data.len < 12) continue;
        if (response.data[0] != id[0] or response.data[1] != id[1]) continue;
        if (response.data[2] & 0x80 == 0) continue;

        return response.data;
    }
}
