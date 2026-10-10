const std = @import("std");
const Config = @import("../config/config.zig").Config;
const State = @import("../state/state.zig").State;
const Record = @import("../domains/record.zig");
const message = @import("../dns/message.zig");
const Cache = @import("../cache/cache.zig");
const UpstreamPool = @import("../resolver/upstream.zig").Pool;
const control = @import("control.zig");
const udp = @import("udp.zig");

const records = [_]Record{.{
    .name = "home.test",
    .a = .{ 192, 0, 2, 10 },
    .aaaa = .{
        0x20, 0x01, 0x0d, 0xb8,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0x10,
    },
}};

/// Main owns this context at a stable address, along with the borrowed config
/// and state. stop joins before releasing the listener or any borrowed memory.
/// A stopped worker retains its cache and can restart for reload rollback.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    settings: *const Config,
    state: *const State,
    mailbox: *control.Mailbox,
    cache: Cache,
    upstreams: UpstreamPool,
    buffer: []u8,
    listener: ?std.Io.net.Socket = null,
    future: ?std.Io.Future(anyerror!void) = null,
    generation: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        settings: *const Config,
        state: *const State,
        mailbox: *control.Mailbox,
    ) !Worker {
        var cache = try Cache.init(allocator, settings.cache_capacity);
        errdefer cache.deinit();
        const buffer = try allocator.alloc(u8, message.packet_capacity);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .settings = settings,
            .state = state,
            .mailbox = mailbox,
            .cache = cache,
            .upstreams = try UpstreamPool.init(settings.upstream_addresses, settings.upstream_timeout_ms),
            .buffer = buffer,
        };
    }

    pub fn start(self: *Worker, io: std.Io, generation: u64) !void {
        std.debug.assert(self.future == null and self.listener == null);
        self.generation = generation;
        self.listener = try self.settings.listen_address.bind(io, .{
            .mode = .dgram,
            .protocol = .udp,
        });
        errdefer {
            self.listener.?.close(io);
            self.listener = null;
        }
        self.future = try io.concurrent(run, .{ self, io });
        std.log.info("DNS listening on {f}; upstreams={d} timeout_ms={d} generation={d}", .{
            self.settings.listen_address,
            self.settings.upstream_addresses.len,
            self.settings.upstream_timeout_ms,
            generation,
        });
    }

    fn run(self: *Worker, io: std.Io) anyerror!void {
        udp.serve(io, &self.listener.?, &records, self.buffer, &self.cache, &self.upstreams, self.state) catch |err| {
            if (err != error.Canceled) {
                self.mailbox.workerFailed(io, .{ .generation = self.generation, .err = err });
            }
            return err;
        };
        self.mailbox.workerFailed(io, .{ .generation = self.generation, .err = error.UnexpectedWorkerExit });
        return error.UnexpectedWorkerExit;
    }

    pub fn stop(self: *Worker, io: std.Io) void {
        if (self.future) |*future| {
            // cancel requests cooperative cancellation AND joins. The serve
            // path propagates Canceled through idle receive and upstream I/O.
            future.cancel(io) catch {};
            self.future = null;
        }
        if (self.listener) |listener| {
            listener.close(io);
            self.listener = null;
        }
    }

    pub fn deinit(self: *Worker, io: std.Io) void {
        self.stop(io);
        self.allocator.free(self.buffer);
        self.cache.deinit();
        self.* = undefined;
    }
};
