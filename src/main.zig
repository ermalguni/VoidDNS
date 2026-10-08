const std = @import("std");
const message = @import("dns/message.zig");
const Record = @import("domains/record.zig");
const udp = @import("server/udp.zig");
const Cache = @import("cache/cache.zig");
const UpstreamPool = @import("resolver/upstream.zig").Pool;

const config = @import("config.zig");
const logging = @import("logging.zig");

// Keep all levels compiled in; the startup configuration filters them at runtime.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: VoidDNS --config <path>\n", .{});
        return;
    }
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--config") or args[2].len == 0) {
        std.log.err("usage: VoidDNS --config <path>", .{});
        return error.InvalidArguments;
    }
    const path = args[2];

    var diagnostic: config.Diagnostic = .{};
    var settings = config.load(allocator, io, path, &diagnostic) catch |err| {
        std.log.err("configuration '{s}': {s} ({s})", .{
            path, diagnostic.text(), @errorName(err),
        });
        return err;
    };
    defer settings.deinit();
    logging.setLevel(settings.log_level);

    // The pool borrows settings' addresses, which remain alive until shutdown.
    var upstreams = try UpstreamPool.init(settings.upstream_addresses, settings.upstream_timeout_ms);

    var cache = try Cache.init(allocator, settings.cache_capacity);
    defer cache.deinit();

    const buffer = try allocator.alloc(u8, message.packet_capacity);
    defer allocator.free(buffer);

    const address = settings.listen_address;
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
        "DNS listening on {f}; upstreams={d} timeout_ms={d}",
        .{ address, settings.upstream_addresses.len, settings.upstream_timeout_ms },
    );

    try udp.serve(io, &listener, &records, buffer, &cache, &upstreams, &settings.state);
}

test {
    _ = @import("dns/edns.zig");
    _ = @import("resolver/resolver.zig");
    _ = @import("config.zig");
}
