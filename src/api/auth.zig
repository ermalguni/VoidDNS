const std = @import("std");

/// Arbitrary file contents, with no trimming or length/character restrictions.
/// Authentication is case-sensitive: the digest covers the file's exact bytes.
/// Only the SHA-256 digest survives loading; plaintext is securely erased.
pub const Auth = struct {
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, key_file: []const u8) !Auth {
        _ = allocator;
        var plaintext: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &plaintext);
        const file = try std.Io.Dir.cwd().openFile(io, key_file, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidApiKeyFile;
        if (@hasDecl(std.Io.File.Permissions, "toMode")) {
            if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureApiKeyPermissions;
        }
        var reader = file.reader(io, &.{});
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        defer std.crypto.secureZero(u8, std.mem.asBytes(&hasher));
        while (true) {
            const length = try reader.interface.readSliceShort(&plaintext);
            hasher.update(plaintext[0..length]);
            if (length < plaintext.len) break;
        }
        var auth: Auth = undefined;
        hasher.final(&auth.digest);
        return auth;
    }

    pub fn verify(self: *const Auth, key: []const u8) bool {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
        return std.crypto.timing_safe.eql([digest.len]u8, self.digest, digest);
    }

    pub fn deinit(self: *Auth) void {
        std.crypto.secureZero(u8, &self.digest);
    }
};

test "authentication loads one key and compares digests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const key = "My user-chosen key!";
    try tmp.dir.writeFile(io, .{
        .sub_path = "key",
        .data = key,
        .flags = .{ .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file },
    });
    const path = try tmp.dir.realPathFileAlloc(io, "key", allocator);
    defer allocator.free(path);
    var auth = try Auth.load(allocator, io, path);
    defer auth.deinit();
    try std.testing.expect(auth.verify(key));
    try std.testing.expect(!auth.verify(key ++ "\n"));
    try std.testing.expect(!auth.verify("my user-chosen key!"));
    try std.testing.expect(!auth.verify(""));
    const long_key: [8193]u8 = @splat('z');
    for ([_][]const u8{ "", "x", " spaced key \r\n", "line\nsecond", "\x00\xff", long_key[0..4096], &long_key }) |contents| {
        try tmp.dir.writeFile(io, .{ .sub_path = "key", .data = contents });
        var loaded = try Auth.load(allocator, io, path);
        defer loaded.deinit();
        try std.testing.expect(loaded.verify(contents));
        try std.testing.expect(!loaded.verify("different key"));
        if (contents.len > 0) try std.testing.expect(!loaded.verify(contents[0 .. contents.len - 1]));
    }
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        const file = try tmp.dir.openFile(io, "key", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o640));
        try std.testing.expectError(error.InsecureApiKeyPermissions, Auth.load(allocator, io, path));
    }
}
