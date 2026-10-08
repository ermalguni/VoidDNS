const std = @import("std");
const Record = @import("../domains/record.zig");
const message = @import("../dns/message.zig");
const decode = @import("../dns/decode.zig");
const resolver = @import("../resolver/resolver.zig");
const Cache = @import("../cache/cache.zig");
const Name = @import("../dns/name.zig");
const UpstreamPool = @import("../resolver/upstream.zig").Pool;
const log = std.log.scoped(.server);

pub fn serve(
    io: std.Io,
    listener: *const std.Io.net.Socket,
    records: []const Record,
    buffer: []u8,
    cache: *Cache,
    upstreams: *UpstreamPool,
) !void {
    while (true) {
        const query = try listener.receive(io, buffer);

        if (query.data.len < message.Header.len) continue;
        if (decode.flags(query.data) & message.Flags.response != 0) continue;

        logQuery(query.from, query.data);
        const query_id = decode.id(query.data);

        const response = resolver.resolve(
            io,
            query.data,
            buffer,
            records,
            cache,
            upstreams,
        ) catch |err| {
            log.warn("resolution failed client={f} id={d}: {s}", .{
                query.from, query_id, @errorName(err),
            });
            continue;
        };

        listener.send(io, &query.from, response) catch |err| {
            log.warn("reply failed client={f} id={d}: {s}", .{
                query.from, query_id, @errorName(err),
            });
        };
    }
}

fn logQuery(client: std.Io.net.IpAddress, packet: []const u8) void {
    if (!std.log.logEnabled(.debug, .server)) return;

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
        @intFromEnum(question.qtype),
        @intFromEnum(question.qclass),
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
