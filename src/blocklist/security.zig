const std = @import("std");
const config = @import("../config/config.zig");
const Source = @import("source.zig").Source;

/// Preserve operator trust only for unchanged original definitions. Provenance
/// is persisted by toDocument and cannot be cleared through the management API.
pub fn validateApiSources(allocator: std.mem.Allocator, io: std.Io, candidate: *const config.Config, previous: *const config.Config) !void {
    _ = allocator;
    _ = io;
    for (candidate.definitions.sources.items) |*source| {
        var trusted = false;
        for (previous.definitions.sources.items) |old| {
            if (std.mem.eql(u8, old.id, source.id)) {
                trusted = !old.api_managed and equivalent(old, source.*);
                break;
            }
        }
        if (trusted and !source.api_managed) continue;
        source.api_managed = true;
        if (source.access.file_root) |root| candidate.allocator.free(root);
        source.access = .{};
        const api = candidate.api;
        source.access.allow_private_sources = api.allow_private_sources;
        if (api.file_root) |root| source.access.file_root = try candidate.allocator.dupe(u8, root);
        switch (source.source.kind) {
            .file => {
                if (source.access.file_root == null) return error.ApiFileSourcesDisabled;
                try validateRelativePath(source.source.value);
            },
            .url => {
                const uri = try std.Uri.parse(source.source.value);
                var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
                const component = uri.host orelse return error.UriMissingHost;
                var host: std.Io.net.HostName = .{ .bytes = try component.toRaw(&host_buffer) };
                if (host.bytes.len >= 2 and host.bytes[0] == '[' and host.bytes[host.bytes.len - 1] == ']')
                    host.bytes = host.bytes[1 .. host.bytes.len - 1];
                if (std.Io.net.IpAddress.parse(host.bytes, uri.port orelse 80)) |ip| {
                    if (!source.access.allow_private_sources and !isPublicAddress(ip)) return error.PrivateSourceAddress;
                } else |_| {}
            },
        }
    }
}

fn equivalent(a: Source, b: Source) bool {
    return a.format == b.format and a.source.kind == b.source.kind and
        std.mem.eql(u8, a.source.value, b.source.value);
}

pub fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\:\x00") != null)
        return error.UnsafeSourcePath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeSourcePath;
    }
}

/// Walk directory descriptors one component at a time. No component may be a
/// symlink, and later rename/symlink swaps cannot escape an already opened dir.
pub fn openSourceFile(io: std.Io, root: []const u8, path: []const u8) !std.Io.File {
    try validateRelativePath(path);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    var components = std.mem.splitScalar(u8, path, '/');
    var component = components.next().?;
    while (components.next()) |next| {
        const child = try dir.openDir(io, component, .{ .follow_symlinks = false });
        dir.close(io);
        dir = child;
        component = next;
    }
    const file = try dir.openFile(io, component, .{ .follow_symlinks = false });
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsafeSourcePath;
    return file;
}

/// Conservative global-unicast policy. IPv4-mapped IPv6 and translation,
/// tunnel, documentation, multicast, link-local and reserved ranges are denied.
pub fn isPublicAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| publicV4(ip.bytes),
        .ip6 => |ip| blk: {
            const b = ip.bytes;
            if (b[0] & 0xe0 != 0x20) break :blk false;
            if (b[0] == 0x20 and b[1] == 0x02) break :blk false; // 6to4
            if (b[0] == 0x20 and b[1] == 0x01) {
                if (b[2] < 2) break :blk false; // IETF special assignments
                if (b[2] == 0x0d and b[3] == 0xb8) break :blk false;
            }
            if (b[0] == 0x3f and b[1] == 0xff and b[2] < 0x10) break :blk false;
            break :blk true;
        },
    };
}

fn publicV4(b: [4]u8) bool {
    if (b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224) return false;
    if (b[0] == 100 and b[1] >= 64 and b[1] <= 127) return false;
    if (b[0] == 169 and b[1] == 254) return false;
    if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return false;
    if (b[0] == 192 and (b[1] == 168 or (b[1] == 0 and (b[2] == 0 or b[2] == 2)) or (b[1] == 88 and b[2] == 99))) return false;
    if (b[0] == 198 and (b[1] == 18 or b[1] == 19 or (b[1] == 51 and b[2] == 100))) return false;
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return false;
    return true;
}

test "API paths reject absolute traversal and platform separators" {
    for ([_][]const u8{ "/etc/passwd", "../secret", "a/../secret", "a/./b", "a//b", "a\\b", "C:secret", "a/", "" }) |path|
        try std.testing.expectError(error.UnsafeSourcePath, validateRelativePath(path));
    try validateRelativePath("lists/domains.txt");
}

test "source network policy rejects local mapped and special addresses" {
    for ([_][]const u8{ "127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1", "2001:db8::1", "2002:0808:0808::1" }) |text|
        try std.testing.expect(!isPublicAddress(try std.Io.net.IpAddress.parse(text, 80)));
    try std.testing.expect(isPublicAddress(try std.Io.net.IpAddress.parse("8.8.8.8", 80)));
    try std.testing.expect(isPublicAddress(try std.Io.net.IpAddress.parse("2606:4700:4700::1111", 80)));
}

test "API provenance survives unchanged edits and cannot be downgraded" {
    const allocator = std.testing.allocator;
    const document: config.Document = .{ .schema_version = 2, .api = .{ .enabled = false }, .ui = .{ .enabled = false }, .upstream = .{ .servers = &.{.{ .address = "1.1.1.1" }} }, .blocks = .{ .lists = &.{.{ .id = "trusted", .source = .{ .kind = .file, .value = "/operator/list" }, .format = .domains }} } };
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.fromDocument(allocator, &document, ".", &diagnostic);
    defer previous.deinit();
    var candidate = try config.fromDocument(allocator, &document, ".", &diagnostic);
    defer candidate.deinit();
    try validateApiSources(allocator, std.testing.io, &candidate, &previous);
    try std.testing.expect(!candidate.definitions.sources.items[0].api_managed);
    candidate.definitions.sources.items[0].name = try allocator.dupe(u8, "Renamed");
    candidate.definitions.sources.items[0].enabled = false;
    try validateApiSources(allocator, std.testing.io, &candidate, &previous);
    try std.testing.expect(!candidate.definitions.sources.items[0].api_managed);
    previous.definitions.sources.items[0].api_managed = true;
    try std.testing.expectError(error.ApiFileSourcesDisabled, validateApiSources(allocator, std.testing.io, &candidate, &previous));
    try std.testing.expect(candidate.definitions.sources.items[0].api_managed);
}

test "rooted source opening refuses leaf and intermediate symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "secret.test\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/nested/list", .data = "allowed.test\n" });
    try tmp.dir.symLink(io, "../outside", "root/leaf", .{});
    try tmp.dir.symLink(io, "nested", "root/link", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(io, "root", allocator);
    defer allocator.free(root);
    const safe = try openSourceFile(io, root, "nested/list");
    safe.close(io);
    for ([_][]const u8{ "leaf", "link/list" }) |path| {
        if (openSourceFile(io, root, path)) |file| {
            file.close(io);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
