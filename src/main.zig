const std = @import("std");
const config = @import("config/config.zig");
const Management = @import("api/management.zig").Management;
const ApiServer = @import("api/server.zig").Server;
const Manager = @import("config/manager.zig").Manager;
const State = @import("state/state.zig").State;
const Worker = @import("server/server.zig").Worker;
const control = @import("server/control.zig");
const logging = @import("logging.zig");

// Keep all levels compiled in; configuration publication selects the threshold.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const usage = "Usage: VoidDNS --config <path> [--control-stdin]\n" ++
    "  --control-stdin: reload, refresh <source-id>, refresh-all, save <candidate-file>, quit; EOF quits\n";

const Arguments = struct {
    path: []const u8,
    control_stdin: bool,

    fn parse(args: []const []const u8) !Arguments {
        var path: ?[]const u8 = null;
        var control_stdin = false;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--config")) {
                if (path != null or index + 1 >= args.len or args[index + 1].len == 0)
                    return error.InvalidArguments;
                index += 1;
                path = args[index];
            } else if (std.mem.eql(u8, args[index], "--control-stdin")) {
                if (control_stdin) return error.InvalidArguments;
                control_stdin = true;
            } else return error.InvalidArguments;
        }
        return .{ .path = path orelse return error.InvalidArguments, .control_stdin = control_stdin };
    }
};

/// Stable owner of independently lived configuration, managed state, and worker.
/// Main alone serializes writers; queries borrow only guarded published data.
const Application = struct {
    settings: config.Config,
    state: State,
    worker: Worker,

    fn prepare(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *Manager,
        mailbox: *control.Mailbox,
        diagnostic: *config.Diagnostic,
    ) !*Application {
        const self = try allocator.create(Application);
        errdefer allocator.destroy(self);
        self.settings = try manager.load(io, diagnostic);
        errdefer self.settings.deinit();
        self.state = try manager.prepareStartupState(io, &self.settings, diagnostic);
        errdefer self.state.deinit();
        self.state.records = self.settings.records;
        self.worker = try Worker.init(allocator, &self.settings, &self.state, mailbox);
        return self;
    }

    fn destroy(self: *Application, allocator: std.mem.Allocator, io: std.Io) void {
        self.worker.deinit(io);
        self.state.deinit();
        self.settings.deinit();
        allocator.destroy(self);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    const options = Arguments.parse(args) catch |err| {
        std.debug.print("{s}", .{usage});
        return err;
    };

    // Use a concurrent, cancellable backend explicitly, not an async fallback
    // that might run the DNS loop inline and prevent main from handling reload.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var manager = try Manager.init(allocator, options.path);
    defer manager.deinit();
    var mailbox: control.Mailbox = .{};
    defer mailbox.deinit(allocator);
    var diagnostic: config.Diagnostic = .{};
    const active = Application.prepare(allocator, io, &manager, &mailbox, &diagnostic) catch |err| {
        std.log.err("configuration '{s}': {s} ({s})", .{
            options.path, diagnostic.text(), @errorName(err),
        });
        return err;
    };
    defer active.destroy(allocator, io);
    var next_generation: u64 = 1;
    logging.setLevel(active.settings.log_level);
    try start(active, io, &next_generation);

    var management: Management = .{
        .allocator = allocator,
        .io = io,
        .manager = &manager,
        .settings = &active.settings,
        .state = &active.state,
        .worker = &active.worker,
        .mailbox = &mailbox,
        .next_generation = &next_generation,
    };
    var bridge = management.asBridge();
    var api: ?ApiServer = null;
    defer {
        // Unblock queued HTTP handlers before joining the transport.
        management.close();
        if (api) |*server| server.deinit();
    }
    if (active.settings.api.enabled) {
        api = try ApiServer.init(allocator, io, active.settings.api, active.settings.ui, &bridge);
        try api.?.start();
    }

    var producer: control.Stdin = .{ .allocator = allocator, .mailbox = &mailbox };
    var control_task: ?std.Io.Future(anyerror!void) = if (options.control_stdin)
        try io.concurrent(control.Stdin.run, .{ &producer, io })
    else
        null;
    defer if (control_task) |*task| {
        task.cancel(io) catch {};
    };

    // Main owns publication; background operations only prepare candidates.
    while (true) {
        const notification = try mailbox.receive(io);
        switch (notification) {
            .operation_ready => {
                management.complete();
                if (management.quit_requested and management.job == null) return;
            },
            .worker_failed => |failure| {
                // A joined worker may have reported just before cancellation.
                // Restart/rollback gets a fresh ID, so this cannot kill it.
                if (failure.generation != active.worker.generation) continue;
                std.log.err("DNS worker generation={d} failed: {s}", .{
                    failure.generation, @errorName(failure.err),
                });
                return failure.err;
            },
            .control_failed => |err| {
                std.log.err("stdin control failed: {s}", .{@errorName(err)});
                return err;
            },
            .request => |request| {
                defer request.deinit(allocator);
                switch (request) {
                    .quit => {
                        if (management.job == null) return;
                        management.quit_requested = true;
                    },
                    .api => |call| management.handleCall(call),
                    else => management.stdin(request) catch |err| {
                        std.log.err("control request failed: {s}", .{@errorName(err)});
                    },
                }
            },
        }
    }
}

fn start(generation: *Application, io: std.Io, next_generation: *u64) !void {
    const id = next_generation.*;
    next_generation.* +%= 1;
    try generation.worker.start(io, id);
}

test "stdin control is explicit and config argument remains required" {
    const plain = try Arguments.parse(&.{ "VoidDNS", "--config", "example.json" });
    try std.testing.expect(!plain.control_stdin);
    const controlled = try Arguments.parse(&.{ "VoidDNS", "--control-stdin", "--config", "example.json" });
    try std.testing.expect(controlled.control_stdin);
    try std.testing.expectEqualStrings("example.json", controlled.path);
    try std.testing.expectError(error.InvalidArguments, Arguments.parse(&.{ "VoidDNS", "--control-stdin" }));
    try std.testing.expectError(error.InvalidArguments, Arguments.parse(&.{ "VoidDNS", "--config", "example.json", "--control-stdin", "--control-stdin" }));
}

test {
    _ = @import("dns/edns.zig");
    _ = @import("resolver/resolver.zig");
    _ = @import("config/config.zig");
    _ = @import("config/manager.zig");
    _ = @import("server/control.zig");
    _ = @import("logging.zig");
}
