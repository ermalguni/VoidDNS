const std = @import("std");
const message = @import("dns/message.zig");
const Record = @import("domains/record.zig");
const udp = @import("server/udp.zig");
const Cache = @import("cache/cache.zig");
const UpstreamPool = @import("resolver/upstream.zig").Pool;

// Per-query logging is useful during development; use .info for normal operation.
pub const std_options: std.Options = .{ .log_level = .debug };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const upstream_addresses = [_]std.Io.net.IpAddress{
        try std.Io.net.IpAddress.parseIp4("1.1.1.1", message.port),
        try std.Io.net.IpAddress.parseIp4("8.8.8.8", message.port),
    };
    var upstreams = try UpstreamPool.init(&upstream_addresses);

    var cache = try Cache.init(allocator, 4096);
    defer cache.deinit();

    const buffer = try allocator.alloc(u8, message.packet_capacity);
    defer allocator.free(buffer);

    const address = try std.Io.net.IpAddress.parseIp4(
        "127.0.0.1",
        message.port,
    );
    const listener = try address.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
    });
    defer listener.close(io);

    const records = [_]Record{
        .{
            .name = "home.test",
            .a = .{ 192, 0, 2, 10 },
            .aaaa = .{
                0x20, 0x01, 0x0d, 0xb8,
                0,    0,    0,    0,
                0,    0,    0,    0,
                0,    0,    0,    0x10,
            },
        },
    };

    std.log.info(
        "DNS listening on {f}; upstream port {d}",
        .{ address, message.port },
    );

    try udp.serve(io, &listener, &records, buffer, &cache, &upstreams);
}

test {
    _ = @import("dns/edns.zig");
    _ = @import("resolver/resolver.zig");
}
