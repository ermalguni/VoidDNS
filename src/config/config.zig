const std = @import("std");
const filtering = @import("../state/filtering.zig");
const State = @import("../state/state.zig").State;
const definitions_module = @import("definitions.zig");
const document_module = @import("document.zig");
const Record = @import("../domains/record.zig");
const domain = @import("../domains/domain.zig");
pub const Definitions = definitions_module.Definitions;
pub const Document = document_module.Document;

pub const max_file_size = 1024 * 1024;

pub const Api = struct {
    enabled: bool = true,
    listen_address: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    key_file: ?[]const u8 = null,
    file_root: ?[]const u8 = null,
    allow_private_sources: bool = false,

    fn deinit(self: *Api, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_address);
        if (self.key_file) |path| allocator.free(path);
        if (self.file_root) |path| allocator.free(path);
    }
};

pub const Ui = struct {
    enabled: bool = true,
};

/// Owns typed configuration definitions and paths, never runtime filtering state.
pub const Config = struct {
    listen_address: std.Io.net.IpAddress,
    upstream_addresses: []const std.Io.net.IpAddress,
    upstream_timeout_ms: u32,
    cache_capacity: usize,
    log_level: std.log.Level,
    allocator: std.mem.Allocator,
    definitions: Definitions,
    records: []const Record,
    base_dir: []const u8,
    api: Api,
    ui: Ui,

    pub fn deinit(self: *Config) void {
        self.api.deinit(self.allocator);
        self.definitions.deinit(self.allocator);
        freeRecords(self.allocator, self.records);
        self.allocator.free(self.records);
        self.allocator.free(self.base_dir);
        self.allocator.free(self.upstream_addresses);
        self.* = undefined;
    }

    /// Materialize enabled sources for startup, not incremental reload.
    /// The returned filtering state is independently owned; records are attached
    /// separately by main as a guarded borrow from the active configuration.
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
    if (document.schema_version != 2)
        return diagnostic.invalid("schema_version: unsupported version {d}; expected 2", .{document.schema_version});
    if (document.ui.enabled and !document.api.enabled)
        return diagnostic.invalid("ui.enabled: requires api.enabled to be true", .{});
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
    const records = recordsFromDocument(allocator, document, diagnostic) catch |err| {
        if (diagnostic.len == 0) diagnostic.set("records: {s}", .{@errorName(err)});
        return err;
    };
    errdefer {
        freeRecords(allocator, records);
        allocator.free(records);
    }
    const owned_base_dir = try allocator.dupe(u8, base_dir);
    errdefer allocator.free(owned_base_dir);
    const settings = document.api;
    _ = try address(settings.listen.address, settings.listen.port, "api.listen", diagnostic);
    if (settings.enabled and settings.key_file == null)
        return diagnostic.invalid("api.key_file: required when API is enabled", .{});
    if (settings.key_file) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
            return diagnostic.invalid("api.key_file: expected a nonempty path", .{});
    }
    if (settings.file_root) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
            return diagnostic.invalid("api.file_root: expected a nonempty path", .{});
    }
    var api: Api = .{
        .enabled = settings.enabled,
        .listen_address = try allocator.dupe(u8, settings.listen.address),
        .port = settings.listen.port,
        .allow_private_sources = settings.allow_private_sources,
    };
    errdefer api.deinit(allocator);
    if (settings.key_file) |path| api.key_file = try resolvePath(allocator, base_dir, path);
    if (settings.file_root) |path| api.file_root = try resolvePath(allocator, base_dir, path);
    for (definitions.sources.items) |*source| {
        if (source.api_managed) {
            source.access.allow_private_sources = api.allow_private_sources;
            if (api.file_root) |path| source.access.file_root = try allocator.dupe(u8, path);
        }
    }

    return .{
        .listen_address = listen_address,
        .upstream_addresses = addresses,
        .upstream_timeout_ms = document.upstream.timeout_ms,
        .cache_capacity = document.cache.capacity,
        .log_level = document.logging.level,
        .allocator = allocator,
        .definitions = definitions,
        .records = records,
        .base_dir = owned_base_dir,
        .api = api,
        .ui = document.ui,
    };
}

fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, path: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(path))
        allocator.dupe(u8, path)
    else
        std.fs.path.join(allocator, &.{ base_dir, path });
}

fn documentPath(allocator: std.mem.Allocator, base_dir: []const u8, path: ?[]const u8) !?[]const u8 {
    const value = path orelse return null;
    return if (std.fs.path.isAbsolute(value))
        try allocator.dupe(u8, value)
    else
        try std.fs.path.relative(allocator, "/", null, base_dir, value);
}

/// Canonical active definitions. Every slice is owned by the caller's arena.
pub fn toDocument(allocator: std.mem.Allocator, self: *const Config) !Document {
    var result: Document = .{
        .schema_version = 2,
        .api = undefined,
        .ui = self.ui,
        .dns = .{ .listen = .{ .address = try ip4Text(allocator, self.listen_address.ip4.bytes), .port = self.listen_address.getPort() } },
        .upstream = .{ .servers = undefined, .timeout_ms = self.upstream_timeout_ms },
        .cache = .{ .capacity = self.cache_capacity },
        .logging = .{ .level = self.log_level },
    };
    const Server = std.meta.Elem(@FieldType(@FieldType(Document, "upstream"), "servers"));
    const servers = try allocator.alloc(Server, self.upstream_addresses.len);
    for (servers, self.upstream_addresses) |*server, ip| {
        server.* = .{ .address = try ip4Text(allocator, ip.ip4.bytes), .port = ip.getPort() };
    }
    result.upstream.servers = servers;
    const api = self.api;
    result.api = .{
        .enabled = api.enabled,
        .listen = .{ .address = try allocator.dupe(u8, api.listen_address), .port = api.port },
        .key_file = try documentPath(allocator, self.base_dir, api.key_file),
        .file_root = try documentPath(allocator, self.base_dir, api.file_root),
        .allow_private_sources = api.allow_private_sources,
    };
    result.blocks.domains = try copyStrings(allocator, self.definitions.blocks.items);
    result.allows.domains = try copyStrings(allocator, self.definitions.allows.items);
    const Source = @import("../blocklist/source.zig").Source;
    const sources = try allocator.alloc(Source.Definition, self.definitions.sources.items.len);
    for (sources, self.definitions.sources.items) |*destination, source| {
        destination.* = source.definition();
        destination.id = try allocator.dupe(u8, source.id);
        destination.name = if (source.name) |name| try allocator.dupe(u8, name) else null;
        destination.source.value = try allocator.dupe(u8, source.source.value);
    }
    result.blocks.lists = sources;
    const DocumentRecord = std.meta.Elem(@FieldType(Document, "records"));
    const records = try allocator.alloc(DocumentRecord, self.records.len);
    for (records, self.records) |*destination, record| {
        const addresses = try allocator.alloc([]const u8, switch (record.addresses) {
            inline else => |values| values.len,
        });
        switch (record.addresses) {
            .a => |values| for (addresses, values) |*text, bytes| {
                text.* = try ip4Text(allocator, bytes);
            },
            .aaaa => |values| for (addresses, values) |*text, bytes| {
                const ip: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
                text.* = try std.fmt.allocPrint(allocator, "{f}", .{ip});
            },
        }
        destination.* = .{
            .name = try allocator.dupe(u8, record.name),
            .type = switch (record.addresses) {
                .a => .A,
                .aaaa => .AAAA,
            },
            .ttl = record.ttl_seconds,
            .addresses = addresses,
        };
    }
    result.records = records;
    return result;
}

fn ip4Text(allocator: std.mem.Allocator, bytes: [4]u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

fn copyStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (result, strings) |*destination, text| destination.* = try allocator.dupe(u8, text);
    return result;
}

fn freeRecords(allocator: std.mem.Allocator, records: []const Record) void {
    for (records) |record| {
        allocator.free(record.name);
        switch (record.addresses) {
            inline else => |addresses| allocator.free(addresses),
        }
    }
}

fn recordsFromDocument(allocator: std.mem.Allocator, document: *const Document, diagnostic: *Diagnostic) ![]const Record {
    const records = try allocator.alloc(Record, document.records.len);
    errdefer allocator.free(records);
    var initialized: usize = 0;
    errdefer freeRecords(allocator, records[0..initialized]);
    var names: std.StringHashMapUnmanaged(u2) = .empty;
    defer names.deinit(allocator);
    for (document.records, 0..) |record, index| {
        var name_buffer: [253]u8 = undefined;
        const normalized = domain.normalize(record.name, &name_buffer) catch
            return diagnostic.invalid("records[{d}].name: expected an exact DNS name", .{index});
        if (record.addresses.len == 0 or record.addresses.len > 16)
            return diagnostic.invalid("records[{d}].addresses: expected 1 to 16 IP literals", .{index});
        const name = try allocator.dupe(u8, normalized);
        errdefer allocator.free(name);
        const entry = try names.getOrPut(allocator, name);
        const family: u2 = switch (record.type) {
            .A => 1,
            .AAAA => 2,
        };
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if (entry.value_ptr.* & family != 0)
            return diagnostic.invalid("records[{d}].name/type: duplicate normalized name and record type", .{index});
        entry.value_ptr.* |= family;
        records[index] = .{
            .name = name,
            .ttl_seconds = record.ttl,
            .addresses = switch (record.type) {
                .A => .{ .a = try recordAddresses(4, allocator, record.addresses, index, diagnostic) },
                .AAAA => .{ .aaaa = try recordAddresses(16, allocator, record.addresses, index, diagnostic) },
            },
        };
        initialized += 1;
    }
    return records;
}

fn recordAddresses(
    comptime size: usize,
    allocator: std.mem.Allocator,
    literals: []const []const u8,
    record_index: usize,
    diagnostic: *Diagnostic,
) ![]const [size]u8 {
    var unique: [16][size]u8 = undefined;
    var count: usize = 0;
    for (literals, 0..) |literal, index| {
        const bytes = if (size == 4)
            (std.Io.net.Ip4Address.parse(literal, 0) catch
                return diagnostic.invalid("records[{d}].addresses[{d}]: expected an IPv4 literal for A", .{ record_index, index })).bytes
        else
            (std.Io.net.Ip6Address.parse(literal, 0) catch
                return diagnostic.invalid("records[{d}].addresses[{d}]: expected an IPv6 literal for AAAA", .{ record_index, index })).bytes;
        for (unique[0..count]) |existing| {
            if (std.mem.eql(u8, &existing, &bytes)) break;
        } else {
            unique[count] = bytes;
            count += 1;
        }
    }
    return allocator.dupe([size]u8, unique[0..count]);
}

fn address(text: []const u8, port: u16, path: []const u8, diagnostic: *Diagnostic) !std.Io.net.IpAddress {
    if (port == 0) return diagnostic.invalid("{s}.port: expected a positive port", .{path});
    return std.Io.net.IpAddress.parseIp4(text, port) catch
        diagnostic.invalid("{s}.address: expected an IPv4 literal (for example 192.0.2.1)", .{path});
}

const minimal_json =
    \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"1.1.1.1"}]}}
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
    try std.testing.expectEqual(@as(usize, 0), config.records.len);
}

test "explicit configuration owns addresses and preserves upstream order" {
    const input = try std.testing.allocator.dupe(u8,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"dns":{"listen":{"address":"0.0.0.0","port":65535}},
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
        "{\"schema_version\":2.0}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{}]}}",
        "{\"schema_version\":1,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}",
        "{\"schema_version\":3,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "unknown fields are rejected at every schema level" {
    const cases = [_][]const u8{
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":{\"typo\":true}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":{\"listen\":{\"host\":\"localhost\"}}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"retry\":true}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"weight\":2}]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":{\"ttl\":1}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"file\":\"log\"}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "ports reject zero overflow strings fractions and other types" {
    for ([_][]const u8{ "0", "65536", "-1", "\"53\"", "53.0", "5.3e1", "null", "true", "[]", "{}" }) |port| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":2,\"api\":{{\"enabled\":false}},\"ui\":{{\"enabled\":false}},\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"8.8.8.8\",\"port\":{s}}}]}}}}",
            .{port},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    try expectInvalid("{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":{\"listen\":{\"port\":0}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
}

test "timeout and capacity enforce integer ranges without coercion" {
    for ([_][]const u8{ "0", "4294967296", "-1", "\"3000\"", "1e3", "null" }) |timeout| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":2,\"api\":{{\"enabled\":false}},\"ui\":{{\"enabled\":false}},\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}],\"timeout_ms\":{s}}}}}",
            .{timeout},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    for ([_][]const u8{ "-1", "\"4096\"", "1.5", "18446744073709551616", "false" }) |capacity| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":2,\"api\":{{\"enabled\":false}},\"ui\":{{\"enabled\":false}},\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}}]}},\"cache\":{{\"capacity\":{s}}}}}",
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
            "{{\"schema_version\":2,\"api\":{{\"enabled\":false}},\"ui\":{{\"enabled\":false}},\"upstream\":{{\"servers\":[{{\"address\":\"1.1.1.1\"}},{{\"address\":\"{s}\"}}]}}}}",
            .{ip},
        );
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    try expectInvalid("{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":{\"listen\":{\"address\":\"::1\"}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
}

test "wrong container and leaf types are rejected" {
    const cases = [_][]const u8{
        "[]",
        "null",
        "{\"schema_version\":true}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":null}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"dns\":{\"listen\":[]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":null}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":{}}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[null]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":123}]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":[49,46,49,46,49,46,49]}]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"cache\":null}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":[]}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":0}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"logging\":{\"level\":\"trace\"}}",
    };
    for (cases) |input| try expectInvalid(input);
}

test "malformed JSON duplicate fields comments and trailing content are rejected" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},}",
        "{\"schema_version\":01}",
        "// comment\n" ++ minimal_json,
        minimal_json ++ " {}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"schema_version\":1}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"schema_vers\\u0069on\":1}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[],\"servers\":[]}}",
        "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"address\":\"8.8.8.8\"}]}}",
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
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"1.1.1.1"}]},
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
    const prefix = "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
    try expectInvalid(prefix ++ "\"blocks\":{\"unknown\":true}}");
    try expectInvalid(prefix ++ "\"allows\":{\"domains\":\"wrong\"}}");
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, prefix ++ "\"blocks\":{\"domains\":[],\"domains\":[]}}", ".", &diagnostic));
}

const filtering_json =
    \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"1.1.1.1"}]},
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
            \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"1.1.1.1"}]},
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
    const prefix = "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
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
        .schema_version = 2,
        .api = .{ .enabled = false },
        .ui = .{ .enabled = false },
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
    };
    var document = valid;
    var diagnostic: Diagnostic = .{};
    document.schema_version = 3;
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
    var source: Source.Definition = .{
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
    const prefix = "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},";
    try expectInvalid("{\"schema_vers\\u0069on\":\"1\",\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
    try expectInvalid("{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\",\"po\\u0072t\":\"53\"}]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"domains\":[[97,46,98]]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"lists\":[{\"id\":[97],\"source\":{\"kind\":\"file\",\"value\":\"missing\"},\"format\":\"domains\"}]}}");
    try expectInvalid(prefix ++ "\"blocks\":{\"lists\":[{\"id\":\"off\",\"source\":{\"kind\":\"file\",\"value\":[97]},\"format\":\"domains\"}]}}");
}

const records_json =
    \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"1.1.1.1"}]},
    \\"records":[
    \\ {"name":"Home.TEST.","type":"A","addresses":["192.0.2.2","192.0.2.1","192.0.2.2"]},
    \\ {"name":"HOME.test","type":"AAAA","ttl":0,"addresses":["2001:db8::2","2001:0db8:0:0:0:0:0:2","::1","2001:db8::1"]},
    \\ {"name":"_Service.Test.","type":"A","ttl":4294967295,"addresses":["127.0.0.1"]}
    \\]}
;

test "records own normalized names and binary addresses with stable deduplication" {
    const input = try std.testing.allocator.dupe(u8, records_json);
    defer std.testing.allocator.free(input);
    var diagnostic: Diagnostic = .{};
    var config = try parse(std.testing.allocator, input, ".", &diagnostic);
    defer config.deinit();
    @memset(input, 0);
    try std.testing.expectEqual(@as(usize, 3), config.records.len);
    const a = config.records[0];
    try std.testing.expectEqualStrings("home.test", a.name);
    try std.testing.expectEqual(@as(u32, 60), a.ttl_seconds);
    try std.testing.expectEqualSlices([4]u8, &.{ .{ 192, 0, 2, 2 }, .{ 192, 0, 2, 1 } }, a.addresses.a);
    const aaaa = config.records[1];
    try std.testing.expectEqualStrings("home.test", aaaa.name);
    try std.testing.expectEqual(@as(u32, 0), aaaa.ttl_seconds);
    try std.testing.expectEqual(@as(usize, 3), aaaa.addresses.aaaa.len);
    for ([_][]const u8{ "2001:db8::2", "::1", "2001:db8::1" }, aaaa.addresses.aaaa) |text, actual| {
        try std.testing.expectEqual((try std.Io.net.Ip6Address.parse(text, 0)).bytes, actual);
    }
    try std.testing.expectEqualStrings("_service.test", config.records[2].name);
    try std.testing.expectEqual(std.math.maxInt(u32), config.records[2].ttl_seconds);
}

test "constructed records are copied independently from editable buffers" {
    var name = "Host.TEST.".*;
    var literal = "192.0.2.1".*;
    var literals = [_][]const u8{&literal};
    var document: Document = .{
        .schema_version = 2,
        .api = .{ .enabled = false },
        .ui = .{ .enabled = false },
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
        .records = &.{.{ .name = &name, .type = .A, .addresses = &literals }},
    };
    var diagnostic: Diagnostic = .{};
    var config = try fromDocument(std.testing.allocator, &document, ".", &diagnostic);
    defer config.deinit();
    @memset(&name, 'x');
    @memset(&literal, '0');
    literals[0] = "203.0.113.1";
    document.records = &.{};
    try std.testing.expectEqualStrings("host.test", config.records[0].name);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 1 }, config.records[0].addresses.a[0]);
}

fn expectInvalidRecords(document: *const Document, field: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, document, ".", &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.text(), field) != null);
    const serialized = try std.json.Stringify.valueAlloc(std.testing.allocator, document.*, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(serialized);
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, serialized, ".", &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.text(), field) != null);
}

test "parsed and constructed records reject invalid names and wrong address families" {
    var document: Document = .{
        .schema_version = 2,
        .api = .{ .enabled = false },
        .ui = .{ .enabled = false },
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
    };
    for ([_][]const u8{ "", ".", "*.test", "a..test", "-a.test", "127.0.0.1", "caf\xc3\xa9.test" }) |name| {
        document.records = &.{.{ .name = name, .type = .A, .addresses = &.{"192.0.2.1"} }};
        try expectInvalidRecords(&document, "records[0].name");
    }
    for ([_][]const u8{ "::1", "localhost", "1.2.3", "256.1.1.1", "01.2.3.4", "192.0.2.1:53", " 192.0.2.1", "" }) |literal| {
        document.records = &.{
            .{ .name = "valid.test", .type = .A, .addresses = &.{"192.0.2.1"} },
            .{ .name = "invalid.test", .type = .A, .addresses = &.{ "192.0.2.2", literal } },
        };
        try expectInvalidRecords(&document, "records[1].addresses[1]");
    }
    for ([_][]const u8{ "192.0.2.1", "localhost", "[::1]", "fe80::1%eth0", "fe80::1%1", "2001:db8:::1", "" }) |literal| {
        document.records = &.{.{ .name = "invalid.test", .type = .AAAA, .addresses = &.{literal} }};
        try expectInvalidRecords(&document, "records[0].addresses[0]");
    }
}

test "records enforce input address count before deduplication" {
    var document: Document = .{
        .schema_version = 2,
        .api = .{ .enabled = false },
        .ui = .{ .enabled = false },
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
        .records = &.{.{ .name = "host.test", .type = .A, .addresses = &.{} }},
    };
    try expectInvalidRecords(&document, "records[0].addresses");
    const literals: [17][]const u8 = @splat("192.0.2.1");
    document.records = &.{.{ .name = "host.test", .type = .A, .addresses = literals[0..16] }};
    var diagnostic: Diagnostic = .{};
    var config = try fromDocument(std.testing.allocator, &document, ".", &diagnostic);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 1), config.records[0].addresses.a.len);
    document.records = &.{.{ .name = "host.test", .type = .A, .addresses = &literals }};
    try expectInvalidRecords(&document, "records[0].addresses");
    document.records = &.{};
    var empty = try fromDocument(std.testing.allocator, &document, ".", &diagnostic);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
}

test "duplicate normalized record names reject only matching families" {
    var document: Document = .{
        .schema_version = 2,
        .api = .{ .enabled = false },
        .ui = .{ .enabled = false },
        .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} },
        .records = &.{
            .{ .name = "Host.Test.", .type = .A, .addresses = &.{"192.0.2.1"} },
            .{ .name = "host.test", .type = .A, .ttl = 30, .addresses = &.{"192.0.2.2"} },
        },
    };
    try expectInvalidRecords(&document, "records[1].name/type");
    document.records = &.{
        .{ .name = "Host.Test.", .type = .AAAA, .addresses = &.{"::1"} },
        .{ .name = "host.test", .type = .AAAA, .addresses = &.{"::2"} },
    };
    try expectInvalidRecords(&document, "records[1].name/type");
}

test "records require strict JSON field shapes and supported record types" {
    const prefix = "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{\"enabled\":false},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]},\"records\":";
    const values = [_][]const u8{
        "null",                                                                               "{}",                                                                      "[null]",                                                                      "[{}]",
        "[{\"type\":\"A\",\"addresses\":[\"192.0.2.1\"]}]",                                   "[{\"name\":\"host.test\",\"addresses\":[\"192.0.2.1\"]}]",                "[{\"name\":\"host.test\",\"type\":\"A\"}]",                                   "[{\"name\":3,\"type\":\"A\",\"addresses\":[\"192.0.2.1\"]}]",
        "[{\"name\":[104],\"type\":\"A\",\"addresses\":[\"192.0.2.1\"]}]",                    "[{\"name\":\"host.test\",\"type\":\"a\",\"addresses\":[\"192.0.2.1\"]}]", "[{\"name\":\"host.test\",\"type\":\"CNAME\",\"addresses\":[\"192.0.2.1\"]}]", "[{\"name\":\"host.test\",\"type\":1,\"addresses\":[\"192.0.2.1\"]}]",
        "[{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":\"192.0.2.1\"}]",              "[{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":[[192,0,2,1]]}]",   "[{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":[1]}]",                 "[{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":[null]}]",
        "[{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":[\"192.0.2.1\"],\"typo\":0}]",
    };
    for (values) |value| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, value, "}" });
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    for ([_][]const u8{ "-1", "4294967296", "\"60\"", "60.0", "6e1", "true", "null", "[]", "{}" }) |ttl| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}[{{\"name\":\"host.test\",\"type\":\"A\",\"addresses\":[\"192.0.2.1\"],\"ttl\":{s}}}]}}", .{ prefix, ttl });
        defer std.testing.allocator.free(input);
        try expectInvalid(input);
    }
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, prefix ++ "[{\"name\":\"host.test\",\"type\":\"A\",\"type\":\"AAAA\",\"addresses\":[\"::1\"]}]}", ".", &diagnostic));
}

fn parseRecordsWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var diagnostic: Diagnostic = .{};
    var config = try parse(allocator, records_json, ".", &diagnostic);
    defer config.deinit();
}

test "records release all partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseRecordsWithFailingAllocator, .{});
}

test "API configuration validates listener and independently owns resolved paths" {
    var diagnostic: Diagnostic = .{};
    try expectInvalid("{\"schema_version\":2,\"ui\":{\"enabled\":false},\"api\":{},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
    try expectInvalid("{\"schema_version\":2,\"ui\":{\"enabled\":false},\"api\":{\"enabled\":false,\"listen\":{\"address\":\"localhost\"}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
    try expectInvalid("{\"schema_version\":2,\"ui\":{\"enabled\":false},\"api\":{\"enabled\":false,\"listen\":{\"port\":0}},\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}");
    var settings = try parse(std.testing.allocator,
        \\{"schema_version":2,"ui":{"enabled":false},"api":{"key_file":"key","file_root":"lists"},"upstream":{"servers":[{"address":"1.1.1.1"}]}}
    , "/configuration", &diagnostic);
    defer settings.deinit();
    try std.testing.expectEqualStrings("/configuration/key", settings.api.key_file.?);
    try std.testing.expectEqualStrings("/configuration/lists", settings.api.file_root.?);
    try std.testing.expectEqual(@as(u16, 8080), settings.api.port);
}

test "canonical document round trip retains normalized records rules and managed policy" {
    const allocator = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var settings = try parse(allocator,
        \\{"schema_version":2,"ui":{"enabled":false},"api":{"key_file":"key","file_root":"lists"},"upstream":{"servers":[{"address":"1.1.1.1","port":5353}]},"blocks":{"domains":["BLOCK.TEST."],"lists":[{"id":"managed","api_managed":true,"source":{"kind":"file","value":"one.txt"},"format":"domains"}]},"records":[{"name":"Home.Test.","type":"AAAA","ttl":17,"addresses":["2001:db8::1"]}]}
    , "config", &diagnostic);
    defer settings.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const canonical = try toDocument(arena.allocator(), &settings);
    try std.testing.expectEqualStrings("key", canonical.api.key_file.?);
    try std.testing.expectEqualStrings("lists", canonical.api.file_root.?);
    try std.testing.expectEqualStrings("block.test", canonical.blocks.domains[0]);
    try std.testing.expectEqualStrings("home.test", canonical.records[0].name);
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), canonical, .{ .emit_null_optional_fields = false });
    var round_trip = try parse(allocator, json, "config", &diagnostic);
    defer round_trip.deinit();
    try std.testing.expect(round_trip.definitions.sources.items[0].api_managed);
    try std.testing.expectEqualStrings("one.txt", round_trip.definitions.sources.items[0].source.value);
    try std.testing.expectEqualStrings("config/lists", round_trip.definitions.sources.items[0].access.file_root.?);
    try std.testing.expectEqualStrings("config/key", round_trip.api.key_file.?);
    try std.testing.expectEqual(@as(u32, 17), round_trip.records[0].ttl_seconds);
}

test "HTTP sections are required non-null objects with enabled defaults and UI dependency" {
    const suffix = ",\"upstream\":{\"servers\":[{\"address\":\"1.1.1.1\"}]}}";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"schema_version\":2,\"ui\":{\"enabled\":false}" ++ suffix, "api" },
        .{ "{\"schema_version\":2,\"api\":{\"enabled\":false}" ++ suffix, "ui" },
        .{ "{\"schema_version\":2,\"api\":null,\"ui\":{}" ++ suffix, "api" },
        .{ "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":null" ++ suffix, "ui" },
        .{ "{\"schema_version\":2,\"api\":{\"enabled\":false},\"ui\":{}" ++ suffix, "ui.enabled" },
    };
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, case[0], ".", &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.text(), case[1]) != null);
    }
    var enabled = try parse(std.testing.allocator, "{\"schema_version\":2,\"api\":{\"key_file\":\"key\"},\"ui\":{}" ++ suffix, ".", &diagnostic);
    defer enabled.deinit();
    try std.testing.expect(enabled.api.enabled);
    try std.testing.expect(enabled.ui.enabled);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var canonical = try toDocument(arena.allocator(), &enabled);
    try std.testing.expectEqual(@as(u32, 2), canonical.schema_version);
    try std.testing.expect(canonical.api.enabled and canonical.ui.enabled);
    canonical.api.enabled = false;
    try std.testing.expectError(error.InvalidConfig, fromDocument(std.testing.allocator, &canonical, ".", &diagnostic));
    canonical.ui.enabled = false;
    var disabled = try fromDocument(std.testing.allocator, &canonical, ".", &diagnostic);
    defer disabled.deinit();
    try std.testing.expect(!disabled.api.enabled and !disabled.ui.enabled);
}
