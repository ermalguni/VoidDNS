const std = @import("std");
const config = @import("config/config.zig");
const Management = @import("api/management.zig").Management;
const ApiServer = @import("api/server.zig").Server;
const Manager = @import("config/manager.zig").Manager;
const State = @import("state/state.zig").State;
const Worker = @import("server/server.zig").Worker;
const control = @import("server/control.zig");
const logging = @import("logging.zig");
const Telemetry = @import("telemetry/store.zig").Store;

// Keep all levels compiled in; configuration publication selects the threshold.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn,
};

const usage = "Usage: VoidDNS --config <path> [--database <path>] [--control-stdin]\n" ++
    "  --database: SQLite client history (default: $HOME/.config/voiddns/voiddns.sqlite3)\n" ++
    "  --control-stdin: reload, refresh <source-id>, refresh-all, save <candidate-file>, quit; EOF quits\n";

const Arguments = struct {
    path: []const u8,
    control_stdin: bool,
    database: ?[]const u8 = null,

    fn parse(args: []const []const u8) !Arguments {
        var path: ?[]const u8 = null;
        var control_stdin = false;
        var database: ?[]const u8 = null;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--config")) {
                if (path != null or index + 1 >= args.len or args[index + 1].len == 0)
                    return error.InvalidArguments;
                index += 1;
                path = args[index];
            } else if (std.mem.eql(u8, args[index], "--database")) {
                if (database != null or index + 1 >= args.len or args[index + 1].len == 0) return error.InvalidArguments;
                index += 1;
                database = args[index];
            } else if (std.mem.eql(u8, args[index], "--control-stdin")) {
                if (control_stdin) return error.InvalidArguments;
                control_stdin = true;
            } else return error.InvalidArguments;
        }
        return .{ .path = path orelse return error.InvalidArguments, .control_stdin = control_stdin, .database = database };
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

    const database_path = try databasePath(allocator, options.database, init.environ_map.get("HOME"));
    defer allocator.free(database_path);
    if (std.fs.path.dirname(database_path)) |parent| {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, parent, if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_dir);
    }
    const new_database = std.Io.Dir.cwd().createFile(io, database_path, .{
        .exclusive = true,
        .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (new_database) |file| file.close(io);
    const telemetry = try Telemetry.init(allocator, io, database_path);
    defer telemetry.deinit();
    try telemetry.start();

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
    active.worker.telemetry = telemetry;
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
        .telemetry = telemetry,
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

fn databasePath(allocator: std.mem.Allocator, override: ?[]const u8, home: ?[]const u8) ![:0]u8 {
    if (override) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or eqPath(path, ":memory:")) return error.InvalidDatabasePath;
        return allocator.dupeSentinel(u8, path, 0);
    }
    const directory = home orelse return error.HomeDirectoryUnavailable;
    if (!std.fs.path.isAbsolute(directory)) return error.InvalidHomeDirectory;
    return std.fmt.allocPrintSentinel(allocator, "{s}/.config/voiddns/voiddns.sqlite3", .{directory}, 0);
}

fn eqPath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "database argument and home default are independent of config location" {
    const a = std.testing.allocator;
    const options = try Arguments.parse(&.{ "VoidDNS", "--config", "config.json", "--database", "history.sqlite3" });
    const custom = try databasePath(a, options.database, null);
    defer a.free(custom);
    try std.testing.expectEqualStrings("history.sqlite3", custom);
    const default = try databasePath(a, null, "/home/operator");
    defer a.free(default);
    try std.testing.expectEqualStrings("/home/operator/.config/voiddns/voiddns.sqlite3", default);
    try std.testing.expectError(error.HomeDirectoryUnavailable, databasePath(a, null, null));
    try std.testing.expectError(error.InvalidHomeDirectory, databasePath(a, null, "relative"));
    try std.testing.expectError(error.InvalidArguments, Arguments.parse(&.{ "VoidDNS", "--config", "config.json", "--database" }));
    try std.testing.expectError(error.InvalidArguments, Arguments.parse(&.{ "VoidDNS", "--config", "config.json", "--database", "a", "--database", "b" }));
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
    _ = @import("telemetry/api.zig");
}
