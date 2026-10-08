const std = @import("std");

pub const max_file_size = 1024 * 1024;

/// Owns only the parsed upstream addresses, not the JSON input or its strings.
pub const Config = struct {
    listen_address: std.Io.net.IpAddress,
    upstream_addresses: []const std.Io.net.IpAddress,
    upstream_timeout_ms: u32,
    cache_capacity: usize,
    log_level: std.log.Level,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.upstream_addresses);
        self.* = undefined;
    }
};

/// Caller-owned diagnostic storage remains valid after parsing and file cleanup.
pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
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
    return parse(allocator, contents, diagnostic);
}

/// Parses a complete strict JSON document. The returned config does not borrow
/// from `contents`; callers may release it immediately. Numbers must be JSON
/// integer tokens, never quoted numbers, fractions, or exponent notation.
pub fn parse(
    allocator: std.mem.Allocator,
    contents: []const u8,
    diagnostic: *Diagnostic,
) !Config {
    diagnostic.* = .{};
    if (contents.len > max_file_size) {
        diagnostic.set("configuration file exceeds the 1 MiB limit", .{});
        return error.FileTooLarge;
    }

    var scanner = std.json.Scanner.initCompleteInput(allocator, contents);
    defer scanner.deinit();
    var location: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&location);
    // Keeping number lexemes distinct from strings prevents std.json's typed
    // integer coercions and preserves usize/u32 range checks without float loss.
    const parsed = std.json.parseFromTokenSource(std.json.Value, allocator, &scanner, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| {
        diagnostic.set("JSON at line {d}, column {d}: {s}", .{
            location.getLine(), location.getColumn(), @errorName(err),
        });
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = try object(parsed.value, "$", &.{ "schema_version", "dns", "upstream", "cache", "logging" }, diagnostic);
    const version = try integer(u32, try required(root, "schema_version", "schema_version", diagnostic), "schema_version", 0, diagnostic);
    if (version != 1) return diagnostic.invalid("schema_version: unsupported version {d}; expected 1", .{version});

    var listen_address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 53 } };
    if (root.get("dns")) |dns_value| {
        const dns = try object(dns_value, "dns", &.{"listen"}, diagnostic);
        if (dns.get("listen")) |listen_value| {
            const listen = try object(listen_value, "dns.listen", &.{ "address", "port" }, diagnostic);
            listen_address = try address(listen, "dns.listen", "127.0.0.1", diagnostic);
        }
    }

    const upstream = try object(
        try required(root, "upstream", "upstream", diagnostic),
        "upstream",
        &.{ "servers", "timeout_ms" },
        diagnostic,
    );
    const servers_value = try required(upstream, "servers", "upstream.servers", diagnostic);
    if (servers_value != .array) return diagnostic.invalid("upstream.servers: expected an array", .{});
    const servers = servers_value.array.items;
    if (servers.len == 0) return diagnostic.invalid("upstream.servers: expected at least one server", .{});
    const timeout = if (upstream.get("timeout_ms")) |value|
        try integer(u32, value, "upstream.timeout_ms", 1, diagnostic)
    else
        3000;

    var cache_capacity: usize = 4096;
    if (root.get("cache")) |value| {
        const cache = try object(value, "cache", &.{"capacity"}, diagnostic);
        if (cache.get("capacity")) |capacity| {
            cache_capacity = try integer(usize, capacity, "cache.capacity", 0, diagnostic);
        }
    }

    var log_level: std.log.Level = .info;
    if (root.get("logging")) |value| {
        const logging = try object(value, "logging", &.{"level"}, diagnostic);
        if (logging.get("level")) |level| {
            if (level != .string) return diagnostic.invalid("logging.level: expected a string", .{});
            log_level = std.meta.stringToEnum(std.log.Level, level.string) orelse
                return diagnostic.invalid("logging.level: expected err, warn, info, or debug", .{});
        }
    }

    const addresses = allocator.alloc(std.Io.net.IpAddress, servers.len) catch |err| {
        diagnostic.set("upstream.servers: {s}", .{@errorName(err)});
        return err;
    };
    errdefer allocator.free(addresses);
    for (servers, 0..) |server_value, index| {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "upstream.servers[{d}]", .{index}) catch unreachable;
        const server = try object(server_value, path, &.{ "address", "port" }, diagnostic);
        addresses[index] = try address(server, path, null, diagnostic);
    }

    return .{
        .listen_address = listen_address,
        .upstream_addresses = addresses,
        .upstream_timeout_ms = timeout,
        .cache_capacity = cache_capacity,
        .log_level = log_level,
        .allocator = allocator,
    };
}

fn object(value: std.json.Value, path: []const u8, allowed: []const []const u8, diagnostic: *Diagnostic) !std.json.ObjectMap {
    if (value != .object) return diagnostic.invalid("{s}: expected an object", .{path});
    for (value.object.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else return diagnostic.invalid("{s}.{s}: unknown field", .{ path, key });
    }
    return value.object;
}

fn required(fields: std.json.ObjectMap, key: []const u8, path: []const u8, diagnostic: *Diagnostic) !std.json.Value {
    return fields.get(key) orelse diagnostic.invalid("{s}: required field is missing", .{path});
}

fn integer(comptime T: type, value: std.json.Value, path: []const u8, minimum: T, diagnostic: *Diagnostic) !T {
    if (value != .number_string) return diagnostic.invalid("{s}: expected an integer JSON number", .{path});
    for (value.number_string) |c| {
        if (c < '0' or c > '9') {
            return diagnostic.invalid("{s}: expected an integer from {d} to {d}", .{ path, minimum, std.math.maxInt(T) });
        }
    }
    const result = std.fmt.parseInt(T, value.number_string, 10) catch
        return diagnostic.invalid("{s}: expected an integer from {d} to {d}", .{ path, minimum, std.math.maxInt(T) });
    if (result < minimum) return diagnostic.invalid("{s}: expected an integer from {d} to {d}", .{ path, minimum, std.math.maxInt(T) });
    return result;
}

fn address(fields: std.json.ObjectMap, path: []const u8, default_address: ?[]const u8, diagnostic: *Diagnostic) !std.Io.net.IpAddress {
    var path_buffer: [96]u8 = undefined;
    const address_path = std.fmt.bufPrint(&path_buffer, "{s}.address", .{path}) catch unreachable;
    const text = if (fields.get("address")) |value| blk: {
        if (value != .string) return diagnostic.invalid("{s}: expected an IPv4 literal string", .{address_path});
        break :blk value.string;
    } else default_address orelse return diagnostic.invalid("{s}: required field is missing", .{address_path});
    var result = std.Io.net.IpAddress.parseIp4(text, 53) catch
        return diagnostic.invalid("{s}: expected an IPv4 literal (for example 192.0.2.1)", .{address_path});
    if (fields.get("port")) |value| {
        const port_path = std.fmt.bufPrint(&path_buffer, "{s}.port", .{path}) catch unreachable;
        result.ip4.port = try integer(u16, value, port_path, 1, diagnostic);
    }
    return result;
}

const minimal_json =
    \\{"schema_version":1,"upstream":{"servers":[{"address":"1.1.1.1"}]}}
;

fn expectInvalid(contents: []const u8, expected_path: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, contents, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.text(), expected_path) != null);
}

test "minimal configuration applies every optional default" {
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, minimal_json, &diagnostic);
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
    var config = try parse(std.testing.allocator, input, &diagnostic);
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
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "{\"schema_version\":2}", &diagnostic));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "{\"schema_version\":0}", &diagnostic));
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{}", "schema_version" },
        .{ "{\"schema_version\":\"1\"}", "schema_version" },
        .{ "{\"schema_version\":1.0}", "schema_version" },
        .{ "{\"schema_version\":1}", "upstream" },
        .{ "{\"schema_version\":1,\"upstream\":{}}", "upstream.servers" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[]}}", "upstream.servers" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{}]}}", "upstream.servers[0].address" },
    };
    for (cases) |case| try expectInvalid(case[0], case[1]);
}

test "unknown fields are rejected at every schema level" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"schema_version\":1,\"records\":[]}", "$.records" },
        .{ "{\"schema_version\":1,\"dns\":{\"typo\":true}}", "dns.typo" },
        .{ "{\"schema_version\":1,\"dns\":{\"listen\":{\"host\":\"localhost\"}}}", "dns.listen.host" },
        .{ "{\"schema_version\":1,\"upstream\":{\"retry\":true}}", "upstream.retry" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"weight\":2}]}}", "upstream.servers[0].weight" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":{\"ttl\":1}}", "cache.ttl" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"file\":\"log\"}}", "logging.file" },
    };
    for (cases) |case| try expectInvalid(case[0], case[1]);
}

test "ports reject zero overflow strings fractions and other types" {
    for ([_][]const u8{ "0", "65536", "-1", "\"53\"", "53.0", "5.3e1", "null", "true", "[]", "{}" }) |port| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"8.8.8.8\",\"port\":{s}}}]}}}}",
            .{port},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input, "upstream.servers[1].port");
    }
    try expectInvalid("{\"schema_version\":1,\"dns\":{\"listen\":{\"port\":0}}}", "dns.listen.port");
}

test "timeout and capacity enforce integer ranges without coercion" {
    for ([_][]const u8{ "0", "4294967296", "-1", "\"3000\"", "1e3", "null" }) |timeout| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}],\"timeout_ms\":{s}}}}}",
            .{timeout},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input, "upstream.timeout_ms");
    }
    for ([_][]const u8{ "-1", "\"4096\"", "1.5", "18446744073709551616", "false" }) |capacity| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}]}},\"cache\":{{\"capacity\":{s}}}}}",
            .{capacity},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input, "cache.capacity");
    }
}

test "IPv4 validation reports indexed field paths" {
    for ([_][]const u8{ "localhost", "::1", "1.2.3", "256.1.1.1", "01.2.3.4", "1.1.1.1:53", "" }) |ip| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"{s}\"}}]}}}}",
            .{ip},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input, "upstream.servers[1].address");
    }
    try expectInvalid("{\"schema_version\":1,\"dns\":{\"listen\":{\"address\":\"::1\"}}}", "dns.listen.address");
}

test "wrong container and leaf types are rejected" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "[]", "$" },
        .{ "null", "$" },
        .{ "{\"schema_version\":true}", "schema_version" },
        .{ "{\"schema_version\":1,\"dns\":null}", "dns" },
        .{ "{\"schema_version\":1,\"dns\":{\"listen\":[]}}", "dns.listen" },
        .{ "{\"schema_version\":1,\"upstream\":null}", "upstream" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":{}}}", "upstream.servers" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[null]}}", "upstream.servers[0]" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":123}]}}", "upstream.servers[0].address" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":null}", "cache" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":[]}", "logging" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":0}}", "logging.level" },
        .{ "{\"schema_version\":1,\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":\"trace\"}}", "logging.level" },
    };
    for (cases) |case| try expectInvalid(case[0], case[1]);
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
        try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, input, &diagnostic));
    }
}

test "parse and load accept exactly 1 MiB and reject larger input" {
    const input = try std.testing.allocator.alloc(u8, max_file_size + 1);
    defer std.testing.allocator.free(input);
    @memset(input, ' ');
    @memcpy(input[0..minimal_json.len], minimal_json);
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, input[0..max_file_size], &diagnostic);
    config.deinit();
    try std.testing.expectError(error.FileTooLarge, parse(std.testing.allocator, input, &diagnostic));

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
    var config = try parse(allocator, minimal_json, &diagnostic);
    defer config.deinit();
}

test "allocation failures release partial parser and address ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithFailingAllocator, .{});
}
