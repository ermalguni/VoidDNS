const std = @import("std");

/// Exactly 64 hexadecimal characters, optionally terminated by LF or CRLF.
/// Authentication is case-sensitive: the digest covers the key's exact spelling.
/// Only the SHA-256 digest survives loading; plaintext is securely erased.
pub const Auth = struct {
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, key_file: []const u8) !Auth {
        _ = allocator;
        var plaintext: [67]u8 = undefined;
        defer std.crypto.secureZero(u8, &plaintext);
        const file = try std.Io.Dir.cwd().openFile(io, key_file, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidApiKeyFile;
        if (@hasDecl(std.Io.File.Permissions, "toMode")) {
            if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureApiKeyPermissions;
        }
        var reader = file.reader(io, &.{});
        const length = try reader.interface.readSliceShort(&plaintext);
        if (length > 66) return error.InvalidApiKeyFile;
        var key: []const u8 = plaintext[0..length];
        if (std.mem.endsWith(u8, key, "\n")) {
            key = key[0 .. key.len - 1];
            if (std.mem.endsWith(u8, key, "\r")) key = key[0 .. key.len - 1];
        }
        if (key.len != 64) return error.InvalidApiKeyFile;
        for (key) |byte| if (!std.ascii.isHex(byte)) return error.InvalidApiKeyFile;
        var auth: Auth = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &auth.digest, .{});
        return auth;
    }

    pub fn verify(self: *const Auth, key: []const u8) bool {
        if (key.len != 64) return false;
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
    const key = "0123456789abcdef" ** 4;
    try tmp.dir.writeFile(io, .{
        .sub_path = "key",
        .data = key ++ "\r\n",
        .flags = .{ .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file },
    });
    const path = try tmp.dir.realPathFileAlloc(io, "key", allocator);
    defer allocator.free(path);
    var auth = try Auth.load(allocator, io, path);
    defer auth.deinit();
    try std.testing.expect(auth.verify(key));
    try std.testing.expect(!auth.verify(key ++ "\n"));
    try std.testing.expect(!auth.verify("1123456789abcdef" ++ "0123456789abcdef" ** 3));
    try std.testing.expect(!auth.verify(""));
    try tmp.dir.writeFile(io, .{ .sub_path = "key", .data = key ++ "\nsecond" });
    try std.testing.expectError(error.InvalidApiKeyFile, Auth.load(allocator, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "key", .data = "z" ** 64 });
    try std.testing.expectError(error.InvalidApiKeyFile, Auth.load(allocator, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "key", .data = "a" ** 63 });
    try std.testing.expectError(error.InvalidApiKeyFile, Auth.load(allocator, io, path));
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        const file = try tmp.dir.openFile(io, "key", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o640));
        try std.testing.expectError(error.InsecureApiKeyPermissions, Auth.load(allocator, io, path));
    }
}
