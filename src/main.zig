const std = @import("std");
const config = @import("config/config.zig");
const document = @import("config/document.zig");
const Manager = @import("config/manager.zig").Manager;
const State = @import("state/state.zig").State;
const Worker = @import("server/server.zig").Worker;
const control = @import("server/control.zig");
const logging = @import("logging.zig");

// Keep all levels compiled in; main selects the threshold between workers.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const usage = "Usage: VoidDNS --config <path> [--control-stdin]\n" ++
    "  --control-stdin: read reload, save <candidate-file>, quit; EOF quits\n";
const max_candidate_bytes = config.max_file_size;

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

/// Heap allocation keeps every borrowed config/state/worker address stable
/// across publication. Main alone owns and destroys these generations.
const Generation = struct {
    settings: config.Config,
    state: State,
    worker: Worker,

    fn prepare(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *Manager,
        mailbox: *control.Mailbox,
        diagnostic: *config.Diagnostic,
    ) !*Generation {
        const self = try allocator.create(Generation);
        errdefer allocator.destroy(self);
        self.settings = try manager.load(io, diagnostic);
        errdefer self.settings.deinit();
        self.state = try self.settings.prepareState(io, diagnostic);
        errdefer self.state.deinit();
        self.worker = try Worker.init(allocator, &self.settings, &self.state, mailbox);
        return self;
    }

    fn destroy(self: *Generation, allocator: std.mem.Allocator, io: std.Io) void {
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
    var active = Generation.prepare(allocator, io, &manager, &mailbox, &diagnostic) catch |err| {
        std.log.err("configuration '{s}': {s} ({s})", .{
            options.path, diagnostic.text(), @errorName(err),
        });
        return err;
    };
    defer active.destroy(allocator, io);
    var next_generation: u64 = 1;
    logging.setLevel(active.settings.log_level);
    try start(active, io, &next_generation);

    var producer: control.Stdin = .{ .allocator = allocator, .mailbox = &mailbox };
    var control_task: ?std.Io.Future(anyerror!void) = if (options.control_stdin)
        try io.concurrent(control.Stdin.run, .{ &producer, io })
    else
        null;
    defer if (control_task) |*task| {
        task.cancel(io) catch {};
    };

    // Without --control-stdin there is no producer: wait only for DNS failure.
    while (true) {
        const notification = try mailbox.receive(io);
        switch (notification) {
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
                    .quit => return,
                    .reload => try reload(allocator, io, &manager, &mailbox, &active, &next_generation),
                    .save => |path| {
                        if (saveCandidate(allocator, io, &manager, path)) {
                            // Dispatch the reload notification directly: main
                            // must not enqueue into its own potentially full queue.
                            try reload(allocator, io, &manager, &mailbox, &active, &next_generation);
                        }
                    },
                }
            },
        }
    }
}

fn start(generation: *Generation, io: std.Io, next_generation: *u64) !void {
    const id = next_generation.*;
    next_generation.* +%= 1;
    try generation.worker.start(io, id);
}

fn reload(
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *Manager,
    mailbox: *control.Mailbox,
    active: **Generation,
    next_generation: *u64,
) !void {
    var diagnostic: config.Diagnostic = .{};
    // Validation, source fetches, RAM indexes, cache, and buffers are prepared
    // while the current worker still serves its immutable snapshot.
    const candidate = Generation.prepare(allocator, io, manager, mailbox, &diagnostic) catch |err| {
        std.log.err("reload rejected; current DNS worker remains active: {s} ({s})", .{
            diagnostic.text(), @errorName(err),
        });
        return;
    };
    var published = false;
    defer if (!published) candidate.destroy(allocator, io);

    const previous = active.*;
    previous.worker.stop(io);
    logging.setLevel(candidate.settings.log_level);
    start(candidate, io, next_generation) catch |err| {
        std.log.err("reload start failed: {s}; restoring previous generation", .{@errorName(err)});
        logging.setLevel(previous.settings.log_level);
        start(previous, io, next_generation) catch |rollback_err| {
            std.log.err("reload rollback failed: {s}", .{@errorName(rollback_err)});
            return rollback_err;
        };
        std.log.warn("reload rejected; previous DNS configuration restored", .{});
        return;
    };

    active.* = candidate;
    published = true;
    previous.destroy(allocator, io);
    std.log.info("reload complete generation={d}", .{candidate.worker.generation});
}

fn saveCandidate(allocator: std.mem.Allocator, io: std.Io, manager: *Manager, path: []const u8) bool {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_candidate_bytes)) catch |err| {
        std.log.err("save candidate '{s}' could not be read: {s}", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(contents);
    var diagnostic: config.Diagnostic = .{};
    const parsed = document.parse(allocator, contents, &diagnostic) catch |err| {
        std.log.err("save rejected: {s} ({s})", .{ diagnostic.text(), @errorName(err) });
        return false;
    };
    defer parsed.deinit();
    // Manager validates definitions relative to the TARGET configuration
    // directory, not the candidate file's parent.
    manager.save(io, &parsed.value, &diagnostic) catch |err| {
        std.log.err("save rejected: {s} ({s})", .{ diagnostic.text(), @errorName(err) });
        return false;
    };
    std.log.info("configuration saved; requesting reload", .{});
    return true;
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
