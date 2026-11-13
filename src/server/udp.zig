const std = @import("std");
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const resolver = @import("../resolver/resolver.zig");
const Cache = @import("../cache/cache.zig");
const Name = @import("../dns/name.zig");
const UpstreamPool = @import("../resolver/upstream.zig").Pool;
const logging = @import("../logging.zig");
const State = @import("../state/state.zig").State;
const log = std.log.scoped(.server);

pub fn serve(
    io: std.Io,
    listener: *const std.Io.net.Socket,
    buffer: []u8,
    cache: *Cache,
    upstreams: *UpstreamPool,
    state: *State,
    runtime_mutex: *std.Io.Mutex,
    telemetry: ?*@import("../telemetry/store.zig").Store,
) !void {
    while (true) {
        const query = try listener.receive(io, buffer);
        if (query.data.len >= message.Header.len and decode.flags(query.data) & message.Flags.response != 0) continue;

        var event = @import("../telemetry/event.zig").Event.begin(io, query.from.ip4.bytes, query.data, .udp);
        var response_packet: ?[]const u8 = null;
        var failure: ?anyerror = null;
        defer if (telemetry) |store| {
            event.finish(io, response_packet, failure);
            store.submit(event);
        };

        if (query.data.len < message.Header.len) {
            failure = error.InvalidQuestion;
            continue;
        }

        logQuery(query.from, query.data);
        const query_id = decode.id(query.data);

        const response = resolved: {
            try runtime_mutex.lock(io);
            defer runtime_mutex.unlock(io);
            break :resolved resolver.resolveTracked(
                io,
                query.data,
                buffer,
                cache,
                upstreams,
                state,
                .udp,
                &event.resolution,
            ) catch |err| {
                failure = err;
                if (err == error.Canceled) return err;
                log.warn("resolution failed client={f} id={d}: {s}", .{
                    query.from, query_id, @errorName(err),
                });
                continue;
            };
        };
        response_packet = response;

        listener.send(io, &query.from, response) catch |err| {
            failure = err;
            if (err == error.Canceled) return err;
            log.warn("reply failed client={f} id={d}: {s}", .{
                query.from, query_id, @errorName(err),
            });
        };
    }
}

fn logQuery(client: std.Io.net.IpAddress, packet: []const u8) void {
    if (!logging.enabled(.debug)) return;

    const question = decode.question(packet) catch |err| {
        log.debug("query client={f} id={d} question_unavailable={s}", .{
            client, decode.id(packet), @errorName(err),
        });
        return;
    };
    const type_name: []const u8 = switch (question.qtype) {
        .a => "A",
        .aaaa => "AAAA",
        else => "unknown",
    };
    log.debug("query client={f} id={d} domain={f} type={s}({d}) class={d}", .{
        client,
        question.id,
        LoggedName{ .name = &question.name },
        type_name,
        @backingInt(question.qtype),
        @backingInt(question.qclass),
    });
}

// Only constructed from a successfully decoded name. Escape arbitrary DNS label
// bytes so names remain unambiguous and cannot inject whitespace or terminal codes.
const LoggedName = struct {
    name: *const Name,

    pub fn format(self: LoggedName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.name.wire[0] == 0) return writer.writeByte('.');

        var offset: usize = 0;
        while (self.name.wire[offset] != 0) {
            const size = self.name.wire[offset];
            offset += 1;
            for (self.name.wire[offset..][0..size]) |byte| {
                if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
                    try writer.writeByte(byte);
                } else {
                    try writer.print("\\{d:0>3}", .{byte});
                }
            }
            try writer.writeByte('.');
            offset += size;
        }
    }
};
