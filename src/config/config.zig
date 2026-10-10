const std = @import("std");
const filtering = @import("../state/filtering.zig");
const State = @import("../state/state.zig").State;
const definitions_module = @import("definitions.zig");
const document_module = @import("document.zig");
pub const Definitions = definitions_module.Definitions;
pub const Document = document_module.Document;

pub const max_file_size = 1024 * 1024;

/// Owns typed configuration definitions and paths, never runtime filtering state.
pub const Config = struct {
    listen_address: std.Io.net.IpAddress,
    upstream_addresses: []const std.Io.net.IpAddress,
    upstream_timeout_ms: u32,
    cache_capacity: usize,
    log_level: std.log.Level,
    allocator: std.mem.Allocator,
    definitions: Definitions,
    base_dir: []const u8,

    pub fn deinit(self: *Config) void {
        self.definitions.deinit(self.allocator);
        self.allocator.free(self.base_dir);
        self.allocator.free(self.upstream_addresses);
        self.* = undefined;
    }

    /// Materialize enabled sources only when preparing a runtime generation.
    /// The returned state is independently owned and must be deinitialized.
    pub fn prepareState(self: *const Config, io: std.Io, diagnostic: *Diagnostic) !State {
        diagnostic.* = .{};
        return filtering.build(self.allocator, io, &self.definitions, self.base_dir) catch |err| {
            diagnostic.set("blocks/allows: {s}", .{@errorName(err)});
            return err;
        };
    }
};

/// Caller-owned diagnostic storage remains valid after parsing and file cleanup.
pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.buffer);
        writer.print(format, args) catch {};
        self.len = writer.end;
    }

    fn invalid(self: *Diagnostic, comptime format: []const u8, args: anytype) error{InvalidConfig} {
        self.set(format, args);
        return error.InvalidConfig;
    }
};

/// Reads at most 1 MiB plus one byte to distinguish an exact-limit file from an
/// oversized file. Paths may be absolute or relative to the working directory.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diagnostic: *Diagnostic,
) !Config {
    diagnostic.* = .{};
    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size + 1),
    ) catch |err| {
        if (err == error.StreamTooLong) {
            diagnostic.set("configuration file exceeds the 1 MiB limit", .{});
            return error.FileTooLarge;
        }
        diagnostic.set("cannot read configuration file: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(contents);
    return parse(allocator, contents, std.fs.path.dirname(path) orelse ".", diagnostic);
}

/// Parse JSON-shaped data and build an independently owned runtime snapshot.
/// Neither the input bytes nor the intermediate document are retained.
pub fn parse(
    allocator: std.mem.Allocator,
    contents: []const u8,
    base_dir: []const u8,
    diagnostic: *Diagnostic,
) !Config {
    const parsed = try document_module.parse(allocator, contents, diagnostic);
    defer parsed.deinit();
    return fromDocument(allocator, &parsed.value, base_dir, diagnostic);
}

/// Validate semantic constraints even for directly constructed documents.
/// The returned config owns its addresses, paths, and normalized definitions.
pub fn fromDocument(
    allocator: std.mem.Allocator,
    document: *const Document,
    base_dir: []const u8,
    diagnostic: *Diagnostic,
) !Config {
    diagnostic.* = .{};
    if (document.schema_version != 1)
        return diagnostic.invalid("schema_version: unsupported version {d}; expected 1", .{document.schema_version});
    const listen = document.dns.listen;
    const listen_address = try address(listen.address, listen.port, "dns.listen", diagnostic);
    const servers = document.upstream.servers;
    if (servers.len == 0) return diagnostic.invalid("upstream.servers: expected at least one server", .{});
    if (document.upstream.timeout_ms == 0) return diagnostic.invalid("upstream.timeout_ms: expected a positive timeout", .{});

    const addresses = allocator.alloc(std.Io.net.IpAddress, servers.len) catch |err| {
        diagnostic.set("upstream.servers: {s}", .{@errorName(err)});
        return err;
    };
    errdefer allocator.free(addresses);
    for (servers, 0..) |server, index| {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "upstream.servers[{d}]", .{index}) catch unreachable;
        addresses[index] = try address(server.address, server.port, path, diagnostic);
    }

    var definitions = definitions_module.fromDocument(allocator, document) catch |err| {
        diagnostic.set("blocks/allows: {s}", .{@errorName(err)});
        return err;
    };
    errdefer definitions.deinit(allocator);
    const owned_base_dir = try allocator.dupe(u8, base_dir);

    return .{
        .listen_address = listen_address,
        .upstream_addresses = addresses,
        .upstream_timeout_ms = document.upstream.timeout_ms,
        .cache_capacity = document.cache.capacity,
        .log_level = document.logging.level,
        .allocator = allocator,
        .definitions = definitions,
        .base_dir = owned_base_dir,
    };
}

fn address(text: []const u8, port: u16, path: []const u8, diagnostic: *Diagnostic) !std.Io.net.IpAddress {
    if (port == 0) return diagnostic.invalid("{s}.port: expected a positive port", .{path});
    return std.Io.net.IpAddress.parseIp4(text, port) catch
        diagnostic.invalid("{s}.address: expected an IPv4 literal (for example 192.0.2.1)", .{path});
}

const minimal_json =
    \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]}}
;

fn expectInvalid(contents: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, contents, ".", &diagnostic));
}

test "minimal configuration applies every optional default" {
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, minimal_json, ".", &diagnostic);
    defer config.deinit();
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, config.listen_address.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 53), config.listen_address.ip4.port);
    try std.testing.expectEqual(@as(usize, 1), config.upstream_addresses.len);
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, config.upstream_addresses[0].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 53), config.upstream_addresses[0].ip4.port);
    try std.testing.expectEqual(@as(u32, 3000), config.upstream_timeout_ms);
    try std.testing.expectEqual(@as(usize, 4096), config.cache_capacity);
    try std.testing.expectEqual(std.log.Level.info, config.log_level);
}

test "explicit configuration owns addresses and preserves upstream order" {
    const input = try std.testing.allocator.dupe(u8,
        \\{"schema_version":1,"dns":{"listen":{"address":"0.0.0.0","port":65535}},
        \\ "upstream":{"servers":[{"address":"192.0.2.1","port":1},{"address":"8.8.8.8"}],"timeout_ms":4294967295},
        \\ "cache":{"capacity":0},"logging":{"level":"debug"}}
    );
    defer std.testing.allocator.free(input);
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, input, ".", &diagnostic);
    defer config.deinit();
    @memset(input, 0);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, config.listen_address.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 65535), config.listen_address.ip4.port);
    try std.testing.expectEqual(@as(usize, 2), config.upstream_addresses.len);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 1 }, config.upstream_addresses[0].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 1), config.upstream_addresses[0].ip4.port);
    try std.testing.expectEqual([4]u8{ 8, 8, 8, 8 }, config.upstream_addresses[1].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 53), config.upstream_addresses[1].ip4.port);
    try std.testing.expectEqual(std.math.maxInt(u32), config.upstream_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), config.cache_capacity);
    try std.testing.expectEqual(std.log.Level.debug, config.log_level);
}

test "required fields and schema version are validated" {
    const cases = [_][]const u8{
        "{}",
        "{\"schema_version\":\"1\"}",
        "{\"schema_version\":1.0}",
        "{\"schema_version\":1}",
        "{\"schema_version\":1,\"upstream\":{}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{}]}}",
        "{\"schema_version\":2,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}",
        "{\"schema_version\":0,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "unknown fields are rejected at every schema level" {
    const cases = [_][]const u8{
        "{\"schema_version\":1,\"records\":[]}",
        "{\"schema_version\":1,\"dns\":{\"typo\":true}}",
        "{\"schema_version\":1,\"dns\":{\"listen\":{\"host\":\"localhost\"}}}",
        "{\"schema_version\":1,\"upstream\":{\"retry\":true}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"weight\":2}]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":{\"ttl\":1}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"file\":\"log\"}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "ports reject zero overflow strings fractions and other types" {
    for ([_][]const u8{ "0", "65536", "-1", "\"53\"", "53.0", "5.3e1", "null", "true", "[]", "{}" }) |port| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"8.8.8.8\",\"port\":{s}}}]}}}}",
            .{port},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    try expectInvalid("{\"schema_version\":1,\"dns\":{\"listen\":{\"port\":0}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
}

test "timeout and capacity enforce integer ranges without coercion" {
    for ([_][]const u8{ "0", "4294967296", "-1", "\"3000\"", "1e3", "null" }) |timeout| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}],\"timeout_ms\":{s}}}}}",
            .{timeout},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    for ([_][]const u8{ "-1", "\"4096\"", "1.5", "18446744073709551616", "false" }) |capacity| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}]}},\"cache\":{{\"capacity\":{s}}}}}",
            .{capacity},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
}

test "IPv4 literals are required for listen and upstream addresses" {
    for ([_][]const u8{ "localhost", "::1", "1.2.3", "256.1.1.1", "01.2.3.4", "1.1.1.1:53", "" }) |ip| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"{s}\"}}]}}}}",
            .{ip},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    try expectInvalid("{\"schema_version\":1,\"dns\":{\"listen\":{\"address\":\"::1\"}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
}

test "wrong container and leaf types are rejected" {
    const cases = [_][]const u8{
        "[]",
        "null",
        "{\"schema_version\":true}",
        "{\"schema_version\":1,\"dns\":null}",
        "{\"schema_version\":1,\"dns\":{\"listen\":[]}}",
        "{\"schema_version\":1,\"upstream\":null}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":{}}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[null]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":123}]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":[49,46,49,46,49,46,49]}]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":null}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":[]}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":0}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":\"trace\"}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "malformed JSON duplicate fields comments and trailing content are rejected" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"schema_version\":1,}",
        "{\"schema_version\":01}",
        "// comment\n" ++ minimal_json,
        minimal_json ++ " {}",
        "{\"schema_version\":1,\"schema_version\":1}",
        "{\"schema_version\":1,\"schema_vers\\u0069on\":1}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[],\"servers\":[]}}",
        "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"address\":\"8.8.8.8\"}]}}",
    };
    for (cases) |input| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, input, ".", &diagnostic));
    }
}

test "parse and load accept exactly 1 MiB and reject larger input" {
    const input = try std.testing.allocator.alloc(u8, max_file_size + 1);
    defer std.testing.allocator.free(input);
    @memset(input, ' ');
    @memcpy(input[0..minimal_json.len], minimal_json);
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, input[0..max_file_size], ".", &diagnostic);
    config.deinit();
    try std.testing.expectError(error.FileTooLarge, parse(std.testing.allocator, input, ".", &diagnostic));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = input[0..max_file_size] });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    config = try load(std.testing.allocator, std.testing.io, path, &diagnostic);
    config.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = input });
    try std.testing.expectError(error.FileTooLarge, load(std.testing.allocator, std.testing.io, path, &diagnostic));
    try tmp.dir.deleteFile(std.testing.io, "config.json");
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, std.testing.io, path, &diagnostic));
}

fn parseWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var diagnostic: Diagnostic = .{};
    var config = try parse(allocator, minimal_json, ".", &diagnostic);
    defer config.deinit();
}

test "allocation failures release partial parser and address ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithFailingAllocator, .{});
}

test "unified configuration owns explicit filtering and loads paths relative to its file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "domains.txt", .data = "Imported.Example.\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data =
        \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]},
        \\"blocks":{"domains":["Blocked.Example."],"lists":[
        \\{"id":"file","source":{"kind":"file","value":"domains.txt"},"format":"domains"}]},
        \\"allows":{"domains":["Allowed.Example"]}}
    });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(path);
    var diagnostic: Diagnostic = .{};
    var config = try load(allocator, std.testing.io, path, &diagnostic);
    defer config.deinit();
    var state = try config.prepareState(std.testing.io, &diagnostic);
    defer state.deinit();
    try std.testing.expect(state.domains.isBlocked("blocked.example"));
    try std.testing.expect(state.domains.isAllowed("allowed.example"));
    try std.testing.expect(state.lists.contains("imported.example"));
    try std.testing.expect(!state.lists.contains("sub.imported.example"));
}

test "unified filtering retains strict nested validation" {
    var diagnostic: Diagnostic = .{};
    const prefix = "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
    try expectInvalid(prefix ++ "\"blocks\":{\"unknown\":true}}");
    try expectInvalid(prefix ++ "\"allows\":{\"domains\":\"wrong\"}}");
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, prefix ++ "\"blocks\":{\"domains\":[],\"domains\":[]}}", ".", &diagnostic));
}

const filtering_json =
    \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]},
    \\"blocks":{"domains":["Blocked.Example."],"lists":[
    \\{"id":"off","name":"Owned name","enabled":false,"source":{"kind":"file","value":"missing.txt"},"format":"hosts"},
    \\{"id":"remote","source":{"kind":"url","value":"http://127.0.0.1:1/list"},"format":"domains"}]},
    \\"allows":{"domains":["Allowed.Example"]}}
;

test "filtering definitions and base directory do not borrow parsing inputs" {
    const allocator = std.testing.allocator;
    const input = try allocator.dupe(u8, filtering_json);
    defer allocator.free(input);
    const base = try allocator.dupe(u8, "owned-directory");
    defer allocator.free(base);
    var diagnostic: Diagnostic = .{};
    var config = try parse(allocator, input, base, &diagnostic);
    defer config.deinit();
    @memset(input, 0);
    @memset(base, 0);
    try std.testing.expectEqualStrings("owned-directory", config.base_dir);
    try std.testing.expectEqualStrings("blocked.example", config.definitions.blocks.items[0]);
    try std.testing.expectEqualStrings("allowed.example", config.definitions.allows.items[0]);
    const source = config.definitions.sources.items[0];
    try std.testing.expectEqualStrings("off", source.id);
    try std.testing.expectEqualStrings("Owned name", source.name.?);
    try std.testing.expectEqualStrings("missing.txt", source.source.value);
    try std.testing.expect(!source.enabled);
    try std.testing.expectEqualStrings("remote", config.definitions.sources.items[1].id);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/list", config.definitions.sources.items[1].source.value);
}

fn parseFilteringWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var diagnostic: Diagnostic = .{};
    var config = try parse(allocator, filtering_json, "owned-directory", &diagnostic);
    defer config.deinit();
}

test "allocation failures release partial filtering definitions and base directory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseFilteringWithFailingAllocator, .{});
}

test "prepared runtime state outlives its configuration definitions" {
    var diagnostic: Diagnostic = .{};
    var state = blk: {
        var config = try parse(std.testing.allocator,
            \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]},
            \\"blocks":{"domains":["Blocked.Example."],"lists":[
            \\{"id":"off","name":"Disabled","enabled":false,"source":{"kind":"file","value":"missing"},"format":"hosts"}]},
            \\"allows":{"domains":["Allowed.Example"]}}
        , ".", &diagnostic);
        defer config.deinit();
        break :blk try config.prepareState(std.testing.io, &diagnostic);
    };
    defer state.deinit();
    try std.testing.expect(state.domains.isBlocked("blocked.example"));
    try std.testing.expect(state.domains.isAllowed("allowed.example"));
    const source = state.lists.sources.get("off").?.source;
    try std.testing.expectEqualStrings("Disabled", source.name.?);
    try std.testing.expectEqualStrings("missing", source.source.value);
    try std.testing.expect(!source.enabled);
}

test "all filtering structure and disabled definition validation occurs during parsing" {
    const prefix = "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
    const cases = [_]struct { []const u8, anyerror }{
        .{ "\"blocks\":null}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":{}}}", error.InvalidConfig },
        .{ "\"blocks\":{\"domains\":[1]}}", error.InvalidConfig },
        .{ "\"allows\":{\"unknown\":[]}}", error.InvalidConfig },
        .{ "\"allows\":{\"lists\":[]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"source\":{\"kind\":\"file\",\"value\":\"missing\",\"typo\":true}}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":0,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":\"other\",\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":0,\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"other\"}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":0}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"name\":null,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidConfig },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"bad id\",\"enabled\":false,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidSourceId },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"name\":\"\",\"enabled\":false,\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"hosts\"}]}}", error.InvalidSourceName },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":\"file\",\"value\":\"\"},\"format\":\"hosts\"}]}}", error.InvalidSourceLocation },
        .{ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"enabled\":false,\"source\":{\"kind\":\"url\",\"value\":\"https://example.test/list\"},\"format\":\"hosts\"}]}}", error.InvalidUrlFormat },
    };
    for (cases) |case| {
        const contents = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, case[0] });
        defer std.testing.allocator.free(contents);
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(case[1], parse(std.testing.allocator, contents, ".", &diagnostic));
    }
}

test "runtime snapshots independently own data from an editable document" {
    const allocator = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var first: Config = undefined;
    var second: Config = undefined;
    {
        const input = try allocator.dupe(u8, filtering_json);
        defer allocator.free(input);
        var parsed = try document_module.parse(allocator, input, &diagnostic);
        defer parsed.deinit();
        @memset(input, 0);
        try std.testing.expectEqualStrings("Blocked.Example.", parsed.value.blocks.domains[0]);
        first = try fromDocument(allocator, &parsed.value, "first-directory", &diagnostic);
        errdefer first.deinit();
        parsed.value.upstream.servers = &.{.{ .address = "8.8.8.8", .port = 5353 }};
        parsed.value.upstream.timeout_ms = 5000;
        parsed.value.blocks.domains = &.{"Changed.Example."};
        parsed.value.blocks.lists = &.{};
        second = try fromDocument(allocator, &parsed.value, "second-directory", &diagnostic);
    }
    defer first.deinit();
    defer second.deinit();
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, first.upstream_addresses[0].ip4.bytes);
    try std.testing.expectEqual(@as(u32, 3000), first.upstream_timeout_ms);
    try std.testing.expectEqualStrings("blocked.example", first.definitions.blocks.items[0]);
    try std.testing.expectEqualStrings("Owned name", first.definitions.sources.items[0].name.?);
    try std.testing.expectEqualStrings("missing.txt", first.definitions.sources.items[0].source.value);
    try std.testing.expectEqualStrings("allowed.example", first.definitions.allows.items[0]);
    try std.testing.expectEqualStrings("first-directory", first.base_dir);
    try std.testing.expectEqual([4]u8{ 8, 8, 8, 8 }, second.upstream_addresses[0].ip4.bytes);
    try std.testing.expectEqual(@as(u16, 5353), second.upstream_addresses[0].ip4.port);
    try std.testing.expectEqual(@as(u32, 5000), second.upstream_timeout_ms);
    try std.testing.expectEqualStrings("changed.example", second.definitions.blocks.items[0]);
    try std.testing.expectEqual(@as(usize, 0), second.definitions.sources.items.len);
}

test "typed document serialization round trips editable values and omitted source names" {
    var diagnostic: Diagnostic = .{};
    var parsed = try document_module.parse(std.testing.allocator, filtering_json, &diagnostic);
    defer parsed.deinit();
    parsed.value.dns.listen.port = 5353;
    parsed.value.logging.level = .debug;
    const serialized = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(serialized);
    const decoded = try document_module.parse(std.testing.allocator, serialized, &diagnostic);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(parsed.value, decoded.value);
    try std.testing.expectEqualStrings("Blocked.Example.", decoded.value.blocks.domains[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.value.blocks.lists[1].name);
    var runtime = try fromDocument(std.testing.allocator, &decoded.value, ".", &diagnostic);
    defer runtime.deinit();
    try std.testing.expectEqualStrings("blocked.example", runtime.definitions.blocks.items[0]);
}

test "constructed documents receive the same semantic validation as parsed input" {
    const valid: Document = .{
        .schema_version = 1,
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
    };
    var document = valid;
    var diagnostic: Diagnostic = .{};
    document.schema_version = 2;
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.dns.listen.port = 0;
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.upstream.timeout_ms = 0;
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.upstream.servers = &.{};
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.upstream.servers = &.{.{ .address = "localhost" }};
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.upstream.servers = &.{.{ .address = "1.1.1.1", .port = 0 }};
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.blocks.domains = &.{"*.example"};
    try std.testing.expectError(error.InvalidDomain, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    document.allows.domains = &.{"127.0.0.1"};
    try std.testing.expectError(error.InvalidDomain, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    document = valid;
    const Source = @import("../blocklist/source.zig").Source;
    var source: Source = .{
        .id = "disabled",
        .enabled = false,
        .source = .{ .kind = .file, .value = "missing" },
        .format = .domains,
    };
    source.id = "bad id";
    document.blocks.lists = (&source)[0..1];
    try std.testing.expectError(error.InvalidSourceId, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    source.id = "disabled";
    source.source.value = "\xff";
    try std.testing.expectError(error.InvalidSourceLocation, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
    source.source.value = "caf\xc3\xa9.txt";
    var unicode_config = try fromDocument(std.testing.allocator, &document, ".", &diagnostic);
    defer unicode_config.deinit();
    try std.testing.expectEqualStrings("caf\xc3\xa9.txt", unicode_config.definitions.sources.items[0].source.value);
    source.source.value = "missing";
    document.blocks.lists = &.{ source, source };
    try std.testing.expectError(error.DuplicateSourceId, fromDocument(std.testing.allocator, &document, ".", &diagnostic));
}

test "strict token checks recognize escaped field names and reject byte arrays for strings" {
    const prefix = "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
    try expectInvalid("{\"schema_vers\\u0069on\":\"1\",\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
    try expectInvalid("{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"po\\u0072t\":\"53\"}]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"domains\":[[97,46,98]]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"lists\":[{\"id\":[97],\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"domains\"}]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"source\":{\"kind\":\"file\",\"value\":[97]},\"format\":\"domains\"}]}}");
}
