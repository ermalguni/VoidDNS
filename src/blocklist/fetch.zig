const std = @import("std");
const Source = @import("source.zig").Source;
const security = @import("security.zig");

pub const max_bytes = 32 * 1024 * 1024;

/// Returned bytes are owned by allocator. HTTP decompression occurs before the
/// byte limit is applied. HTTPS uses std.http.Client's system CA verification.
pub fn load(allocator: std.mem.Allocator, io: std.Io, source: Source, base_dir: []const u8) ![]u8 {
    const Result = union(enum) { loaded: anyerror![]u8, deadline: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var race: std.Io.Select(Result) = .init(io, &results);
    defer while (race.cancel()) |result| switch (result) {
        .loaded => |loaded| if (loaded) |bytes| allocator.free(bytes) else |_| {},
        .deadline => {},
    };
    try race.concurrent(.deadline, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(30), .awake });
    try race.concurrent(.loaded, loadInner, .{ allocator, io, source, base_dir });
    return switch (try race.await()) {
        .loaded => |loaded| loaded,
        .deadline => |deadline| blk: {
            try deadline;
            break :blk error.SourceLoadTimeout;
        },
    };
}

fn loadInner(allocator: std.mem.Allocator, io: std.Io, source: Source, base_dir: []const u8) anyerror![]u8 {
    try source.validate();
    switch (source.source.kind) {
        .file => {
            if (source.api_managed) {
                const root = source.access.file_root orelse return error.ApiFileSourcesDisabled;
                const file = try security.openSourceFile(io, root, source.source.value);
                defer file.close(io);
                var buffer: [4096]u8 = undefined;
                var reader = file.reader(io, &buffer);
                return reader.interface.allocRemaining(allocator, .limited(max_bytes));
            }
            const path = if (std.fs.path.isAbsolute(source.source.value))
                try allocator.dupe(u8, source.source.value)
            else
                try std.fs.path.join(allocator, &.{ base_dir, source.source.value });
            defer allocator.free(path);
            return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
        },
        .url => return download(allocator, io, source),
    }
}

fn download(allocator: std.mem.Allocator, io: std.Io, source: Source) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(source.source.value);
    const connection = if (source.api_managed) try pinnedConnection(&client, uri, source.access.allow_private_sources) else null;
    var request = try client.request(.GET, uri, .{
        .keep_alive = false,
        .connection = connection,
        .redirect_behavior = if (source.api_managed) .unhandled else @enumFromInt(3),
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (source.api_managed and response.head.status.class() == .redirect) return error.SourceRedirectDenied;
    if (response.head.status.class() != .success) return error.HttpStatusFailure;
    const window_size: usize = switch (response.head.content_encoding) {
        .identity => 0,
        .gzip, .deflate => std.compress.flate.max_window_len,
        .zstd => std.compress.zstd.default_window_len,
        .compress => return error.UnsupportedCompressionMethod,
    };
    const window = try allocator.alloc(u8, window_size);
    defer allocator.free(window);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, window);
    return reader.allocRemaining(allocator, .limited(max_bytes));
}

/// Resolve once, validate the complete result set, then connect using a numeric
/// address. proxied_host supplies the ORIGINAL TLS identity/SNI; no proxy is
/// used. HTTP's Host header also remains the original URI authority.
fn pinnedConnection(client: *std.http.Client, uri: std.Uri, allow_private: bool) !*std.http.Client.Connection {
    const io = client.io;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const component = uri.host orelse return error.UriMissingHost;
    var host: std.Io.net.HostName = .{ .bytes = try component.toRaw(&host_buffer) };
    if (host.bytes.len >= 2 and host.bytes[0] == '[' and host.bytes[host.bytes.len - 1] == ']')
        host.bytes = host.bytes[1 .. host.bytes.len - 1];
    const protocol: std.http.Client.Protocol = if (std.mem.eql(u8, uri.scheme, "https")) .tls else .plain;
    const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
    if (port == 0) return error.InvalidSourceLocation;
    var selected: ?std.Io.net.IpAddress = null;
    if (std.Io.net.IpAddress.parse(host.bytes, port)) |ip| {
        if (!allow_private and !security.isPublicAddress(ip)) return error.PrivateSourceAddress;
        selected = ip;
    } else |_| {
        try std.Io.net.HostName.validate(host.bytes);
        var storage: [16]std.Io.net.HostName.LookupResult = undefined;
        var resolved: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
        try host.lookup(io, &resolved, .{ .port = port });
        while (resolved.getOne(io)) |result| {
            switch (result) {
                .address => |ip| {
                    if (!allow_private and !security.isPublicAddress(ip)) return error.PrivateSourceAddress;
                    // Prefer IPv4 when available; retain IPv6-only connectivity.
                    if (selected == null or (selected.? == .ip6 and ip == .ip4)) selected = ip;
                },
                .canonical_name => {},
            }
        } else |err| switch (err) {
            error.Closed => {},
            else => return err,
        }
    }
    const ip = selected orelse return error.NoAddressReturned;
    var numeric_buffer: [64]u8 = undefined;
    const numeric = switch (ip) {
        .ip4 => |v4| try std.fmt.bufPrint(&numeric_buffer, "{d}.{d}.{d}.{d}", .{ v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3] }),
        .ip6 => |v6| try std.fmt.bufPrint(&numeric_buffer, "{f}", .{std.Io.net.Ip6Address.Unresolved{ .bytes = v6.bytes, .interface_name = null }}),
    };
    if (protocol == .tls) {
        client.now = std.Io.Clock.real.now(io);
        try client.ca_bundle.rescan(client.allocator, io, client.now.?);
    }
    return client.connectTcpOptions(.{
        .host = .{ .bytes = numeric },
        .port = port,
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    });
}

test "relative file loading is bounded and anchored to configuration directory" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "list.txt", .data = "example.test\n" });
    const base = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const bytes = try load(std.testing.allocator, io, .{
        .id = "test",
        .source = .{ .kind = .file, .value = "list.txt" },
        .format = .domains,
    }, base);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("example.test\n", bytes);
}

test "oversized local source is rejected rather than truncated" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const file = try temporary.dir.createFile(io, "oversized", .{});
    defer file.close(io);
    try file.setLength(io, max_bytes + 1);
    try std.testing.expectError(error.StreamTooLong, load(std.testing.allocator, io, .{
        .id = "oversized",
        .source = .{ .kind = .file, .value = "oversized" },
        .format = .domains,
    }, base));
}

test "API file loading uses policy root rather than configuration directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "lists");
    try temporary.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "wrong.test\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "lists/one.txt", .data = "right.test\n" });
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const root = try temporary.dir.realPathFileAlloc(io, "lists", allocator);
    defer allocator.free(root);
    const source: Source = .{
        .id = "managed",
        .source = .{ .kind = .file, .value = "one.txt" },
        .format = .domains,
        .api_managed = true,
        .access = .{ .file_root = root },
    };
    const bytes = try load(allocator, io, source, base);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("right.test\n", bytes);
    var traversal = source;
    traversal.source.value = "../one.txt";
    try std.testing.expectError(error.UnsafeSourcePath, load(allocator, io, traversal, base));
    traversal.source.value = base;
    try std.testing.expectError(error.UnsafeSourcePath, load(allocator, io, traversal, base));
}

test "API URL loading rejects private address before connecting" {
    try std.testing.expectError(error.PrivateSourceAddress, load(std.testing.allocator, std.testing.io, .{
        .id = "managed",
        .source = .{ .kind = .url, .value = "http://127.0.0.1:1/list" },
        .format = .domains,
        .api_managed = true,
    }, "."));
}
