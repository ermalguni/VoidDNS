const std = @import("std");
const Worker = @import("server.zig").Worker;
const Config = @import("../config/config.zig").Config;
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const resolver = @import("../resolver/resolver.zig");
const log = std.log.scoped(.tcp);

/// The accept task owns this group. Cancellation joins every client before the
/// worker may reclaim its runtime, state, or listener resources.
pub fn serve(worker: *Worker, io: std.Io) !void {
    var clients: std.Io.Group = .init;
    defer clients.cancel(io);
    while (true) {
        const stream = worker.tcp_listener.?.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        worker.tcp_mutex.lockUncancelable(io);
        const settings = worker.tcp_settings;
        const admitted = worker.tcp_active < settings.max_connections;
        if (admitted) worker.tcp_active += 1;
        worker.tcp_mutex.unlock(io);
        if (!admitted) {
            stream.close(io);
            continue;
        }
        clients.concurrent(io, client, .{ worker, io, stream, settings }) catch |err| {
            stream.close(io);
            release(worker, io);
            return err;
        };
    }
}

fn release(worker: *Worker, io: std.Io) void {
    worker.tcp_mutex.lockUncancelable(io);
    defer worker.tcp_mutex.unlock(io);
    worker.tcp_active -= 1;
}

fn client(worker: *Worker, io: std.Io, stream: std.Io.net.Stream, settings: Config.Tcp) std.Io.Cancelable!void {
    defer release(worker, io);
    defer stream.close(io);
    handle(worker, io, stream, settings) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        // Invalid or incomplete frames terminate only this connection.
        log.debug("connection closed: {s}", .{@errorName(err)});
    };
}

fn handle(worker: *Worker, io: std.Io, stream: std.Io.net.Stream, settings: Config.Tcp) !void {
    // One reusable packet buffer per admitted connection, never per query.
    const buffer = try worker.allocator.alloc(u8, message.packet_capacity);
    defer worker.allocator.free(buffer);
    while (true) {
        var prefix: [2]u8 = undefined;
        const first = try readSome(io, stream, prefix[0..1], deadline(io, settings.idle_timeout_ms));
        if (first == 0) return;
        const read_deadline = deadline(io, settings.read_timeout_ms);
        try readExact(io, stream, prefix[1..], read_deadline);
        const size = std.mem.readInt(u16, &prefix, .big);
        if (size < message.Header.len) return error.InvalidFrame;
        try readExact(io, stream, buffer[0..size], read_deadline);
        var event = @import("../telemetry/event.zig").Event.begin(io, stream.socket.address.ip4.bytes, buffer[0..size], .tcp);
        var response_packet: ?[]const u8 = null;
        var failure: ?anyerror = null;
        defer if (worker.telemetry) |store| {
            event.finish(io, response_packet, failure);
            store.submit(event);
        };
        if (decode.flags(buffer[0..size]) & message.Flags.response != 0) {
            failure = error.InvalidQuestion;
            return error.InvalidQuestion;
        }
        const response = resolved: {
            try worker.mutex.lock(io);
            defer worker.mutex.unlock(io);
            break :resolved resolver.resolveTracked(io, buffer[0..size], buffer, &worker.cache, &worker.upstreams, worker.state, .tcp, &event.resolution) catch |err| {
                failure = err;
                return err;
            };
        };
        response_packet = response;
        std.mem.writeInt(u16, &prefix, @intCast(response.len), .big);
        const write_deadline = deadline(io, settings.write_timeout_ms);
        writeAll(io, stream, &prefix, response, write_deadline) catch |err| {
            failure = err;
            return err;
        };
    }
}

fn deadline(io: std.Io, milliseconds: u32) std.Io.Timeout {
    return .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake }) };
}

fn readSome(io: std.Io, stream: std.Io.net.Stream, buffer: []u8, timeout: std.Io.Timeout) !usize {
    var slices = [_][]u8{buffer};
    return (try (try io.operateTimeout(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &slices,
    } }, timeout)).net_read).data_len;
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buffer: []u8, timeout: std.Io.Timeout) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = try readSome(io, stream, buffer[offset..], timeout);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn writeAll(io: std.Io, stream: std.Io.net.Stream, prefix: []const u8, packet: []const u8, timeout: std.Io.Timeout) !void {
    var header = prefix;
    var body = packet;
    while (header.len + body.len != 0) {
        const slices = [_][]const u8{body};
        const count = try (try io.operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .header = header,
            .data = &slices,
        } }, timeout)).net_write;
        if (count == 0) return error.EndOfStream;
        const header_count = @min(count, header.len);
        header = header[header_count..];
        body = body[count - header_count ..];
    }
}

test "persistent TCP frames tolerate fragmentation and pipelining" {
    const io = std.testing.io;
    const config = @import("../config/config.zig");
    const State = @import("../state/state.zig").State;
    const control = @import("control.zig");
    var diagnostic: config.Diagnostic = .{};
    var settings = try config.parse(std.testing.allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"192.0.2.1"}]}}
    , ".", &diagnostic);
    defer settings.deinit();
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.domains.block("home.test");
    var mailbox: control.Mailbox = .{};
    var worker = try Worker.init(std.testing.allocator, &settings, &state, &mailbox);
    defer worker.deinit(io);
    // Direct connection handler isolates framing from listener port selection.
    const pair = try std.Io.net.Socket.createPair(io, .{});
    const remote: std.Io.net.Stream = .{ .socket = pair[0] };
    defer remote.close(io);
    const accepted: std.Io.net.Stream = .{ .socket = pair[1] };
    worker.tcp_active = 1;
    var future = try io.concurrent(client, .{ &worker, io, accepted, settings.dns_tcp });
    defer future.cancel(io) catch {};
    const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
        "\x04home\x04test\x00\x00\x01\x00\x01";
    const timeout = deadline(io, 3000);
    // Split the length prefix, then send two frames without waiting for replies.
    try writeAll(io, remote, &.{0}, &.{}, timeout);
    try writeAll(io, remote, &.{query.len}, query, timeout);
    try writeAll(io, remote, &.{ 0, query.len }, query, timeout);
    for (0..2) |_| {
        var prefix: [2]u8 = undefined;
        try readExact(io, remote, &prefix, timeout);
        const size = std.mem.readInt(u16, &prefix, .big);
        var answer: [512]u8 = undefined;
        try std.testing.expect(size <= answer.len);
        try readExact(io, remote, answer[0..size], timeout);
        try std.testing.expectEqual(@as(u16, 0x1234), decode.id(answer[0..size]));
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, answer[6..8], .big));
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, answer[size - 4 .. size]);
    }
}
