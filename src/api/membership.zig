const std = @import("std");
const State = @import("../state/state.zig").State;
const Service = @import("../blocklist/service.zig").Service;
const Index = @import("../blocklist/index.zig").Index;
const Store = @import("../lists/store.zig").Store;
const domain = @import("../domains/domain.zig");
const bridge = @import("bridge.zig");

pub const Source = struct { id: []const u8, name: ?[]const u8, status: Service.Health };
const Match = struct { domain: []const u8, source_ids: []const []const u8 };
const Batch = struct { generation: u64, sources: []Source, matches: []Match };
const Kind = enum { active, saved };
const Snapshot = struct { kind: Kind, version: []const u8, last_success_at_ms: ?i64, domain_count: usize, active: bool };

pub fn owns(request: bridge.Request) bool {
    return (eq(request.path, "/api/v1/blocklists/matches") and eq(request.method, "POST")) or browseId(request.path) != null;
}

fn browseId(path: []const u8) ?[]const u8 {
    const start = "/api/v1/blocklists/";
    const end = "/domains";
    if (!std.mem.startsWith(u8, path, start) or !std.mem.endsWith(u8, path, end) or path.len <= start.len + end.len) return null;
    const id = path[start.len .. path.len - end.len];
    if (std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return id;
}

/// Called on HTTP handler threads, never the serialized main writer loop.
pub fn handle(state: *State, io: std.Io, a: std.mem.Allocator, request: bridge.Request) !bridge.Response {
    return read(state, io, a, request) catch |err| {
        const status: u16 = if (std.mem.startsWith(u8, @errorName(err), "SQLite")) 503 else switch (err) {
            error.SourceNotFound, error.SnapshotUnavailable => 404,
            error.StaleCursor => 409,
            error.MethodNotAllowed => 405,
            error.OutOfMemory => 500,
            else => 400,
        };
        return reply(a, status, .{ .@"error" = .{ .code = @errorName(err), .message = @errorName(err) } });
    };
}

fn read(state: *State, io: std.Io, a: std.mem.Allocator, request: bridge.Request) !bridge.Response {
    if (eq(request.path, "/api/v1/blocklists/matches")) {
        if (!eq(request.method, "POST")) return error.MethodNotAllowed;
        const body = try std.json.parseFromSlice(std.json.Value, a, request.body, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
        defer body.deinit();
        if (body.value != .object or body.value.object.count() != 1) return error.InvalidBody;
        const domains = body.value.object.get("domains") orelse return error.InvalidBody;
        if (domains != .array) return error.InvalidBody;
        if (domains.array.items.len > 100) return error.TooManyDomains;
        var names: std.ArrayList([]const u8) = .empty;
        for (domains.array.items) |value| {
            if (value != .string) return error.InvalidBody;
            const raw = value.string;
            var buffer: [253]u8 = undefined;
            const name = try domain.normalize(raw, &buffer);
            var duplicate = false;
            for (names.items) |existing| if (eq(existing, name)) { duplicate = true; break; };
            if (!duplicate) try names.append(a, try a.dupe(u8, name));
        }
        return reply(a, 200, try collect(state, io, a, names.items));
    }
    if (!eq(request.method, "GET")) return error.MethodNotAllowed;
    const id = try decode(a, browseId(request.path) orelse return error.SourceNotFound);
    if (id.len == 0 or id.len > 128) return error.SourceNotFound;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return error.SourceNotFound;
    const exact_raw = try parameter(a, request.query, "domain");
    const prefix_raw = try parameter(a, request.query, "prefix");
    if (exact_raw != null and prefix_raw != null) return error.ConflictingFilters;
    var exact_buffer: [253]u8 = undefined;
    var prefix_buffer: [253]u8 = undefined;
    const exact = if (exact_raw) |raw| try domain.normalize(raw, &exact_buffer) else null;
    const prefix = if (prefix_raw) |raw| try normalizePrefix(raw, &prefix_buffer) else null;
    const limit_raw = (try parameter(a, request.query, "limit")) orelse "50";
    if (limit_raw.len == 0) return error.InvalidLimit;
    for (limit_raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidLimit;
    const limit = std.fmt.parseInt(usize, limit_raw, 10) catch return error.InvalidLimit;
    if (limit == 0 or limit > 100) return error.InvalidLimit;
    const after = try parameter(a, request.query, "after");
    const last = if (after) |cursor| blk: {
        if (cursor.len < 66 or cursor.len > 318 or cursor[64] != ':') return error.InvalidCursor;
        var buffer: [253]u8 = undefined;
        const normalized = domain.normalize(cursor[65..], &buffer) catch return error.InvalidCursor;
        if (!eq(normalized, cursor[65..])) return error.InvalidCursor;
        break :blk cursor[65..];
    } else "";
    const kind_raw = try parameter(a, request.query, "snapshot");
    const requested: ?Kind = if (kind_raw) |raw| (std.meta.stringToEnum(Kind, raw) orelse return error.InvalidSnapshot) else null;
    var version: [32]u8 = undefined;
    var success: ?i64 = null;
    var count: usize = 0;
    var items: std.ArrayList([]const u8) = .empty;
    var kind: Kind = undefined;
    var fingerprint: ?[64]u8 = null;
    var store: ?*Store = null;
    {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        const entry = state.lists.sources.get(id) orelse return error.SourceNotFound;
        kind = requested orelse if (entry.source.enabled) Kind.active else Kind.saved;
        if (kind == .active) {
            version = entry.version orelse return error.SnapshotUnavailable;
            if (!contributes(entry.health)) return error.SnapshotUnavailable;
            success = entry.health.last_success_at_ms;
            count = entry.snapshot.len;
            const lower = if (last.len != 0) last else exact orelse prefix orelse "";
            var position = Index.lowerBound(entry.snapshot, lower);
            if (position < entry.snapshot.len and last.len != 0 and eq(entry.snapshot[position], last)) position += 1;
            while (position < entry.snapshot.len and items.items.len < limit + 1) : (position += 1) {
                const name = entry.snapshot[position];
                if (exact) |value| { if (!eq(name, value)) break; }
                if (prefix) |value| { if (!std.mem.startsWith(u8, name, value)) break; }
                try items.append(a, try a.dupe(u8, name));
            }
        } else {
            fingerprint = entry.fingerprint;
            store = state.lists.store;
        }
    }
    var active = kind == .active;
    if (kind == .saved) {
        const saved_store = store orelse return error.SnapshotUnavailable;
        const key = fingerprint orelse return error.SnapshotUnavailable;
        const page = try saved_store.browse(a, id, &key, exact, prefix, last, limit + 1) orelse return error.SnapshotUnavailable;
        version = page.version;
        success = page.last_success_at_ms;
        count = page.domain_count;
        try items.appendSlice(a, page.items);
        // Recheck after the SQL transaction. A concurrently published source
        // must demonstrably use this exact content version and definition.
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.lists.sources.get(id)) |current| {
            if (current.version) |used| {
                if (current.fingerprint) |current_key| active = contributes(current.health) and std.mem.eql(u8, &used, &version) and std.mem.eql(u8, &key, &current_key);
            }
        }
    }
    const binding = try cursorBinding(a, id, kind, &version, exact, prefix);
    if (after) |cursor| if (!eq(cursor[0..64], &binding)) return error.StaleCursor;
    const has_more = items.items.len > limit;
    const visible = items.items[0..@min(limit, items.items.len)];
    const next = if (has_more) try std.fmt.allocPrint(a, "{s}:{s}", .{ binding, visible[visible.len - 1] }) else null;
    return reply(a, 200, .{ .source_id = id, .snapshot = Snapshot{ .kind = kind, .version = &version, .last_success_at_ms = success, .domain_count = count, .active = active }, .items = visible, .next_cursor = next });
}

/// Cost is source-count × at most 100 binary searches, never domain totals.
pub fn collect(state: *State, io: std.Io, a: std.mem.Allocator, names: []const []const u8) !Batch {
    if (names.len > 100) return error.TooManyDomains;
    var sources: std.ArrayList(Source) = .empty;
    const matches = try a.alloc(Match, names.len);
    const ids = try a.alloc(std.ArrayList([]const u8), names.len);
    for (ids) |*list| list.* = .empty;
    for (matches, names) |*match, name| match.* = .{ .domain = name, .source_ids = &.{} };
    var generation: u64 = undefined;
    {
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        generation = state.lists.generation;
        var entries = state.lists.sources.valueIterator();
        while (entries.next()) |entry| {
            if (!contributes(entry.health)) continue;
            var copied: ?Source = null;
            for (names, ids) |name, *list| {
                if (!Index.snapshotContains(entry.snapshot, name)) continue;
                if (copied == null) {
                    copied = try copySource(a, entry.source.id, entry.source.name, entry.health);
                    try sources.append(a, copied.?);
                }
                try list.append(a, copied.?.id);
            }
        }
    }
    std.mem.sort(Source, sources.items, {}, struct { fn less(_: void, l: Source, r: Source) bool { return std.mem.lessThan(u8, l.id, r.id); } }.less);
    for (matches, ids) |*match, list| {
        std.mem.sort([]const u8, list.items, {}, struct { fn less(_: void, l: []const u8, r: []const u8) bool { return std.mem.lessThan(u8, l, r); } }.less);
        match.source_ids = list.items;
    }
    return .{ .generation = generation, .sources = sources.items, .matches = matches };
}

pub fn copySource(a: std.mem.Allocator, id: []const u8, name: ?[]const u8, status: Service.Health) !Source {
    var health = status;
    if (health.last_error) |text| health.last_error = try a.dupe(u8, text);
    return .{ .id = try a.dupe(u8, id), .name = if (name) |text| try a.dupe(u8, text) else null, .status = health };
}

pub fn contributes(health: Service.Health) bool { return health.state == .active or health.state == .degraded; }

fn cursorBinding(a: std.mem.Allocator, id: []const u8, kind: Kind, version: []const u8, exact: ?[]const u8, prefix: ?[]const u8) ![64]u8 {
    const serialized = try std.json.Stringify.valueAlloc(a, .{ "source-domains-v1", id, kind, version, exact, prefix }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(serialized, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A prefix is partial input, not an exact name: a final dot or hyphen is
/// permitted, but empty labels, non-ASCII, wildcards and oversized labels aren't.
fn normalizePrefix(input: []const u8, buffer: *[253]u8) ![]const u8 {
    if (input.len == 0 or input.len > buffer.len) return error.InvalidPrefix;
    var label_len: usize = 0;
    for (input, 0..) |byte, i| {
        if (byte == '.') {
            if (label_len == 0 or input[i - 1] == '-') return error.InvalidPrefix;
            label_len = 0;
        } else {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidPrefix;
            if (label_len == 0 and byte == '-') return error.InvalidPrefix;
            label_len += 1;
            if (label_len > 63) return error.InvalidPrefix;
        }
        buffer[i] = std.ascii.toLower(byte);
    }
    return buffer[0..input.len];
}

fn eq(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
fn reply(a: std.mem.Allocator, status: u16, value: anytype) !bridge.Response { return .{ .status = status, .body = try std.json.Stringify.valueAlloc(a, value, .{}) }; }
fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const result = try a.alloc(u8, text.len);
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) : (i += 1) {
        const byte = if (text[i] == '%') blk: {
            if (text.len - i < 3) return error.InvalidEncoding;
            const b = std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16) catch return error.InvalidEncoding;
            i += 2;
            break :blk b;
        } else if (text[i] == '+') ' ' else text[i];
        if (byte == 0) return error.InvalidEncoding;
        result[used] = byte;
        used += 1;
    }
    return result[0..used];
}
fn parameter(a: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, std.mem.trimStart(u8, query, "?"), '&');
    var found: ?[]const u8 = null;
    while (pairs.next()) |pair| {
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!eq(try decode(a, pair[0..split]), name)) continue;
        if (found != null) return error.DuplicateParameter;
        found = try decode(a, if (split == pair.len) "" else pair[split + 1 ..]);
    }
    return found;
}

test "partial prefixes and cursor bindings are strict and normalized" {
    var buffer: [253]u8 = undefined;
    try std.testing.expectEqualStrings("ads-", try normalizePrefix("ADS-", &buffer));
    try std.testing.expectEqualStrings("ads.", try normalizePrefix("ADS.", &buffer));
    for ([_][]const u8{ "", ".", "a..", "-a", "a-.", "a*", "é" }) |bad| try std.testing.expectError(error.InvalidPrefix, normalizePrefix(bad, &buffer));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try cursorBinding(a, "a", .active, "one", null, "ads");
    try std.testing.expect(!eq(&first, &(try cursorBinding(a, "b", .active, "one", null, "ads"))));
    try std.testing.expect(!eq(&first, &(try cursorBinding(a, "a", .saved, "one", null, "ads"))));
    try std.testing.expect(!eq(&first, &(try cursorBinding(a, "a", .active, "two", null, "ads"))));
    try std.testing.expect(!eq(&first, &(try cursorBinding(a, "a", .active, "one", "ads", null))));
}
