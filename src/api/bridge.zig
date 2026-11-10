const std = @import("std");

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    if_match: ?[]const u8,
};
pub const Response = struct {
    status: u16 = 200,
    body: []const u8,
    revision: ?u64 = null,
};
pub const Bridge = struct {
    context: *anyopaque,
    handleFn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,

    pub fn handle(self: *Bridge, allocator: std.mem.Allocator, request: Request) !Response {
        return self.handleFn(self.context, allocator, request);
    }
};

/// A caller keeps its request arena alive until main has completed the call.
/// Once queued, waiting is uncancelable: HTTP cancellation cannot invalidate a
/// request still owned by main. Mailbox closure completes all outstanding calls.
pub const Call = struct {
    allocator: std.mem.Allocator,
    request: Request,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    done: bool = false,
    response: anyerror!Response = error.ShuttingDown,

    pub fn finish(self: *Call, io: std.Io, response: anyerror!Response) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.response = response;
        self.done = true;
        self.condition.signal(io);
    }

    pub fn awaitResult(self: *Call, io: std.Io) !Response {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.done) self.condition.waitUncancelable(io, &self.mutex);
        return self.response;
    }
};
