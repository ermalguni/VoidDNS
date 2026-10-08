const std = @import("std");
const Record = @import("../domains/record.zig");
const decode = @import("../dns/decode.zig");
const encode = @import("../dns/encode.zig");
const UpstreamPool = @import("upstream.zig").Pool;
const Cache = @import("../cache/cache.zig");
const CacheKey = @import("../cache/key.zig");
const edns = @import("../dns/edns.zig");
const log = std.log.scoped(.resolver);

pub fn resolve(
    io: std.Io,
    query: []const u8,
    buffer: []u8,
    records: []const Record,
    cache: *Cache,
    upstreams: *UpstreamPool,
) ![]const u8 {
    const normalized = try edns.stripCookies(query, buffer);
    const request = normalized.packet;
    if (normalized.cookies_removed != 0) {
        log.debug("ignored query COOKIE id={d} removed={d}; cookie protection disabled", .{
            decode.id(request), normalized.cookies_removed,
        });
    }
    if (cache.get(request, std.Io.Clock.awake.now(io).toSeconds(), buffer)) |hit|
        return hit;

    var saved: [CacheKey.max_query]u8 = undefined;
    const saved_key: ?[]const u8 = if (CacheKey.fromQuery(request)) |key| blk: {
        @memcpy(saved[0..key.len], key);
        break :blk saved[0..key.len];
    } else null;

    const received = try resolveMiss(io, request, buffer, records, upstreams);
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

fn resolveMiss(
    io: std.Io,
    query: []const u8,
    buffer: []u8,
    records: []const Record,
    upstreams: *UpstreamPool,
) ![]const u8 {
    const question = decode.question(query) catch
        return upstreams.forward(io, query, buffer);

    if (question.qclass != .internet)
        return upstreams.forward(io, query, buffer);

    switch (question.qtype) {
        .a, .aaaa => {
            for (records) |*record| {
                if (!question.name.matches(record.name)) continue;

                const data = record.data(question.qtype) orelse continue;
                return encode.address(
                    &question,
                    data,
                    record.ttl_seconds,
                    buffer,
                );
            }
        },
        else => {},
    }

    return upstreams.forward(io, query, buffer);
}

test "different client cookies share a local answer and restore the request ID" {
    const prefix = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x01" ++
        "\x04home\x04test\x00\x00\x01\x00\x01" ++
        "\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x0c\x00\x0a\x00\x08";
    const first = prefix ++ "abcdefgh";
    const second = prefix ++ "12345678";
    var cache = try Cache.init(std.testing.allocator, 16);
    defer cache.deinit();
    var buffer: [512]u8 = undefined;
    const records = [_]Record{.{ .name = "home.test", .a = .{ 192, 0, 2, 10 } }};
    const upstream_addresses = [_]std.Io.net.IpAddress{
        try std.Io.net.IpAddress.parseIp4("192.0.2.1", 53),
    };
    var upstreams = try UpstreamPool.init(&upstream_addresses, 3000);

    @memcpy(buffer[0..first.len], first);
    _ = try resolve(std.testing.io, buffer[0..first.len], &buffer, &records, &cache, &upstreams);
    @memcpy(buffer[0..second.len], second);
    buffer[0] = 0xab;
    // A changed local value distinguishes a cache hit from resolving again.
    const changed_records = [_]Record{.{ .name = "home.test", .a = .{ 192, 0, 2, 99 } }};
    const response = try resolve(std.testing.io, buffer[0..second.len], &buffer, &changed_records, &cache, &upstreams);
    try std.testing.expectEqual(@as(u16, 0xab34), decode.id(response));
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, response[response.len - 4 ..]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, response[10..12], .big));
}
