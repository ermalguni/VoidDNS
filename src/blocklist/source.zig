const std = @import("std");

pub const Source = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    enabled: bool = true,
    source: struct {
        kind: enum { url, file },
        value: []const u8,
    },
    format: enum { hosts, domains },

    /// Validate disabled definitions too. IDs and display names cannot inject
    /// terminal controls or extra log lines. Locations are never logged.
    pub fn validate(self: Source) !void {
        if (self.id.len == 0 or self.id.len > 128) return error.InvalidSourceId;
        for (self.id) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-')
                return error.InvalidSourceId;
        }
        if (self.name) |name| {
            if (name.len == 0 or name.len > 256) return error.InvalidSourceName;
            for (name) |byte| {
                if (byte < 0x20 or byte > 0x7e) return error.InvalidSourceName;
            }
        }
        if (self.source.value.len == 0) return error.InvalidSourceLocation;
        for (self.source.value) |byte| {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidSourceLocation;
        }
        switch (self.source.kind) {
            .file => {
                if (std.mem.find(u8, self.source.value, "://") != null)
                    return error.UnsupportedUriScheme;
            },
            .url => {
                // Downloads are always strict domain lists, never hosts or filter rules.
                if (self.format != .domains) return error.InvalidUrlFormat;
                const uri = std.Uri.parse(self.source.value) catch return error.InvalidSourceLocation;
                if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https"))
                    return error.UnsupportedUriScheme;
                if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or uri.fragment != null)
                    return error.InvalidSourceLocation;
            },
        }
    }

    pub fn clone(self: Source, allocator: std.mem.Allocator) !Source {
        try self.validate();
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = if (self.name) |value| try allocator.dupe(u8, value) else null;
        errdefer if (name) |value| allocator.free(value);
        const value = try allocator.dupe(u8, self.source.value);
        return .{
            .id = id,
            .name = name,
            .enabled = self.enabled,
            .source = .{ .kind = self.source.kind, .value = value },
            .format = self.format,
        };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.name) |name| allocator.free(name);
        allocator.free(self.source.value);
        self.* = undefined;
    }
};

test "disabled source definitions still require safe metadata and supported schemes" {
    var source: Source = .{ .id = "list-1", .enabled = false, .source = .{ .kind = .url, .value = "https://example.test/list" }, .format = .domains };
    try source.validate();
    source.id = "bad\nlog";
    try std.testing.expectError(error.InvalidSourceId, source.validate());
    source.id = "list-1";
    source.source.value = "ftp://example.test/list";
    try std.testing.expectError(error.UnsupportedUriScheme, source.validate());
    source.source.value = "https://example.test/list";
    source.name = "bad\x1blog";
    try std.testing.expectError(error.InvalidSourceName, source.validate());
}

test "URL sources cannot opt into hosts parsing" {
    var source: Source = .{
        .id = "remote",
        .source = .{ .kind = .url, .value = "https://example.test/list" },
        .format = .hosts,
    };
    try std.testing.expectError(error.InvalidUrlFormat, source.validate());
    source.enabled = false;
    try std.testing.expectError(error.InvalidUrlFormat, source.validate());
}
