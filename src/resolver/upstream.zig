const std = @import("std");
const Io = std.Io;
const net = Io.net;
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const log = std.log.scoped(.upstream);

const automatic_port: u16 = 0;

/// Borrows its generation's address list; used by the sequential UDP worker.
pub const Pool = struct {
    addresses: []const net.IpAddress,
    response_timeout: Io.Clock.Duration,
    next_index: usize = 0,

    pub fn init(addresses: []const net.IpAddress, timeout_ms: u32) !Pool {
        if (addresses.len == 0) return error.NoUpstreams;
        if (timeout_ms == 0) return error.InvalidTimeout;
        return .{
            .addresses = addresses,
            .response_timeout = .{
                .raw = .fromMilliseconds(timeout_ms),
                .clock = .awake,
            },
        };
    }

    pub fn forward(self: *Pool, io: Io, query: []const u8, buffer: []u8) ![]const u8 {
        const address = self.addresses[self.next_index];
        // Advance even if the exchange fails; no retry within this query.
        self.next_index += 1;
        if (self.next_index == self.addresses.len) self.next_index = 0;
        return exchange(io, address, self.response_timeout, query, buffer);
    }
};

fn exchange(
    io: Io,
    upstream: net.IpAddress,
    response_timeout: Io.Clock.Duration,
    query: []const u8,
    buffer: []u8,
) ![]const u8 {
    if (query.len < message.Header.len) {
        log.debug("forwarding bypass: query too short bytes={d}", .{query.len});
        return error.InvalidQuestion;
    }

    const query_id = decode.id(query);
    log.debug("forwarding id={d} to={f} bytes={d}", .{ query_id, upstream, query.len });
    errdefer |err| {
        if (err != error.Canceled) log.warn("forwarding failed id={d} to={f}: {s}", .{
            query_id, upstream, @errorName(err),
        });
    }
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

test "pool requires upstreams and a positive response timeout" {
    const addresses = [_]net.IpAddress{
        try net.IpAddress.parseIp4("192.0.2.1", 53),
    };
    try std.testing.expectError(error.NoUpstreams, Pool.init(&.{}, 3000));
    try std.testing.expectError(error.InvalidTimeout, Pool.init(&addresses, 0));
}
