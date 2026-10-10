const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const document = @import("document.zig");

const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false,
};

/// Single-owner configuration file operations. The application serializes calls
/// on its main task and emits lifecycle notifications only after save succeeds.
/// This is not a cross-process writer lock: external writers are last-writer-wins.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Manager {
        return .{ .allocator = allocator, .path = try allocator.dupe(u8, path) };
    }

    pub fn deinit(self: *Manager) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn load(self: *const Manager, io: std.Io, diagnostic: *config.Diagnostic) !config.Config {
        return config.load(self.allocator, io, self.path, diagnostic);
    }

    /// Validate and serialize a typed document before creating any file.
    /// Source definitions are validated, but their files/URLs are never read.
    /// Atomic replacement deliberately gives the new file private 0600 POSIX
    /// permissions (subject to umask), rather than preserving the old file mode.
    /// A pre-rename failure preserves the original. A post-rename directory sync
    /// failure reports that the new file is visible but crash durability is unknown.
    pub fn save(self: *Manager, io: std.Io, candidate_document: *const document.Document, diagnostic: *config.Diagnostic) !void {
        var candidate = try config.fromDocument(self.allocator, candidate_document, std.fs.path.dirname(self.path) orelse ".", diagnostic);
        candidate.deinit();
        const contents = try std.json.Stringify.valueAlloc(self.allocator, candidate_document, stringify_options);
        defer self.allocator.free(contents);
        if (contents.len > config.max_file_size) {
            diagnostic.set("serialized configuration exceeds the 1 MiB limit", .{});
            return error.FileTooLarge;
        }
        self.replace(io, contents, diagnostic) catch |err| {
            if (diagnostic.len == 0) diagnostic.set("cannot save configuration file: {s}", .{@errorName(err)});
            return err;
        };
    }

    fn replace(self: *Manager, io: std.Io, contents: []const u8, diagnostic: *config.Diagnostic) !void {
        // An iterable handle is required on Linux: an O_PATH directory cannot
        // be fsynced. Holding the directory also anchors temp creation and rename.
        const dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(self.path) orelse ".", .{ .iterate = true });
        defer dir.close(io);
        var temporary = try dir.createFileAtomic(io, std.fs.path.basename(self.path), .{
            .replace = true,
            .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file,
        });
        defer temporary.deinit(io);
        try temporary.file.writeStreamingAll(io, contents);
        try temporary.file.sync(io);
        try temporary.replace(io);
        syncDirectory(dir, io) catch |err| {
            diagnostic.set("configuration replaced, but directory sync failed; crash durability is unknown: {s}", .{@errorName(err)});
            return err;
        };
    }
};

/// Zig 0.16 has no Dir.sync; POSIX directory handles can use File.sync. Other
/// targets retain atomic replacement and file sync without a directory guarantee.
fn syncDirectory(dir: std.Io.Dir, io: std.Io) !void {
    switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            const file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
            try file.sync(io);
        },
        else => {},
    }
}

const minimal_json =
    \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]}}
;

const minimal_document: document.Document = .{
    .schema_version = 1,
    .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
};

fn expectContents(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(config.max_file_size + 1));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "manager owns its path and saves valid definitions without source IO" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = minimal_json });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(path);
    var manager = try Manager.init(allocator, path);
    defer manager.deinit();
    @memset(path, 0);
    const replacement: document.Document = .{
        .schema_version = 1,
        .dns = .{ .listen = .{ .address = "127.0.0.2", .port = 5353 } },
        .upstream = .{ .servers = &.{.{ .address = "8.8.8.8", .port = 9953 }}, .timeout_ms = 1250 },
        .cache = .{ .capacity = 17 },
        .logging = .{ .level = .debug },
        .blocks = .{
            .domains = &.{"BLOCKED.Example."},
            .lists = &.{
                .{ .id = "file", .source = .{ .kind = .file, .value = "missing.txt" }, .format = .domains },
                .{ .id = "remote", .name = "Remote list", .source = .{ .kind = .url, .value = "http://127.0.0.1:1/list" }, .format = .domains },
            },
        },
        .allows = .{ .domains = &.{"Allowed.Example."} },
    };
    var diagnostic: config.Diagnostic = .{};
    try manager.save(io, &replacement, &diagnostic);
    var loaded = try manager.load(io, &diagnostic);
    defer loaded.deinit();
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 2 }, loaded.listen_address.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 5353), loaded.listen_address.ip4.port);
    try std.testing.expectEqual([4]u8{ 8, 8, 8, 8 }, loaded.upstream_addresses[0].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 9953), loaded.upstream_addresses[0].ip4.port);
    try std.testing.expectEqual(@as(u32, 1250), loaded.upstream_timeout_ms);
    try std.testing.expectEqual(@as(usize, 17), loaded.cache_capacity);
    try std.testing.expectEqual(std.log.Level.debug, loaded.log_level);
    try std.testing.expectEqualStrings("blocked.example", loaded.definitions.blocks.items[0]);
    try std.testing.expectEqualStrings("allowed.example", loaded.definitions.allows.items[0]);
    try std.testing.expectEqual(@as(usize, 2), loaded.definitions.sources.items.len);
    const file_source = loaded.definitions.sources.items[0];
    try std.testing.expectEqualStrings("file", file_source.id);
    try std.testing.expect(file_source.name == null);
    try std.testing.expect(file_source.enabled);
    try std.testing.expect(file_source.source.kind == .file);
    try std.testing.expectEqualStrings("missing.txt", file_source.source.value);
    const remote_source = loaded.definitions.sources.items[1];
    try std.testing.expectEqualStrings("Remote list", remote_source.name.?);
    try std.testing.expect(remote_source.enabled);
    try std.testing.expect(remote_source.source.kind == .url);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/list", remote_source.source.value);
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const stat = try tmp.dir.statFile(io, "config.json", .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
    }
    var iterator = tmp.dir.iterate();
    const entry = (try iterator.next(io)).?;
    try std.testing.expectEqualStrings("config.json", entry.name);
    try std.testing.expect((try iterator.next(io)) == null);
}

test "invalid saves preserve original bytes and create no temporary files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = minimal_json });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(path);
    var manager = try Manager.init(allocator, path);
    defer manager.deinit();
    var diagnostic: config.Diagnostic = .{};
    var invalid = minimal_document;
    invalid.schema_version = 2;
    try std.testing.expectError(error.InvalidConfig, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    invalid = minimal_document;
    invalid.upstream.servers = &.{};
    try std.testing.expectError(error.InvalidConfig, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    invalid = minimal_document;
    invalid.dns.listen.port = 0;
    try std.testing.expectError(error.InvalidConfig, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    invalid = minimal_document;
    invalid.upstream.timeout_ms = 0;
    try std.testing.expectError(error.InvalidConfig, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    invalid = minimal_document;
    invalid.blocks.lists = &.{.{
        .id = "off",
        .enabled = false,
        .source = .{ .kind = .url, .value = "ftp://example.test/list" },
        .format = .domains,
    }};
    try std.testing.expectError(error.UnsupportedUriScheme, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    const source: @import("../blocklist/source.zig").Source = .{
        .id = "same",
        .enabled = false,
        .source = .{ .kind = .file, .value = "missing" },
        .format = .hosts,
    };
    invalid.blocks.lists = &.{ source, source };
    try std.testing.expectError(error.DuplicateSourceId, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    invalid = minimal_document;
    invalid.allows.domains = &.{"*.test"};
    try std.testing.expectError(error.InvalidDomain, manager.save(io, &invalid, &diagnostic));
    try expectContents(tmp.dir, "config.json", minimal_json);
    var iterator = tmp.dir.iterate();
    try std.testing.expectEqualStrings("config.json", (try iterator.next(io)).?.name);
    try std.testing.expect((try iterator.next(io)) == null);
}

test "save bounds serialized output and preserves an exact-limit document on rejection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fs.path.join(allocator, &.{ base, "new.json" });
    defer allocator.free(path);
    var manager = try Manager.init(allocator, path);
    defer manager.deinit();
    var sources = [_]@import("../blocklist/source.zig").Source{.{
        .id = "file",
        .source = .{ .kind = .file, .value = "x" },
        .format = .domains,
    }};
    var replacement = minimal_document;
    replacement.blocks.lists = &sources;
    const small = try std.json.Stringify.valueAlloc(allocator, &replacement, stringify_options);
    defer allocator.free(small);
    const exact_location_len = config.max_file_size - small.len + 1;
    const location = try allocator.alloc(u8, exact_location_len + 1);
    defer allocator.free(location);
    @memset(location, 'x');
    sources[0].source.value = location[0..exact_location_len];
    var diagnostic: config.Diagnostic = .{};
    try manager.save(io, &replacement, &diagnostic);
    var loaded = try manager.load(io, &diagnostic);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(sources[0].source.value, loaded.definitions.sources.items[0].source.value);
    const saved = try tmp.dir.readFileAlloc(io, "new.json", allocator, .limited(config.max_file_size + 1));
    defer allocator.free(saved);
    try std.testing.expectEqual(config.max_file_size, saved.len);
    sources[0].source.value = location;
    try std.testing.expectError(error.FileTooLarge, manager.save(io, &replacement, &diagnostic));
    try expectContents(tmp.dir, "new.json", saved);
    // Escaping can exceed the serialized limit even for a smaller string.
    @memset(location, '\\');
    sources[0].source.value = location[0 .. config.max_file_size / 2];
    try std.testing.expectError(error.FileTooLarge, manager.save(io, &replacement, &diagnostic));
    try expectContents(tmp.dir, "new.json", saved);
}

test "failed atomic replacement cleans temporary and retains destination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "config.json", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json/original", .data = "retain me" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(path);
    var manager = try Manager.init(allocator, path);
    defer manager.deinit();
    var diagnostic: config.Diagnostic = .{};
    try std.testing.expectError(error.IsDir, manager.save(io, &minimal_document, &diagnostic));
    try std.testing.expect(diagnostic.len != 0);
    try expectContents(tmp.dir, "config.json/original", "retain me");
    var iterator = tmp.dir.iterate();
    try std.testing.expectEqualStrings("config.json", (try iterator.next(io)).?.name);
    try std.testing.expect((try iterator.next(io)) == null);
}
