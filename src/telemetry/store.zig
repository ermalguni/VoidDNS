const std = @import("std");
const sqlite = @import("sqlite");
const events = @import("event.zig");
pub const Event = events.Event;
pub const retention_ms: i64 = 7 * 24 * 60 * 60 * 1000;
pub const queue_capacity = 4096;
const batch_size = 256;

pub const schema = @embedFile("schema.sql");
const client_sql = "INSERT INTO clients(ip_address,first_seen_at_ms,last_seen_at_ms) VALUES(?,?,?) ON CONFLICT(ip_address) DO UPDATE SET first_seen_at_ms=min(first_seen_at_ms,excluded.first_seen_at_ms),last_seen_at_ms=max(last_seen_at_ms,excluded.last_seen_at_ms)";
const request_sql = "INSERT INTO requests(client_id,received_at_ms,domain,query_type,query_class,transport,resolution,rcode,duration_us,error) VALUES((SELECT id FROM clients WHERE ip_address=?),?,?,?,?,?,?,?,?,?)";

/// ARMv7 generic targets support at most 32-bit atomics. Saturating keeps a
/// prolonged loss incident from wrapping back to zero without taking a lock
/// on the DNS path. The API still exposes an integer, capped at 4,294,967,295.
const DropCounter = struct {
    value: std.atomic.Value(u32) = .init(0),

    pub fn load(self: *const DropCounter, comptime order: std.builtin.AtomicOrder) u64 {
        return self.value.load(order);
    }

    pub fn fetchAdd(self: *DropCounter, amount: usize, comptime order: std.builtin.AtomicOrder) u64 {
        const increment: u32 = @intCast(@min(amount, std.math.maxInt(u32)));
        var previous = self.value.load(.monotonic);
        while (previous != std.math.maxInt(u32)) {
            if (self.value.cmpxchgWeak(previous, previous +| increment, order, .monotonic)) |observed| {
                previous = observed;
            } else return previous;
        }
        return previous;
    }
};

/// Preserve full Unix milliseconds on 32-bit targets. Only the background
/// writer and health API use this mutex; DNS producers never acquire it.
const PersistedTime = struct {
    mutex: std.Io.Mutex = .init,
    value: i64 = 0,

    pub fn load(self: *PersistedTime, io: std.Io) i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value;
    }

    fn store(self: *PersistedTime, io: std.Io, value: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value = value;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: sqlite.Db,
    reader: sqlite.Db,
    writer_mutex: std.Io.Mutex = .init,
    reader_mutex: std.Io.Mutex = .init,
    queue_mutex: std.Io.Mutex = .init,
    queue: [queue_capacity]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    dropped: DropCounter = .{},
    healthy: std.atomic.Value(bool) = .init(true),
    last_persisted: PersistedTime = .{},
    future: ?std.Io.Future(void) = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        var writer = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true, .create = true } });
        errdefer writer.deinit();
        _ = try writer.one(i64, "PRAGMA busy_timeout=2000", .{}, .{});
        const version = (try writer.one(i64, "PRAGMA user_version", .{}, .{})).?;
        if (version != 0 and version != 1) return error.UnsupportedTelemetrySchema;
        const journal = (try writer.oneAlloc([]const u8, allocator, "PRAGMA journal_mode=WAL", .{}, .{})).?;
        defer allocator.free(journal);
        if (!std.mem.eql(u8, journal, "wal")) return error.WalUnavailable;
        try writer.exec("PRAGMA foreign_keys=ON", .{}, .{});
        const migration = try allocator.dupeSentinel(u8, std.mem.trim(u8, schema, " \r\n\t"), 0);
        defer allocator.free(migration);
        try writer.execMulti(migration, .{});
        var reader = try sqlite.Db.init(.{ .mode = .{ .File = path } });
        errdefer reader.deinit();
        _ = try reader.one(i64, "PRAGMA busy_timeout=1000", .{}, .{});
        self.* = .{ .allocator = allocator, .io = io, .writer = writer, .reader = reader };
        // Return bounded pages rather than allow an unbounded startup delete.
        _ = try self.cleanup(events.now(io));
        return self;
    }

    pub fn start(self: *Store) !void {
        self.future = try self.io.concurrent(run, .{self});
    }

    /// Call after DNS producers and HTTP handlers have been joined.
    pub fn deinit(self: *Store) void {
        if (self.future) |*future| future.cancel(self.io);
        while (self.flush()) {}
        self.reader.deinit();
        self.writer.deinit();
        self.allocator.destroy(self);
    }

    /// Bounded copy only: no allocations, database calls, or waiting for locks.
    pub fn submit(self: *Store, event: Event) void {
        if (!self.queue_mutex.tryLock()) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        defer self.queue_mutex.unlock(self.io);
        if (self.count == self.queue.len) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.queue[(self.head + self.count) % self.queue.len] = event;
        self.count += 1;
    }

    fn run(self: *Store) void {
        var next_cleanup = events.now(self.io);
        while (true) {
            const worked = self.flush();
            const now = events.now(self.io);
            if (now >= next_cleanup) {
                const deleted = self.cleanup(now) catch |err| blk: {
                    self.healthy.store(false, .monotonic);
                    std.log.warn("telemetry retention failed: {s}", .{@errorName(err)});
                    break :blk 0;
                };
                // Retry each tick while expired rows remain, bounded per pass.
                next_cleanup = if (deleted == 1000) now else now + 300_000;
            }
            if (!worked) self.io.sleep(.fromMilliseconds(250), .awake) catch return;
        }
    }

    pub fn flush(self: *Store) bool {
        var batch: [batch_size]Event = undefined;
        self.queue_mutex.lockUncancelable(self.io);
        const n = @min(self.count, batch.len);
        for (batch[0..n], 0..) |*event, i| event.* = self.queue[(self.head + i) % self.queue.len];
        self.head = (self.head + n) % self.queue.len;
        self.count -= n;
        self.queue_mutex.unlock(self.io);
        if (n == 0) return false;
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        self.writeBatch(batch[0..n]) catch |err| {
            _ = self.dropped.fetchAdd(n, .monotonic);
            self.healthy.store(false, .monotonic);
            std.log.warn("telemetry batch lost count={d}: {s}", .{ n, @errorName(err) });
            return true;
        };
        self.healthy.store(true, .monotonic);
        self.last_persisted.store(self.io, events.now(self.io));
        return true;
    }

    fn writeBatch(self: *Store, batch: []const Event) !void {
        try self.writer.exec("BEGIN IMMEDIATE", .{}, .{});
        errdefer self.writer.exec("ROLLBACK", .{}, .{}) catch {};
        var client = try self.writer.prepare(client_sql);
        defer client.deinit();
        var request = try self.writer.prepare(request_sql);
        defer request.deinit();
        const cutoff = events.now(self.io) - retention_ms;
        for (batch) |*event| {
            var ip_buffer: [15]u8 = undefined;
            const ip = try std.fmt.bufPrint(&ip_buffer, "{d}.{d}.{d}.{d}", .{ event.ip[0], event.ip[1], event.ip[2], event.ip[3] });
            client.reset();
            try client.exec(.{}, .{ ip, event.received_at_ms, event.received_at_ms });
            if (event.received_at_ms < cutoff) continue;
            request.reset();
            const name: ?[]const u8 = if (event.name_len != 0) event.name[0..event.name_len] else null;
            try request.exec(.{}, .{ ip, event.received_at_ms, name, event.query_type, event.query_class, @tagName(event.transport), @tagName(event.resolution), event.rcode, event.duration_us, event.failure });
        }
        try self.writer.exec("COMMIT", .{}, .{});
    }

    pub fn cleanup(self: *Store, now: i64) !usize {
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.writer.exec("DELETE FROM requests WHERE id IN (SELECT id FROM requests WHERE received_at_ms < ? ORDER BY received_at_ms,id LIMIT 1000)", .{}, .{now - retention_ms});
        return self.writer.rowsAffected();
    }

    pub fn rename(self: *Store, id: i64, name: ?[]const u8) !bool {
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.writer.exec("UPDATE clients SET name=? WHERE id=?", .{}, .{ name, id });
        return self.writer.rowsAffected() != 0;
    }
};

test "drop counter uses 32-bit atomics and saturates without wrapping" {
    var counter: DropCounter = .{};
    try std.testing.expectEqual(@as(u64, 0), counter.fetchAdd(1, .monotonic));
    try std.testing.expectEqual(@as(u64, 1), counter.load(.monotonic));
    counter.value.store(std.math.maxInt(u32) - 1, .monotonic);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32) - 1), counter.fetchAdd(batch_size, .monotonic));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), counter.load(.monotonic));
    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), counter.load(.monotonic));
}

test "persistence timestamp retains milliseconds beyond 32 bits" {
    var timestamp: PersistedTime = .{};
    try std.testing.expectEqual(@as(i64, 0), timestamp.load(std.testing.io));
    const now: i64 = 1_800_000_000_123;
    timestamp.store(std.testing.io, now);
    try std.testing.expectEqual(now, timestamp.load(std.testing.io));
}
