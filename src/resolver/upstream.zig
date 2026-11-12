const std = @import("std");
const Io = std.Io;
const net = Io.net;
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const log = std.log.scoped(.upstream);

const automatic_port: u16 = 0;

/// Borrows the active configuration's address list; guarded by Worker.mutex.
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
        // Advance even if the exchange fails; TCP fallback keeps this resolver.
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
    if (query.len > message.packet_capacity) return error.QueryTooLarge;
    if (query.len < message.Header.len) {
        log.debug("forwarding bypass: query too short bytes={d}", .{query.len});
        return error.InvalidQuestion;
    }

    const query_id = decode.id(query);
    log.debug("forwarding id={d} to={f} bytes={d}", .{ query_id, upstream, query.len });
    return exchangeResponse(io, upstream, response_timeout, query, buffer, query_id) catch |err| {
        if (err != error.Canceled) log.warn("forwarding failed id={d} to={f}: {s}", .{
            query_id, upstream, @errorName(err),
        });
        return err;
    };
}

fn exchangeResponse(
    io: Io,
    upstream: net.IpAddress,
    response_timeout: Io.Clock.Duration,
    query: []const u8,
    buffer: []u8,
    query_id: u16,
) ![]const u8 {
    // One deadline covers the UDP send/receive and every TCP fallback operation.
    const timeout: Io.Timeout = .{
        .deadline = Io.Clock.Timestamp.fromNow(io, response_timeout),
    };
    // Callers may reuse their query buffer for the response. Preserve only
    // overlapping queries, before even an ignored UDP packet can overwrite one.
    var saved_query: [message.packet_capacity]u8 = undefined;
    const overlaps = @intFromPtr(query.ptr) < @intFromPtr(buffer.ptr) + buffer.len and
        @intFromPtr(buffer.ptr) < @intFromPtr(query.ptr) + query.len;
    const original = if (overlaps) blk: {
        @memcpy(saved_query[0..query.len], query);
        break :blk saved_query[0..query.len];
    } else query;
    // A legal TCP DNS query may exceed IPv4 UDP's 65,507-byte payload.
    if (original.len > 65507)
        return exchangeTcp(io, upstream, timeout, original, buffer, query_id);

    const local = try net.IpAddress.parseIp4("0.0.0.0", automatic_port);
    const socket = try local.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer socket.close(io);

    try socket.sendTimeout(io, &upstream, original, timeout);

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

        if (decode.flags(response.data) & message.Flags.truncated != 0)
            return exchangeTcp(io, upstream, timeout, original, buffer, query_id);
        if (response.flags.trunc) return error.ResponseTooLarge;

        log.debug("received id={d} from={f} bytes={d} rcode={d}", .{
            query_id, response.from, response.data.len, decode.flags(response.data) & 0x000f,
        });
        return response.data;
    }
}

fn exchangeTcp(
    io: Io,
    upstream: net.IpAddress,
    timeout: Io.Timeout,
    query: []const u8,
    buffer: []u8,
    query_id: u16,
) ![]const u8 {
    if (timeout == .none) return exchangeTcpOwned(io, upstream, timeout, query, buffer, query_id);
    // Zig 0.17.1's threaded backend does not implement ConnectOptions.timeout.
    // Race the entire owned exchange so cancellation closes even a connection
    // that completes concurrently with the deadline; no socket escapes a task.
    const Result = union(enum) { response: anyerror![]const u8, expired: Io.Cancelable!void };
    var results: [2]Result = undefined;
    var race: Io.Select(Result) = .init(io, &results);
    defer race.cancelDiscard();
    try race.concurrent(.response, exchangeTcpOwned, .{ io, upstream, timeout, query, buffer, query_id });
    try race.concurrent(.expired, Io.Timeout.sleep, .{ timeout, io });
    return switch (try race.await()) {
        .response => |response| response,
        .expired => |expired| blk: {
            try expired;
            break :blk error.Timeout;
        },
    };
}

fn exchangeTcpOwned(
    io: Io,
    upstream: net.IpAddress,
    timeout: Io.Timeout,
    query: []const u8,
    buffer: []u8,
    query_id: u16,
) ![]const u8 {
    const stream = try upstream.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var prefix: [2]u8 = undefined;
    std.mem.writeInt(u16, &prefix, @intCast(query.len), .big);
    try writeAll(io, stream, &prefix, timeout);
    try writeAll(io, stream, query, timeout);
    try readAll(io, stream, &prefix, timeout);
    const length = std.mem.readInt(u16, &prefix, .big);
    if (length < message.Header.len) return error.InvalidResponse;
    if (length > buffer.len) return error.ResponseTooLarge;
    const response = buffer[0..length];
    try readAll(io, stream, response, timeout);
    if (decode.id(response) != query_id or decode.flags(response) & message.Flags.response == 0)
        return error.InvalidResponse;
    return response;
}

fn readAll(io: Io, stream: net.Stream, buffer: []u8, timeout: Io.Timeout) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var parts = [_][]u8{buffer[offset..]};
        const result = try (try io.operateTimeout(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &parts,
        } }, timeout)).net_read;
        if (result.data_len == 0) return error.EndOfStream;
        offset += result.data_len;
    }
}

fn writeAll(io: Io, stream: net.Stream, bytes: []const u8, timeout: Io.Timeout) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try (try io.operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &.{bytes[offset..]},
        } }, timeout)).net_write;
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

test "pool requires upstreams and a positive response timeout" {
    const addresses = [_]net.IpAddress{
        try net.IpAddress.parseIp4("192.0.2.1", 53),
    };
    try std.testing.expectError(error.NoUpstreams, Pool.init(&.{}, 3000));
    try std.testing.expectError(error.InvalidTimeout, Pool.init(&addresses, 0));
}

const test_query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
    "\x04home\x04test\x00\x00\x01\x00\x01";

const TestPeer = struct {
    server: *net.Server,
    udp: ?net.Socket = null,
    response: []const u8,
    udp_delay_ms: u32 = 0,
    tcp_delay_ms: u32 = 0,
    advertised_length: ?u16 = null,
    ready: ?*Io.Event = null,

    fn run(self: *const TestPeer, io: Io) !void {
        if (self.udp) |udp| {
            var packet: [512]u8 = undefined;
            const received = try udp.receive(io, &packet);
            try std.testing.expectEqualSlices(u8, test_query, received.data);
            // An ignored datagram also overwrites the caller's original query.
            var truncated = [_]u8{ 0x99, 0x99, 0x83, 0x80, 0, 1, 0, 0, 0, 0, 0, 0 };
            try udp.send(io, &received.from, &truncated);
            std.mem.writeInt(u16, truncated[0..2], decode.id(test_query), .big);
            if (self.udp_delay_ms != 0)
                try Io.sleep(io, .fromMilliseconds(self.udp_delay_ms), .awake);
            try udp.send(io, &received.from, &truncated);
        }
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var prefix: [2]u8 = undefined;
        try readAll(io, stream, &prefix, .none);
        try std.testing.expectEqual(test_query.len, std.mem.readInt(u16, &prefix, .big));
        var query: [test_query.len]u8 = undefined;
        try readAll(io, stream, &query, .none);
        try std.testing.expectEqualSlices(u8, test_query, &query);
        if (self.ready) |ready| ready.set(io);
        if (self.tcp_delay_ms != 0)
            try Io.sleep(io, .fromMilliseconds(self.tcp_delay_ms), .awake);
        std.mem.writeInt(u16, &prefix, self.advertised_length orelse @intCast(self.response.len), .big);
        // Deliberately split both prefix and body across writes.
        try writeAll(io, stream, prefix[0..1], .none);
        try Io.sleep(io, .fromMilliseconds(1), .awake);
        try writeAll(io, stream, prefix[1..], .none);
        const split = @min(7, self.response.len);
        try writeAll(io, stream, self.response[0..split], .none);
        try Io.sleep(io, .fromMilliseconds(1), .awake);
        try writeAll(io, stream, self.response[split..], .none);
    }
};

test "UDP TC retries the selected server over TCP with aliased query and maximal fragmented response" {
    const io = std.testing.io;
    const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try local.listen(io, .{});
    defer server.deinit(io);
    const udp = try server.socket.address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    var response: [message.packet_capacity]u8 = @splat(0);
    @memcpy(response[0..test_query.len], test_query);
    response[2] = 0x81;
    const peer: TestPeer = .{ .server = &server, .udp = udp, .response = &response };
    var task = try io.concurrent(TestPeer.run, .{ &peer, io });
    defer task.cancel(io) catch {};
    const addresses = [_]net.IpAddress{ server.socket.address, try net.IpAddress.parseIp4("192.0.2.1", 53) };
    var pool = try Pool.init(&addresses, 3000);
    var buffer: [message.packet_capacity]u8 = undefined;
    @memcpy(buffer[0..test_query.len], test_query);
    const received = try pool.forward(io, buffer[0..test_query.len], &buffer);
    try std.testing.expectEqualSlices(u8, &response, received);
    try std.testing.expectEqual(@as(usize, 1), pool.next_index);
    try task.await(io);
}

test "TCP rejects invalid response identity flags and incomplete frames" {
    const io = std.testing.io;
    const cases = [_]struct { response: []const u8, length: ?u16 = null, expected: anyerror }{
        .{ .response = "\x99\x99\x80\x00" ++ @as([8]u8, @splat(0)), .expected = error.InvalidResponse },
        .{ .response = test_query, .expected = error.InvalidResponse },
        .{ .response = "", .length = 0, .expected = error.InvalidResponse },
        .{ .response = "short", .length = 12, .expected = error.EndOfStream },
        .{ .response = "", .length = 513, .expected = error.ResponseTooLarge },
    };
    for (cases) |case| {
        const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try local.listen(io, .{});
        defer server.deinit(io);
        const peer: TestPeer = .{ .server = &server, .response = case.response, .advertised_length = case.length };
        var task = try io.concurrent(TestPeer.run, .{ &peer, io });
        defer task.cancel(io) catch {};
        var buffer: [512]u8 = undefined;
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };
        try std.testing.expectError(case.expected, exchangeTcp(io, server.socket.address, timeout, test_query, &buffer, decode.id(test_query)));
        try task.await(io);
    }
}

test "UDP and TCP fallback share a total deadline" {
    const io = std.testing.io;
    const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try local.listen(io, .{});
    defer server.deinit(io);
    const udp = try server.socket.address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer udp.close(io);
    const response = "\x12\x34\x81\x80" ++ @as([8]u8, @splat(0));
    const peer: TestPeer = .{ .server = &server, .udp = udp, .response = response, .udp_delay_ms = 120, .tcp_delay_ms = 120 };
    var task = try io.concurrent(TestPeer.run, .{ &peer, io });
    defer task.cancel(io) catch {};
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(error.Timeout, exchangeResponse(
        io, server.socket.address, .{ .raw = .fromMilliseconds(200), .clock = .awake },
        test_query, &buffer, decode.id(test_query),
    ));
}

test "TCP response read cooperatively cancels" {
    const io = std.testing.io;
    const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try local.listen(io, .{});
    defer server.deinit(io);
    var ready: Io.Event = .unset;
    const peer: TestPeer = .{ .server = &server, .response = "", .ready = &ready, .tcp_delay_ms = 30000 };
    var task = try io.concurrent(TestPeer.run, .{ &peer, io });
    defer task.cancel(io) catch {};
    var buffer: [512]u8 = undefined;
    var pending = try io.concurrent(exchangeTcp, .{
        io, server.socket.address, @as(Io.Timeout, .none), test_query, &buffer, decode.id(test_query),
    });
    defer if (pending.cancel(io)) |_| {} else |_| {};
    try ready.wait(io);
    try std.testing.expectError(error.Canceled, pending.cancel(io));
}

test "maximal DNS queries use TCP without an impossible IPv4 UDP datagram" {
    const io = std.testing.io;
    const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try local.listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn run(peer_io: Io, listener: *net.Server) !void {
            const stream = try listener.accept(peer_io);
            defer stream.close(peer_io);
            var prefix: [2]u8 = undefined;
            try readAll(peer_io, stream, &prefix, .none);
            try std.testing.expectEqual(message.packet_capacity, std.mem.readInt(u16, &prefix, .big));
            var packet: [message.packet_capacity]u8 = undefined;
            try readAll(peer_io, stream, &packet, .none);
            try std.testing.expectEqualSlices(u8, test_query, packet[0..test_query.len]);
            for (packet[test_query.len..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            const response = "\x12\x34\x81\x80\x00\x00\x00\x00\x00\x00\x00\x00";
            std.mem.writeInt(u16, &prefix, response.len, .big);
            try writeAll(peer_io, stream, &prefix, .none);
            try writeAll(peer_io, stream, response, .none);
        }
    };
    var task = try io.concurrent(Peer.run, .{ io, &server });
    defer task.cancel(io) catch {};
    var packet: [message.packet_capacity]u8 = @splat(0xa5);
    @memcpy(packet[0..test_query.len], test_query);
    const addresses = [_]net.IpAddress{server.socket.address};
    var pool = try Pool.init(&addresses, 3000);
    const response = try pool.forward(io, &packet, &packet);
    try std.testing.expectEqualSlices(u8, "\x12\x34\x81\x80\x00\x00\x00\x00\x00\x00\x00\x00", response);
    try task.await(io);
}
