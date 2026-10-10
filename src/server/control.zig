const std = @import("std");

pub const max_command_bytes = 4096;
pub const request_capacity = 16;

/// Save paths own their bytes; the consumer releases them after handling.
pub const Request = union(enum) {
    reload,
    save: []u8,
    quit,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        switch (self) {
            .save => |path| allocator.free(path),
            else => {},
        }
    }
};

pub const Failure = struct { generation: u64, err: anyerror };
pub const Notification = union(enum) {
    request: Request,
    worker_failed: Failure,
    control_failed: anyerror,
};

/// Bounded request mailbox with reserved failure slots. A finishing worker
/// never waits for request capacity, so cancellation/join cannot deadlock.
pub const Mailbox = struct {
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    space: std.Io.Condition = .init,
    requests: [request_capacity]Request = undefined,
    first: usize = 0,
    count: usize = 0,
    worker_failure: ?Failure = null,
    control_failure: ?anyerror = null,

    pub fn put(self: *Mailbox, io: std.Io, request: Request) std.Io.Cancelable!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (self.count == self.requests.len) try self.space.wait(io, &self.mutex);
        self.requests[(self.first + self.count) % self.requests.len] = request;
        self.count += 1;
        self.available.signal(io);
    }

    pub fn receive(self: *Mailbox, io: std.Io) std.Io.Cancelable!Notification {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.worker_failure) |failure| {
                self.worker_failure = null;
                return .{ .worker_failed = failure };
            }
            if (self.control_failure) |err| {
                self.control_failure = null;
                return .{ .control_failed = err };
            }
            if (self.count != 0) {
                const request = self.requests[self.first];
                self.first = (self.first + 1) % self.requests.len;
                self.count -= 1;
                self.space.signal(io);
                return .{ .request = request };
            }
            try self.available.wait(io, &self.mutex);
        }
    }

    pub fn workerFailed(self: *Mailbox, io: std.Io, failure: Failure) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.worker_failure = failure;
        self.available.signal(io);
    }

    fn controlFailed(self: *Mailbox, io: std.Io, err: anyerror) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.control_failure = err;
        self.available.signal(io);
    }

    /// Called only after all producers have joined.
    pub fn deinit(self: *Mailbox, allocator: std.mem.Allocator) void {
        for (0..self.count) |offset| {
            self.requests[(self.first + offset) % self.requests.len].deinit(allocator);
        }
        self.* = undefined;
    }
};

pub const Stdin = struct {
    allocator: std.mem.Allocator,
    mailbox: *Mailbox,

    pub fn run(self: *Stdin, io: std.Io) anyerror!void {
        self.readCommands(io) catch |err| {
            if (err != error.Canceled) self.mailbox.controlFailed(io, err);
            return err;
        };
    }

    fn readCommands(self: *Stdin, io: std.Io) !void {
        var input: [1024]u8 = undefined;
        var line: [max_command_bytes]u8 = undefined;
        var length: usize = 0;
        var oversized = false;
        while (true) {
            const count = std.Io.File.stdin().readStreaming(io, &.{&input}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count == 0) {
                if (!oversized and length != 0 and try self.command(io, line[0..length])) return;
                try self.mailbox.put(io, .quit);
                return;
            }
            for (input[0..count]) |byte| {
                if (byte == '\n') {
                    if (oversized) {
                        std.log.warn("control command exceeds {d} bytes", .{max_command_bytes});
                    } else if (try self.command(io, line[0..length])) return;
                    length = 0;
                    oversized = false;
                } else if (length < line.len) {
                    line[length] = byte;
                    length += 1;
                } else {
                    oversized = true;
                }
            }
        }
    }

    fn command(self: *Stdin, io: std.Io, line: []const u8) !bool {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) return false;
        if (std.mem.eql(u8, text, "reload")) {
            try self.mailbox.put(io, .reload);
        } else if (std.mem.eql(u8, text, "quit")) {
            try self.mailbox.put(io, .quit);
            return true;
        } else if (std.mem.startsWith(u8, text, "save ")) {
            const path = std.mem.trim(u8, text[5..], " \t");
            if (path.len == 0) {
                std.log.warn("control save requires a candidate-file path", .{});
                return false;
            }
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            try self.mailbox.put(io, .{ .save = owned });
        } else {
            std.log.warn("unknown control command; expected reload, save <candidate-file>, or quit", .{});
        }
        return false;
    }
};

test "worker failure bypasses full bounded request queue" {
    var mailbox: Mailbox = .{};
    defer mailbox.deinit(std.testing.allocator);
    for (0..request_capacity) |_| try mailbox.put(std.testing.io, .reload);
    mailbox.workerFailed(std.testing.io, .{ .generation = 7, .err = error.TestWorkerFailure });
    const notification = try mailbox.receive(std.testing.io);
    try std.testing.expectEqual(@as(u64, 7), notification.worker_failed.generation);
    try std.testing.expectEqual(error.TestWorkerFailure, notification.worker_failed.err);
    try std.testing.expectEqual(request_capacity, mailbox.count);
}

test "queued save path owns bytes independently of command buffer" {
    var mailbox: Mailbox = .{};
    defer mailbox.deinit(std.testing.allocator);
    var producer: Stdin = .{ .allocator = std.testing.allocator, .mailbox = &mailbox };
    var line = "save candidate.json".*;
    try std.testing.expect(!try producer.command(std.testing.io, &line));
    @memset(&line, 'x');
    const notification = try mailbox.receive(std.testing.io);
    defer notification.request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("candidate.json", notification.request.save);
}
