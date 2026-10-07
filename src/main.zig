const std = @import("std");
const message = @import("dns/message.zig");
const Record = @import("domains/record.zig");
const udp = @import("server/udp.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

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

    try udp.serve(io, &listener, &records, buffer);
}
