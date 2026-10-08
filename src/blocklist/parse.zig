const std = @import("std");
const domain = @import("../domains/domain.zig");
const Source = @import("source.zig").Source;

/// Temporary owned canonical names. Index publication takes ownership of these
/// strings, so no second permanent copy of each imported name is necessary.
pub const Names = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Names) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn insert(self: *Names, canonical: []const u8) !void {
        if (self.entries.contains(canonical)) return;
        const owned = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(owned);
        try self.entries.put(self.allocator, owned, {});
    }
};

/// Every non-comment line must match its declared format. Hosts entries require
/// a literal IPv4/IPv6 prefix and one or more names; domain lists one name only.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, format: @FieldType(Source, "format")) !Names {
    var names: Names = .{ .allocator = allocator };
    errdefer names.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var buffer: [253]u8 = undefined;
    while (lines.next()) |raw| {
        const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..comment], " \t\r");
        if (line.len == 0) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const first = tokens.next().?;
        switch (format) {
            .domains => {
                if (tokens.next() != null) return error.InvalidListLine;
                const canonical = domain.normalize(first, &buffer) catch return error.InvalidListLine;
                try names.insert(canonical);
            },
            .hosts => {
                _ = std.Io.net.IpAddress.parse(first, 0) catch return error.InvalidListLine;
                var aliases: usize = 0;
                while (tokens.next()) |alias| {
                    const canonical = domain.normalize(alias, &buffer) catch return error.InvalidListLine;
                    aliases += 1;
                    if (!isLocalhost(canonical)) try names.insert(canonical);
                }
                if (aliases == 0) return error.InvalidListLine;
            },
        }
    }
    return names;
}

fn isLocalhost(name: []const u8) bool {
    const customary = [_][]const u8{
        "localhost",     "localhost.localdomain",   "localhost4",    "localhost4.localdomain4",
        "localhost6",    "localhost6.localdomain6", "ip6-localhost", "ip6-loopback",
        "ip6-allnodes",  "ip6-allrouters",          "ip6-localnet",  "ip6-mcastprefix",
        "broadcasthost",
    };
    for (customary) |alias| {
        if (std.mem.eql(u8, name, alias)) return true;
    }
    return false;
}

test "hosts supports aliases IPv4 IPv6 comments and skips customary local names" {
    var names = try parse(std.testing.allocator, "# hosts\r\n127.0.0.1 localhost LOCALHOST.localdomain\n0.0.0.0 ADS.Example. tracker.example # comment\n:: ads.example ipv6.example ip6-localhost\n", .hosts);
    defer names.deinit();
    try std.testing.expectEqual(@as(u32, 3), names.entries.count());
    try std.testing.expect(names.entries.contains("ads.example"));
    try std.testing.expect(names.entries.contains("tracker.example"));
    try std.testing.expect(names.entries.contains("ipv6.example"));
}

test "domain lists normalize and deduplicate without suffix matching" {
    var names = try parse(std.testing.allocator, "\n Ads.Example. # note\nads.example\n_www.test\n", .domains);
    defer names.deinit();
    try std.testing.expectEqual(@as(u32, 2), names.entries.count());
    try std.testing.expect(!names.entries.contains("child.ads.example"));
}

test "invalid content fails the complete import" {
    for ([_][]const u8{ "valid.test\n||ads.example^", "valid.test\n0.0.0.0 ads.example", "valid.test\n:: ads.example", "a.test b.test", "0.0.0.0", "https://example.test/", "[Adblock Plus 2.0]", "! not a supported comment", "<html>failure</html>", "a..test", "*.test", "a\x00.test" }) |text| {
        try std.testing.expectError(error.InvalidListLine, parse(std.testing.allocator, text, .domains));
    }
    for ([_][]const u8{ "not-an-ip a.test", "999.0.0.0 a.test", "::", "0.0.0.0 good.test *.test", "0.0.0.0 a.test\rb.test" }) |text| {
        try std.testing.expectError(error.InvalidListLine, parse(std.testing.allocator, text, .hosts));
    }
}
