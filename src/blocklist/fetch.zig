const std = @import("std");
const Source = @import("source.zig").Source;

pub const max_bytes = 32 * 1024 * 1024;

/// Returned bytes are owned by allocator. HTTP decompression occurs before the
/// byte limit is applied. HTTPS uses std.http.Client's system CA verification.
pub fn load(allocator: std.mem.Allocator, io: std.Io, source: Source, base_dir: []const u8) ![]u8 {
    try source.validate();
    switch (source.source.kind) {
        .file => {
            const path = if (std.fs.path.isAbsolute(source.source.value))
                try allocator.dupe(u8, source.source.value)
            else
                try std.fs.path.join(allocator, &.{ base_dir, source.source.value });
            defer allocator.free(path);
            return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
        },
        .url => return download(allocator, io, source.source.value),
    }
}

fn download(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
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
