const std = @import("std");
const Source = @import("../blocklist/source.zig").Source;
const domain = @import("../domains/domain.zig");
const Document = @import("document.zig").Document;

/// Owned, validated configuration data; no files are opened and no URLs fetched.
pub const Definitions = struct {
    blocks: std.ArrayList([]const u8) = .empty,
    allows: std.ArrayList([]const u8) = .empty,
    sources: std.ArrayList(Source) = .empty,

    pub fn deinit(self: *Definitions, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |text| allocator.free(text);
        self.blocks.deinit(allocator);
        for (self.allows.items) |text| allocator.free(text);
        self.allows.deinit(allocator);
        for (self.sources.items) |*source| source.deinit(allocator);
        self.sources.deinit(allocator);
        self.* = undefined;
    }
};

/// Validate and independently own filtering definitions, including disabled
/// sources. Domain spelling is normalized only in the runtime snapshot.
pub fn fromDocument(allocator: std.mem.Allocator, document: *const Document) !Definitions {
    var definitions: Definitions = .{};
    errdefer definitions.deinit(allocator);
    try copyDomains(allocator, document.blocks.domains, &definitions.blocks);
    try copyDomains(allocator, document.allows.domains, &definitions.allows);

    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(allocator);
    for (document.blocks.lists) |source| {
        try source.validate();
        if (!std.unicode.utf8ValidateSlice(source.source.value)) return error.InvalidSourceLocation;
        const entry = try ids.getOrPut(allocator, source.id);
        if (entry.found_existing) return error.DuplicateSourceId;
        var owned = try source.clone(allocator);
        errdefer owned.deinit(allocator);
        try definitions.sources.append(allocator, owned);
    }
    return definitions;
}

fn copyDomains(allocator: std.mem.Allocator, values: []const []const u8, result: *std.ArrayList([]const u8)) !void {
    for (values) |text| {
        var buffer: [253]u8 = undefined;
        const canonical = try domain.normalize(text, &buffer);
        const owned = try allocator.dupe(u8, canonical);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
}
