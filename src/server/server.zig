const std = @import("std");
const Config = @import("../config/config.zig").Config;
const State = @import("../state/state.zig").State;
const message = @import("../dns/message.zig");
const Cache = @import("../cache/cache.zig");
const UpstreamPool = @import("../resolver/upstream.zig").Pool;
const control = @import("control.zig");
const udp = @import("udp.zig");

/// Main owns this context and its borrowed state at stable addresses. The
/// runtime mutex guards cache/upstream use; acquire it before state.mutex.
/// A stopped worker retains its cache and can restart for listener rollback.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    listen_address: std.Io.net.IpAddress,
    state: *State,
    mutex: std.Io.Mutex = .init,
    mailbox: *control.Mailbox,
    cache: Cache,
    upstreams: UpstreamPool,
    buffer: []u8,
    listener: ?std.Io.net.Socket = null,
    future: ?std.Io.Future(anyerror!void) = null,
    generation: u64 = 0,

    /// Prepared without the runtime lock. commit cannot fail and leaves the
    /// retired cache here for deinit after publication releases the lock.
    pub const Update = struct {
        upstreams_changed: bool,
        cache: ?Cache = null,
        upstreams: ?UpstreamPool = null,
        timeout: ?std.Io.Clock.Duration = null,

        pub fn prepare(allocator: std.mem.Allocator, previous: *const Config, candidate: *const Config) !Update {
            const upstreams_changed = changed: {
                if (previous.upstream_addresses.len != candidate.upstream_addresses.len) break :changed true;
                for (previous.upstream_addresses, candidate.upstream_addresses) |*old, *new| {
                    if (!old.eql(new)) break :changed true;
                }
                break :changed false;
            };
            var update: Update = .{ .upstreams_changed = upstreams_changed };
            errdefer update.deinit();
            if (upstreams_changed) {
                update.upstreams = try UpstreamPool.init(candidate.upstream_addresses, candidate.upstream_timeout_ms);
            } else if (previous.upstream_timeout_ms != candidate.upstream_timeout_ms) {
                update.timeout = .{ .raw = .fromMilliseconds(candidate.upstream_timeout_ms), .clock = .awake };
            }
            if (upstreams_changed or previous.cache_capacity != candidate.cache_capacity) {
                update.cache = try Cache.init(allocator, candidate.cache_capacity);
            }
            return update;
        }

        pub fn needsLock(self: *const Update) bool {
            return self.cache != null or self.upstreams != null or self.timeout != null;
        }

        /// Caller holds worker.mutex. Call once, then deinit outside the lock.
        pub fn commit(self: *Update, worker: *Worker) void {
            if (self.cache) |*cache| std.mem.swap(Cache, &worker.cache, cache);
            if (self.upstreams) |upstreams| {
                worker.upstreams = upstreams;
            } else if (self.timeout) |timeout| {
                worker.upstreams.response_timeout = timeout;
            }
        }

        pub fn deinit(self: *Update) void {
            if (self.cache) |*cache| cache.deinit();
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        settings: *const Config,
        state: *State,
        mailbox: *control.Mailbox,
    ) !Worker {
        var cache = try Cache.init(allocator, settings.cache_capacity);
        errdefer cache.deinit();
        const buffer = try allocator.alloc(u8, message.packet_capacity);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .listen_address = settings.listen_address,
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
        self.listener = try self.listen_address.bind(io, .{
            .mode = .dgram,
            .protocol = .udp,
        });
        errdefer {
            self.listener.?.close(io);
            self.listener = null;
        }
        self.future = try io.concurrent(run, .{ self, io });
        std.log.info("DNS listening on {f}; generation={d}", .{ self.listen_address, generation });
    }

    fn run(self: *Worker, io: std.Io) anyerror!void {
        udp.serve(io, &self.listener.?, self.buffer, &self.cache, &self.upstreams, self.state, &self.mutex) catch |err| {
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

test "runtime updates preserve cache and rotation unless upstreams or capacity change" {
    const config = @import("../config/config.zig");
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.parse(std.testing.allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"192.0.2.1"},{"address":"192.0.2.2"}]},"cache":{"capacity":4}}
    , ".", &diagnostic);
    defer previous.deinit();
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var mailbox: control.Mailbox = .{};
    const cases = [_]enum { unchanged, timeout, capacity, order, port, count }{
        .unchanged, .timeout, .capacity, .order, .port, .count,
    };
    for (cases) |case| {
        var worker = try Worker.init(std.testing.allocator, &previous, &state, &mailbox);
        defer worker.deinit(std.testing.io);
        worker.upstreams.next_index = 1;
        const old_slots = worker.cache.slots.ptr;
        const old_addresses = worker.upstreams.addresses.ptr;
        const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" ++
            "\x04home\x04test\x00\x00\x01\x00\x01";
        var answer_buffer: [512]u8 = undefined;
        const question = try @import("../dns/decode.zig").question(query);
        const answer = try @import("../dns/encode.zig").address(&question, &.{ 192, 0, 2, 10 }, 60, &answer_buffer);
        try worker.cache.put(@import("../cache/key.zig").fromQuery(query).?, answer, 0);

        // The candidate borrows this fixture; production candidates own these
        // allocations separately, even when all addresses are semantically equal.
        var addresses = [_]std.Io.net.IpAddress{ previous.upstream_addresses[0], previous.upstream_addresses[1] };
        var candidate = previous;
        candidate.upstream_addresses = &addresses;
        switch (case) {
            .unchanged => {},
            .timeout => candidate.upstream_timeout_ms = 4500,
            .capacity => candidate.cache_capacity = 8,
            .order => std.mem.swap(std.Io.net.IpAddress, &addresses[0], &addresses[1]),
            .port => addresses[0].ip4.port = 5353,
            .count => candidate.upstream_addresses = addresses[0..1],
        }
        const upstreams_changed = case == .order or case == .port or case == .count;
        const cache_changed = upstreams_changed or case == .capacity;
        var update = try Worker.Update.prepare(std.testing.allocator, &previous, &candidate);
        defer update.deinit();
        try std.testing.expectEqual(upstreams_changed, update.upstreams_changed);
        try std.testing.expectEqual(case != .unchanged, update.needsLock());
        // Preparation never touches live runtime data.
        try std.testing.expectEqual(old_slots, worker.cache.slots.ptr);
        try std.testing.expectEqual(@as(usize, 1), worker.upstreams.next_index);
        if (update.needsLock()) {
            try worker.mutex.lock(std.testing.io);
            defer worker.mutex.unlock(std.testing.io);
            update.commit(&worker);
        }
        try std.testing.expectEqual(candidate.cache_capacity, worker.cache.slots.len);
        try std.testing.expectEqual(!cache_changed, old_slots == worker.cache.slots.ptr);
        try std.testing.expectEqual(!cache_changed, worker.cache.get(query, 0, &answer_buffer) != null);
        try std.testing.expectEqual(@as(usize, if (upstreams_changed) 0 else 1), worker.upstreams.next_index);
        try std.testing.expectEqual(if (upstreams_changed) candidate.upstream_addresses.ptr else old_addresses, worker.upstreams.addresses.ptr);
        try std.testing.expectEqual(@as(i64, candidate.upstream_timeout_ms), worker.upstreams.response_timeout.raw.toMilliseconds());
    }
}

test "runtime preparation failure leaves worker resources unchanged" {
    const config = @import("../config/config.zig");
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.parse(std.testing.allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"192.0.2.1"}]},"cache":{"capacity":4}}
    , ".", &diagnostic);
    defer previous.deinit();
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var mailbox: control.Mailbox = .{};
    var worker = try Worker.init(std.testing.allocator, &previous, &state, &mailbox);
    defer worker.deinit(std.testing.io);
    const slots = worker.cache.slots.ptr;
    const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.2", 53)};
    var candidate = previous;
    candidate.upstream_addresses = &addresses;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Worker.Update.prepare(failing.allocator(), &previous, &candidate));
    try std.testing.expectEqual(slots, worker.cache.slots.ptr);
    try std.testing.expectEqual(previous.upstream_addresses.ptr, worker.upstreams.addresses.ptr);
    try std.testing.expectEqual(@as(i64, previous.upstream_timeout_ms), worker.upstreams.response_timeout.raw.toMilliseconds());

    // Unchanged and timeout-only plans require no allocations.
    candidate = previous;
    var unchanged = try Worker.Update.prepare(failing.allocator(), &previous, &candidate);
    defer unchanged.deinit();
    try std.testing.expect(!unchanged.needsLock());
    candidate.upstream_timeout_ms += 1;
    var timeout = try Worker.Update.prepare(failing.allocator(), &previous, &candidate);
    defer timeout.deinit();
    try std.testing.expect(timeout.needsLock());
}
