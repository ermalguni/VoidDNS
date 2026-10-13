const std = @import("std");
const config = @import("config/config.zig");
const document = @import("config/document.zig");
const Manager = @import("config/manager.zig").Manager;
const State = @import("state/state.zig").State;
const Worker = @import("server/server.zig").Worker;
const control = @import("server/control.zig");
const logging = @import("logging.zig");
const Apply = @import("state/apply.zig").Plan;
const Service = @import("blocklist/service.zig").Service;

// Keep all levels compiled in; configuration publication selects the threshold.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const usage = "Usage: VoidDNS --config <path> [--control-stdin]\n" ++
    "  --control-stdin: reload, refresh <source-id>, refresh-all, save <candidate-file>, quit; EOF quits\n";
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
        self.state = try self.settings.prepareState(io, diagnostic);
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
                    .reload => try reload(allocator, io, &manager, active, &next_generation),
                    .refresh => |id| try refresh(io, active, .{ .one = id }),
                    .refresh_all => try refresh(io, active, .all),
                    .save => |path| {
                        if (saveCandidate(allocator, io, &manager, path)) {
                            // Dispatch the reload notification directly: main
                            // must not enqueue into its own potentially full queue.
                            try reload(allocator, io, &manager, active, &next_generation);
                        }
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

fn reload(
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *Manager,
    active: *Application,
    next_generation: *u64,
) !void {
    var diagnostic: config.Diagnostic = .{};
    var candidate = manager.load(io, &diagnostic) catch |err| {
        std.log.err("reload rejected; active configuration unchanged: {s} ({s})", .{
            diagnostic.text(), @errorName(err),
        });
        return;
    };
    // After publication candidate owns the preceding configuration instead.
    defer candidate.deinit();
    var plan = Apply.prepare(allocator, io, &active.state, &active.settings, &candidate) catch |err| {
        std.log.err("reload preparation failed; active configuration unchanged: {s}", .{@errorName(err)});
        return;
    };
    defer plan.deinit();
    var runtime = Worker.Update.prepare(allocator, &active.settings, &candidate) catch |err| {
        std.log.err("reload resource preparation failed; active configuration unchanged: {s}", .{@errorName(err)});
        return;
    };
    defer runtime.deinit();
    const listener_changed = !active.settings.listen_address.eql(&candidate.listen_address);
    if (!plan.changed() and !runtime.needsLock() and !listener_changed and active.settings.log_level == candidate.log_level) {
        std.log.info("reload unchanged generation={d}", .{active.worker.generation});
        return;
    }

    // All fallible reservations precede any listener change or logical mutation.
    // Only main writes; capacities remain valid after releasing this guard.
    reserve(io, &active.state, &plan) catch |err| {
        std.log.err("reload reservation failed; active configuration unchanged: {s}", .{@errorName(err)});
        return;
    };
    if (listener_changed) active.worker.stop(io);
    const lock_runtime = listener_changed or runtime.needsLock();
    if (lock_runtime) active.worker.mutex.lockUncancelable(io);
    defer if (lock_runtime) active.worker.mutex.unlock(io);
    active.state.mutex.lockUncancelable(io);
    defer active.state.mutex.unlock(io);

    if (listener_changed) {
        active.worker.listen_address = candidate.listen_address;
        // A new worker cannot resolve until this transaction releases its
        // runtime guard. A failed bind/start publishes none of the candidate.
        start(active, io, next_generation) catch |err| {
            std.log.err("reload listener start failed: {s}; restoring previous listener", .{@errorName(err)});
            active.worker.listen_address = active.settings.listen_address;
            start(active, io, next_generation) catch |rollback_err| {
                std.log.err("reload listener rollback failed: {s}", .{@errorName(rollback_err)});
                return rollback_err;
            };
            std.log.warn("reload rejected; previous configuration restored", .{});
            return;
        };
    }

    plan.commit(&active.state, &active.settings, &candidate);
    if (!runtime.upstreams_changed) {
        // The running pool borrows this allocation, not the Config field itself.
        std.mem.swap([]const std.Io.net.IpAddress, &active.settings.upstream_addresses, &candidate.upstream_addresses);
    }
    if (runtime.needsLock()) runtime.commit(&active.worker);
    std.mem.swap(config.Config, &active.settings, &candidate);
    logging.setLevel(active.settings.log_level);
    std.log.info("reload complete generation={d}", .{active.worker.generation});
}

fn reserve(io: std.Io, state: *State, plan: *Apply) !void {
    try state.mutex.lock(io);
    defer state.mutex.unlock(io);
    try plan.reserve(state);
}

fn refresh(io: std.Io, active: *Application, selection: Service.Refresh) !void {
    var plan = active.state.lists.prepare(
        io,
        active.settings.definitions.sources.items,
        active.settings.base_dir,
        selection,
    ) catch |err| {
        std.log.err("refresh rejected; imported snapshots unchanged: {s}", .{@errorName(err)});
        return;
    };
    defer plan.deinit();
    if (!plan.changed()) {
        std.log.info("refresh unchanged", .{});
        return;
    }
    try active.state.mutex.lock(io);
    defer active.state.mutex.unlock(io);
    plan.reserve(&active.state.lists) catch |err| {
        std.log.err("refresh reservation failed; imported snapshots unchanged: {s}", .{@errorName(err)});
        return;
    };
    plan.commit(&active.state.lists);
    std.log.info("refresh complete generation={d}", .{active.worker.generation});
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
