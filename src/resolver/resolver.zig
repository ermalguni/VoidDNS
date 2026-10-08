const std = @import("std");
const Record = @import("../domains/record.zig");
const decode = @import("../dns/decode.zig");
const encode = @import("../dns/encode.zig");
const UpstreamPool = @import("upstream.zig").Pool;
const Cache = @import("../cache/cache.zig");
const CacheKey = @import("../cache/key.zig");
const edns = @import("../dns/edns.zig");
const State = @import("../state/state.zig").State;
const domain = @import("../domains/domain.zig");
const policy = @import("../policy/policy.zig");
const message = @import("../dns/message.zig");
const log = std.log.scoped(.resolver);

pub fn resolve(
    io: std.Io,
    query: []const u8,
    buffer: []u8,
    records: []const Record,
    cache: *Cache,
    upstreams: *UpstreamPool,
    state: *const State,
) ![]const u8 {
    const normalized = try edns.stripCookies(query, buffer);
    const request = normalized.packet;
    if (normalized.cookies_removed != 0) {
        log.debug("ignored query COOKIE id={d} removed={d}; cookie protection disabled", .{
            decode.id(request), normalized.cookies_removed,
        });
    }
    if (try managedAnswer(request, buffer, records, state)) |response|
        return response;

    if (cache.get(request, std.Io.Clock.awake.now(io).toSeconds(), buffer)) |hit|
        return hit;

    var saved: [CacheKey.max_query]u8 = undefined;
    const saved_key: ?[]const u8 = if (CacheKey.fromQuery(request)) |key| blk: {
        @memcpy(saved[0..key.len], key);
        break :blk saved[0..key.len];
    } else null;

    const received = try upstreams.forward(io, request, buffer);
    const sanitized = try edns.stripCookies(received, buffer);
    const response = sanitized.packet;
    if (sanitized.cookies_removed != 0) {
        log.debug("removed unsolicited response COOKIE id={d} removed={d}", .{
            decode.id(response), sanitized.cookies_removed,
        });
    }

    if (saved_key) |key| {
        cache.put(
            key,
            response,
            std.Io.Clock.awake.now(io).toSeconds(),
        ) catch |err| {
            std.log.warn("cache insertion failed: {s}", .{@errorName(err)});
        };
    }

    return response;
}

fn managedAnswer(
    query: []const u8,
    buffer: []u8,
    records: []const Record,
    state: *const State,
) !?[]const u8 {
    const question = try decode.question(query);
    var canonical_buffer: [253]u8 = undefined;
    const canonical = domain.fromWire(&question.name, &canonical_buffer) orelse return null;

    var local: ?*const Record = null;
    if (question.qclass == .internet) {
        for (records) |*record| {
            if (record.data(question.qtype) != null and question.name.matches(record.name)) {
                local = record;
                break;
            }
        }
    }

    return switch (policy.decide(state, canonical, local != null)) {
        .block => try blockedAnswer(&question, buffer),
        .local => try encode.address(&question, local.?.data(question.qtype).?, local.?.ttl_seconds, buffer),
        .forward => null,
    };
}

fn blockedAnswer(question: *const message.Question, buffer: []u8) ![]const u8 {
    // Sinkhole RDATA is defined only for IN. Other classes and unsupported
    // types receive NODATA rather than address bytes with incorrect semantics.
    if (question.qclass != .internet) return encode.nodata(question, buffer);
    return switch (question.qtype) {
        .a => encode.address(question, &.{ 0, 0, 0, 0 }, 0, buffer),
        .aaaa => encode.address(question, &([_]u8{0} ** 16), 0, buffer),
        else => encode.nodata(question, buffer),
    };
}

const test_query = "\x12\x34\x01\x10\x00\x01\x00\x00\x00\x00\x00\x00" ++
    "\x04HoMe\x04TeSt\x00\x00\x01\x00\x01";

fn importTestNames(state: *State) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "domains.txt", .data = "home.test\nimported.test\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "domains.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try state.lists.add(std.testing.io, .{
        .id = "test",
        .source = .{ .kind = .file, .value = path },
        .format = .domains,
    }, ".");
}

test "explicit blocks override allows and local records with zero TTL sinkholes or NODATA" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.domains.allow("home.test");
    try state.domains.block("HOME.TEST.");
    var cache = try Cache.init(std.testing.allocator, 16);
    defer cache.deinit();
    const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53)};
    var upstreams = try UpstreamPool.init(&addresses, 3000);
    const records = [_]Record{.{
        .name = "home.test",
        .a = .{ 192, 0, 2, 10 },
        .aaaa = [_]u8{1} ** 16,
    }};
    const cases = [_]struct { qtype: u16, qclass: u16, data_len: usize }{
        .{ .qtype = 1, .qclass = 1, .data_len = 4 },
        .{ .qtype = 28, .qclass = 1, .data_len = 16 },
        .{ .qtype = 65000, .qclass = 1, .data_len = 0 },
        .{ .qtype = 1, .qclass = 3, .data_len = 0 },
        .{ .qtype = 28, .qclass = 3, .data_len = 0 },
    };
    for (cases, 0..) |case, i| {
        var buffer: [512]u8 = undefined;
        @memcpy(buffer[0..test_query.len], test_query);
        const id: u16 = @intCast(0xab00 + i);
        std.mem.writeInt(u16, buffer[0..2], id, .big);
        std.mem.writeInt(u16, buffer[test_query.len - 4 ..][0..2], case.qtype, .big);
        std.mem.writeInt(u16, buffer[test_query.len - 2 ..][0..2], case.qclass, .big);
        const response = try resolve(std.testing.io, buffer[0..test_query.len], &buffer, &records, &cache, &upstreams, &state);
        try std.testing.expectEqual(id, decode.id(response));
        try std.testing.expectEqual(@as(u16, 0x8190), decode.flags(response));
        try std.testing.expectEqual(case.qtype, std.mem.readInt(u16, response[test_query.len - 4 ..][0..2], .big));
        try std.testing.expectEqual(case.qclass, std.mem.readInt(u16, response[test_query.len - 2 ..][0..2], .big));
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, response[8..12]);
        if (case.data_len == 0) {
            try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, response[6..8], .big));
            try std.testing.expectEqual(test_query.len, response.len);
        } else {
            try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, response[6..8], .big));
            try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, response[test_query.len + 6 ..][0..4], .big));
            try std.testing.expectEqual(case.data_len, std.mem.readInt(u16, response[test_query.len + 10 ..][0..2], .big));
            const zeroes = [_]u8{0} ** 16;
            try std.testing.expectEqualSlices(u8, zeroes[0..case.data_len], response[test_query.len + 12 ..]);
        }
    }
    for (cache.slots) |slot| try std.testing.expect(slot == null);
}

test "cached upstream answers cannot bypass a new explicit or imported block" {
    for ([_]bool{ false, true }) |imported| {
        var state = State.init(std.testing.allocator);
        defer state.deinit();
        var cache = try Cache.init(std.testing.allocator, 16);
        defer cache.deinit();
        var buffer: [512]u8 = undefined;
        const question = try decode.question(test_query);
        const upstream_answer = try encode.address(&question, &.{ 192, 0, 2, 20 }, 60, &buffer);
        try cache.put(CacheKey.fromQuery(test_query).?, upstream_answer, std.Io.Clock.awake.now(std.testing.io).toSeconds());
        if (imported) {
            try importTestNames(&state);
        } else {
            try state.domains.block("home.test");
        }
        const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53)};
        var upstreams = try UpstreamPool.init(&addresses, 3000);
        const response = try resolve(std.testing.io, test_query, &buffer, &.{}, &cache, &upstreams, &state);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, response[response.len - 4 ..]);
        try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, response[test_query.len + 6 ..][0..4], .big));
    }
}

test "allows bypass imported blocks while local answers precede imports and cached upstream answers" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try importTestNames(&state);
    var cache = try Cache.init(std.testing.allocator, 16);
    defer cache.deinit();
    var buffer: [512]u8 = undefined;
    const question = try decode.question(test_query);
    const upstream_answer = try encode.address(&question, &.{ 192, 0, 2, 20 }, 60, &buffer);
    try cache.put(CacheKey.fromQuery(test_query).?, upstream_answer, std.Io.Clock.awake.now(std.testing.io).toSeconds());
    const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53)};
    var upstreams = try UpstreamPool.init(&addresses, 3000);
    const records = [_]Record{.{ .name = "home.test", .a = .{ 192, 0, 2, 10 } }};

    // A local answer wins over both an imported block and an upstream cache hit.
    const local = try resolve(std.testing.io, test_query, &buffer, &records, &cache, &upstreams, &state);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, local[local.len - 4 ..]);
    try state.domains.allow("HOME.TEST.");
    const allowed_local = try resolve(std.testing.io, test_query, &buffer, &records, &cache, &upstreams, &state);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, allowed_local[allowed_local.len - 4 ..]);

    // Without a local record, the allow exposes the original upstream cache
    // entry; the preceding local answers must not have replaced it.
    const allowed = try resolve(std.testing.io, test_query, &buffer, &.{}, &cache, &upstreams, &state);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 20 }, allowed[allowed.len - 4 ..]);
}

test "COOKIE normalization preserves local responses and request IDs without caching them" {
    const prefix = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x01" ++
        "\x04home\x04test\x00\x00\x01\x00\x01" ++
        "\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x0c\x00\x0a\x00\x08";
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var cache = try Cache.init(std.testing.allocator, 16);
    defer cache.deinit();
    const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53)};
    var upstreams = try UpstreamPool.init(&addresses, 3000);
    const records = [_]Record{.{ .name = "home.test", .a = .{ 192, 0, 2, 10 } }};
    for ([_][]const u8{ "abcdefgh", "12345678" }, 0..) |cookie, i| {
        var buffer: [512]u8 = undefined;
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[prefix.len..][0..cookie.len], cookie);
        const id: u16 = @intCast(0xab34 + i);
        std.mem.writeInt(u16, buffer[0..2], id, .big);
        const response = try resolve(std.testing.io, buffer[0 .. prefix.len + cookie.len], &buffer, &records, &cache, &upstreams, &state);
        try std.testing.expectEqual(id, decode.id(response));
        try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, response[response.len - 4 ..]);
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, response[10..12], .big));
    }
    for (cache.slots) |slot| try std.testing.expect(slot == null);
}

test "policy does not bypass signed COOKIE and malformed option rejection" {
    const prefix = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x01" ++
        "\x04home\x04test\x00\x00\x01\x00\x01" ++
        "\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x0c\x00\x0a\x00\x08";
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    try state.domains.block("home.test");
    var cache = try Cache.init(std.testing.allocator, 0);
    defer cache.deinit();
    const addresses = [_]std.Io.net.IpAddress{try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53)};
    var upstreams = try UpstreamPool.init(&addresses, 3000);
    var buffer: [512]u8 = undefined;
    const signed = prefix ++ "abcdefgh" ++ "\x00\x00\xfa\x00\xff\x00\x00\x00\x00\x00\x00";
    @memcpy(buffer[0..signed.len], signed);
    buffer[11] = 2;
    try std.testing.expectError(error.AuthenticatedCookie, resolve(std.testing.io, buffer[0..signed.len], &buffer, &.{}, &cache, &upstreams, &state));

    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..8], "abcdefgh");
    buffer[prefix.len - 1] = 9;
    try std.testing.expectError(error.InvalidOption, resolve(std.testing.io, buffer[0 .. prefix.len + 8], &buffer, &.{}, &cache, &upstreams, &state));
    try std.testing.expectError(error.InvalidMessage, resolve(std.testing.io, &.{0}, &buffer, &.{}, &cache, &upstreams, &state));
    try std.testing.expectError(error.InvalidQuestion, resolve(std.testing.io, test_query[0 .. test_query.len - 1], &buffer, &.{}, &cache, &upstreams, &state));
    @memcpy(buffer[0..test_query.len], test_query);
    buffer[5] = 2;
    try std.testing.expectError(error.UnsupportedQuestion, resolve(std.testing.io, buffer[0..test_query.len], &buffer, &.{}, &cache, &upstreams, &state));
}
