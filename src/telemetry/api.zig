const std = @import("std");
const sqlite = @import("sqlite");
const Store = @import("store.zig").Store;
const retention_ms = @import("store.zig").retention_ms;
const events = @import("event.zig");
const bridge = @import("../api/bridge.zig");
const domain = @import("../domains/domain.zig");

const Cursor = struct { from: i64, to: i64, high: i64, last: i64, time: i64, fingerprint: u64 };
const Filter = struct {
    from: i64,
    to: i64,
    client: ?i64 = null,
    resolution: ?[]const u8 = null,
    name: ?[]const u8 = null,
    qtype: ?u16 = null,
    transport: ?[]const u8 = null,
    errors: bool = false,
    limit: u8 = 50,
    interval: i64 = 900_000,
    high: i64 = 0,
    last: i64 = 0,
    time: i64 = std.math.maxInt(i64),
};

const prefix =
    "WITH p(f,t,c,r,d,q,tr,e,h,cutoff) AS (VALUES(?,?,?,?,?,?,?,?,?,?)), filtered AS (" ++
    "SELECT requests.* FROM requests,p WHERE received_at_ms>=p.f AND received_at_ms>=p.cutoff AND received_at_ms<p.t AND id<=p.h " ++
    "AND (p.c IS NULL OR client_id=p.c) AND (p.r IS NULL OR resolution=p.r) " ++
    "AND (p.d IS NULL OR domain=p.d) AND (p.q IS NULL OR query_type=p.q) " ++
    "AND (p.tr IS NULL OR transport=p.tr) AND (p.e=0 OR error IS NOT NULL)) ";
const counts = "count(*) AS total,coalesce(sum(resolution='blocked'),0) AS blocked,coalesce(sum(resolution='cached'),0) AS cached,coalesce(sum(resolution='forwarded'),0) AS forwarded,coalesce(sum(resolution='local'),0) AS local,coalesce(sum(resolution='rejected'),0) AS rejected,coalesce(sum(error IS NOT NULL),0) AS errors";
const count_json = "'total',total,'blocked',blocked,'cached',cached,'forwarded',forwarded,'local',local,'rejected',rejected,'errors',errors";

pub fn owns(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/v1/metrics/") or eq(path, "/api/v1/clients") or
        std.mem.startsWith(u8, path, "/api/v1/clients/") or eq(path, "/api/v1/requests");
}

pub fn handle(store: *Store, a: std.mem.Allocator, request: bridge.Request) !bridge.Response {
    return read(store, a, request) catch |err| reply(a, if (std.mem.startsWith(u8, @errorName(err), "SQLite")) @as(u16, 503) else switch (err) {
        error.NotFound => 404,
        error.MethodNotAllowed => 405,
        error.ExpiredCursor => 409,
        error.OutOfMemory => 500,
        else => 400,
    }, .{ .@"error" = .{ .code = @errorName(err), .message = @errorName(err) } });
}

fn read(store: *Store, a: std.mem.Allocator, request: bridge.Request) !bridge.Response {
    if (!eq(request.method, "GET")) return error.MethodNotAllowed;
    const path = request.path[8..];
    if (eq(path, "metrics/health")) {
        store.queue_mutex.lockUncancelable(store.io);
        const pending = store.count;
        store.queue_mutex.unlock(store.io);
        return reply(a, 200, .{ .writer_healthy = store.healthy.load(.monotonic), .pending_events = pending, .dropped_events_since_start = store.dropped.load(.monotonic), .last_persisted_at_ms = store.last_persisted.load(.monotonic), .retention_days = 7 });
    }
    var f = try filter(a, request.query, events.now(store.io));
    const fingerprint = std.hash.Wyhash.hash(0, try std.json.Stringify.valueAlloc(a, .{ path, f.from, f.to, f.client, f.resolution, f.name, f.qtype, f.transport, f.errors }, .{}));
    if (try parameter(a, request.query, "after")) |after| {
        const cursor = try decodeCursor(a, after);
        if (cursor.fingerprint != fingerprint) return error.CursorFilterMismatch;
        f.high = cursor.high;
        f.last = cursor.last;
        f.time = cursor.time;
    }
    // Only metrics readers serialize here. DNS never acquires this mutex.
    store.reader_mutex.lockUncancelable(store.io);
    defer store.reader_mutex.unlock(store.io);
    var deadline: Deadline = .{ .io = store.io, .started = std.Io.Clock.awake.now(store.io) };
    sqlite.c.sqlite3_progress_handler(store.reader.db, 10000, Deadline.check, &deadline);
    defer sqlite.c.sqlite3_progress_handler(store.reader.db, 0, null, null);
    try store.reader.exec("BEGIN", .{}, .{});
    defer store.reader.exec("ROLLBACK", .{}, .{}) catch {};
    if (f.high == 0 and f.last == 0) f.high = (try store.reader.one(i64, "SELECT coalesce(max(id),0) FROM requests", .{}, .{})).?;
    const values = .{ f.from, f.to, f.client, f.resolution, f.name, f.qtype, f.transport, @intFromBool(f.errors), f.high, events.now(store.io) - retention_ms };
    var suffix: []const u8 = undefined;
    const requests_page = eq(path, "requests");
    const clients_page = eq(path, "clients");
    if (eq(path, "metrics/summary")) {
        suffix = "SELECT json_object(" ++ count_json ++ ",'active_clients',active_clients,'blocked_percentage',CASE WHEN total=0 THEN 0.0 ELSE 100.0*blocked/total END,'cache_hit_percentage',CASE WHEN cached+forwarded=0 THEN 0.0 ELSE 100.0*cached/(cached+forwarded) END,'average_duration_us',average_duration_us) FROM (SELECT " ++ counts ++ ",count(DISTINCT client_id) AS active_clients,coalesce(avg(duration_us),0.0) AS average_duration_us FROM filtered)";
    } else if (eq(path, "metrics/timeseries")) {
        suffix = try std.fmt.allocPrint(a, "SELECT json_group_array(json_object('start_ms',start_ms," ++ count_json ++ ")) FROM (SELECT {d}+((received_at_ms-{d})/{d})*{d} AS start_ms," ++ counts ++ " FROM filtered GROUP BY start_ms ORDER BY start_ms)", .{ f.from, f.from, f.interval, f.interval });
    } else if (eq(path, "metrics/domains")) {
        suffix = try std.fmt.allocPrint(a, "SELECT json_group_array(json_object('domain',domain," ++ count_json ++ ")) FROM (SELECT domain," ++ counts ++ " FROM filtered WHERE domain IS NOT NULL GROUP BY domain ORDER BY total DESC,domain LIMIT {d})", .{f.limit});
    } else if (clients_page or eq(path, "metrics/clients")) {
        // LIMIT must apply to rows before the JSON aggregate, not its single output row.
        suffix = try std.fmt.allocPrint(a, "SELECT json_group_array(json(item)) FROM (SELECT json_object('id',c.id,'ip_address',c.ip_address,'name',c.name,'first_seen_at_ms',c.first_seen_at_ms,'last_seen_at_ms',c.last_seen_at_ms,'total',coalesce(s.total,0),'blocked',coalesce(s.blocked,0),'cached',coalesce(s.cached,0),'forwarded',coalesce(s.forwarded,0),'local',coalesce(s.local,0),'rejected',coalesce(s.rejected,0),'errors',coalesce(s.errors,0)) AS item FROM clients c LEFT JOIN (SELECT client_id," ++ counts ++ " FROM filtered GROUP BY client_id) s ON c.id=s.client_id WHERE c.id>{d} AND ({d}=0 OR c.id={d}) {s} ORDER BY {s} LIMIT {d})", .{ f.last, f.client orelse 0, f.client orelse 0, if (clients_page) "" else "AND s.total>0", if (clients_page) "c.id" else "s.total DESC,c.id", @as(usize, f.limit) + 1 });
    } else if (std.mem.startsWith(u8, path, "clients/")) {
        const id = try positive(path[8..]);
        const body = try store.reader.oneAlloc([]const u8, a, "SELECT json_object('id',id,'ip_address',ip_address,'name',name,'first_seen_at_ms',first_seen_at_ms,'last_seen_at_ms',last_seen_at_ms) FROM clients WHERE id=?", .{}, .{id}) orelse return error.NotFound;
        return .{ .body = body };
    } else if (requests_page) {
        suffix = try std.fmt.allocPrint(a, "SELECT json_group_array(json(item)) FROM (SELECT json_object('id',r.id,'client_id',r.client_id,'ip_address',c.ip_address,'client_name',c.name,'received_at_ms',r.received_at_ms,'domain',r.domain,'query_type',r.query_type,'query_class',r.query_class,'transport',r.transport,'resolution',r.resolution,'rcode',r.rcode,'duration_us',r.duration_us,'error',r.error) AS item FROM filtered r JOIN clients c ON c.id=r.client_id WHERE r.received_at_ms<{d} OR (r.received_at_ms={d} AND r.id<{d}) ORDER BY r.received_at_ms DESC,r.id DESC LIMIT {d})", .{ f.time, f.time, if (f.last == 0) std.math.maxInt(i64) else f.last, @as(usize, f.limit) + 1 });
    } else return error.NotFound;
    const sql = try std.mem.concat(a, u8, &.{ prefix, suffix });
    const body = (try store.reader.oneDynamicAlloc([]const u8, a, sql, .{}, values)).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{ .allocate = .alloc_always });
    var result = parsed.value;
    var next: ?[]const u8 = null;
    if ((requests_page or clients_page) and result.array.items.len > f.limit) {
        result.array.items.len = f.limit;
        const last = result.array.items[result.array.items.len - 1].object;
        next = try encodeCursor(a, .{ .from = f.from, .to = f.to, .high = f.high, .last = last.get("id").?.integer, .time = if (requests_page) last.get("received_at_ms").?.integer else 0, .fingerprint = fingerprint });
    } else if (eq(path, "metrics/clients") and result.array.items.len > f.limit) result.array.items.len = f.limit;
    return reply(a, 200, .{ .from_ms = f.from, .to_ms = f.to, .observed_at_ms = events.now(store.io), .interval_ms = f.interval, .data = result, .next = next });
}

const Deadline = struct {
    io: std.Io,
    started: std.Io.Timestamp,
    fn check(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Deadline = @ptrCast(@alignCast(context.?));
        return @intFromBool(self.started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 2000);
    }
};

fn filter(a: std.mem.Allocator, query: []const u8, now: i64) !Filter {
    var cursor: ?Cursor = null;
    if (try parameter(a, query, "after")) |after| cursor = try decodeCursor(a, after);
    var f: Filter = .{ .from = if (cursor) |c| c.from else now - 86_400_000, .to = if (cursor) |c| c.to else now };
    if (try parameter(a, query, "from")) |value| f.from = try timestamp(value);
    if (try parameter(a, query, "to")) |value| f.to = try timestamp(value);
    // Allow a small transport delay at the oldest boundary; SQL still excludes expired rows.
    if (f.from < 0 or f.to > now or f.from >= f.to or f.to - f.from > retention_ms) return error.InvalidTimeRange;
    if (cursor == null and f.from < now - retention_ms - 5000) return error.InvalidTimeRange;
    if (cursor != null and f.to <= now - retention_ms) return error.ExpiredCursor;
    if (try parameter(a, query, "client_id")) |value| f.client = try positive(value);
    if (try parameter(a, query, "resolution")) |value| {
        _ = std.meta.stringToEnum(events.Resolution, value) orelse return error.InvalidResolution;
        f.resolution = value;
    }
    if (try parameter(a, query, "domain")) |value| {
        var buffer: [253]u8 = undefined;
        f.name = try a.dupe(u8, try domain.normalize(value, &buffer));
    }
    if (try parameter(a, query, "query_type")) |value| f.qtype = try std.fmt.parseInt(u16, value, 10);
    if (try parameter(a, query, "transport")) |value| {
        if (!eq(value, "udp") and !eq(value, "tcp")) return error.InvalidTransport;
        f.transport = value;
    }
    if (try parameter(a, query, "errors")) |value| {
        if (!eq(value, "true") and !eq(value, "false")) return error.InvalidErrorsFilter;
        f.errors = eq(value, "true");
    }
    if (try parameter(a, query, "limit")) |value| {
        f.limit = try std.fmt.parseInt(u8, value, 10);
        if (f.limit < 1 or f.limit > 100) return error.InvalidLimit;
    }
    if (try parameter(a, query, "interval")) |value| {
        f.interval = if (eq(value, "1m")) 60_000 else if (eq(value, "5m")) 300_000 else if (eq(value, "15m")) 900_000 else if (eq(value, "1h")) 3_600_000 else return error.InvalidInterval;
    } else if (f.to - f.from > 86_400_000) f.interval = 3_600_000;
    if (@divTrunc(f.to - f.from + f.interval - 1, f.interval) > 1000) return error.TooManyBuckets;
    return f;
}

pub fn positive(value: []const u8) !i64 {
    const n = try std.fmt.parseInt(i64, value, 10);
    if (n <= 0) return error.InvalidId;
    return n;
}

fn timestamp(value: []const u8) !i64 {
    if (std.mem.indexOfScalar(u8, value, 'T') == null) return std.fmt.parseInt(i64, value, 10);
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    if (day > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return error.InvalidTimestamp;
    var days: i64 = day - 1;
    for (1970..year) |y| days += std.time.epoch.getDaysInYear(@intCast(y));
    for (1..month) |m| days += std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(m)));
    return ((days * 24 + hour) * 3600 + @as(i64, minute) * 60 + second) * 1000;
}

fn encodeCursor(a: std.mem.Allocator, cursor: Cursor) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(a, cursor, .{});
    const out = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(json.len));
    return std.base64.url_safe_no_pad.Encoder.encode(out, json);
}
fn decodeCursor(a: std.mem.Allocator, value: []const u8) !Cursor {
    if (value.len > 512) return error.InvalidCursor;
    const out = try a.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(value));
    try std.base64.url_safe_no_pad.Decoder.decode(out, value);
    const parsed = try std.json.parseFromSlice(Cursor, a, out, .{});
    if (parsed.value.high < 0 or parsed.value.last <= 0 or parsed.value.time < 0) return error.InvalidCursor;
    return parsed.value;
}

fn parameter(a: std.mem.Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, std.mem.trimStart(u8, query, "?"), '&');
    var result: ?[]const u8 = null;
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidQuery;
        if (!eq(pair[0..split], key)) continue;
        if (result != null) return error.DuplicateParameter;
        const output = try a.alloc(u8, pair.len - split - 1);
        var used: usize = 0;
        var i = split + 1;
        while (i < pair.len) : (i += 1) {
            output[used] = if (pair[i] == '%') blk: {
                if (i + 2 >= pair.len) return error.InvalidEncoding;
                const byte = try std.fmt.parseInt(u8, pair[i + 1 ..][0..2], 16);
                if (byte == 0) return error.InvalidEncoding;
                i += 2;
                break :blk byte;
            } else if (pair[i] == '+') ' ' else pair[i];
            used += 1;
        }
        result = output[0..used];
    }
    return result;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn reply(a: std.mem.Allocator, status: u16, value: anytype) !bridge.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(a, value, .{}) };
}

test "history persists, metrics reconcile, cursors isolate new inserts, and retention keeps names" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history.db", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "history.db", a);
    const path_z = try a.dupeSentinel(u8, path, 0);
    var store = try Store.init(gpa, io, path_z);
    var alive = true;
    defer if (alive) store.deinit();
    const query = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x04home\x04test\x00\x00\x01\x00\x01";
    const now = events.now(io);
    for ([_]events.Resolution{ .blocked, .cached, .forwarded, .local, .rejected }, 0..) |resolution, i| {
        var event = events.Event.begin(io, .{ 192, 0, 2, 1 }, query, .udp);
        event.received_at_ms = now - 1000 - @as(i64, @intCast(i));
        event.resolution = resolution;
        event.finish(io, null, if (resolution == .forwarded) error.Timeout else null);
        store.submit(event);
    }
    try std.testing.expect(store.flush());
    try std.testing.expect(try store.rename(1, "Living room"));
    const summary = try handle(store, a, .{ .method = "GET", .path = "/api/v1/metrics/summary", .query = "", .body = "", .if_match = null });
    try std.testing.expectEqual(@as(u16, 200), summary.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, summary.body, .{});
    const counts_value = parsed.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 5), counts_value.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 1), counts_value.get("errors").?.integer);
    try std.testing.expectEqual(@as(i64, 1), counts_value.get("local").?.integer);
    const first = try handle(store, a, .{ .method = "GET", .path = "/api/v1/requests", .query = "limit=2", .body = "", .if_match = null });
    const page = try std.json.parseFromSlice(std.json.Value, a, first.body, .{});
    try std.testing.expectEqual(@as(usize, 2), page.value.object.get("data").?.array.items.len);
    const cursor = page.value.object.get("next").?.string;
    const changed_filter = try handle(store, a, .{ .method = "GET", .path = "/api/v1/requests", .query = try std.fmt.allocPrint(a, "limit=2&resolution=blocked&after={s}", .{cursor}), .body = "", .if_match = null });
    try std.testing.expectEqual(@as(u16, 400), changed_filter.status);
    var newer = events.Event.begin(io, .{ 192, 0, 2, 2 }, query, .tcp);
    newer.resolution = .cached;
    store.submit(newer);
    _ = store.flush();
    const second = try handle(store, a, .{ .method = "GET", .path = "/api/v1/requests", .query = try std.fmt.allocPrint(a, "limit=2&after={s}", .{cursor}), .body = "", .if_match = null });
    try std.testing.expectEqual(@as(u16, 200), second.status);
    const next_page = try std.json.parseFromSlice(std.json.Value, a, second.body, .{});
    try std.testing.expectEqual(@as(i64, 3), next_page.value.object.get("data").?.array.items[0].object.get("id").?.integer);
    for ([_][]const u8{ "/api/v1/clients", "/api/v1/clients/1", "/api/v1/metrics/clients", "/api/v1/metrics/domains", "/api/v1/metrics/timeseries", "/api/v1/metrics/health" }) |endpoint| {
        const response = try handle(store, a, .{ .method = "GET", .path = endpoint, .query = "", .body = "", .if_match = null });
        try std.testing.expectEqual(@as(u16, 200), response.status);
        _ = try std.json.parseFromSlice(std.json.Value, a, response.body, .{});
    }
    // Move requests outside the retention window, then verify API exclusion
    // before physical cleanup, including a second inactive client.
    try store.writer.exec("UPDATE requests SET received_at_ms=?", .{}, .{now - retention_ms - 1000});
    const expired = try handle(store, a, .{ .method = "GET", .path = "/api/v1/requests", .query = "", .body = "", .if_match = null });
    const expired_page = try std.json.parseFromSlice(std.json.Value, a, expired.body, .{});
    try std.testing.expectEqual(@as(usize, 0), expired_page.value.object.get("data").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 6), try store.cleanup(now));
    store.deinit();
    alive = false;
    store = try Store.init(gpa, io, path_z);
    alive = true;
    try std.testing.expectEqual(@as(i64, 0), (try store.reader.one(i64, "SELECT count(*) FROM requests", .{}, .{})).?);
    const saved_name = (try store.reader.oneAlloc([]const u8, a, "SELECT name FROM clients WHERE id=1", .{}, .{})).?;
    try std.testing.expectEqualStrings("Living room", saved_name);
    try std.testing.expectEqual(@as(i64, 2), (try store.reader.one(i64, "SELECT count(*) FROM clients", .{}, .{})).?);
    // Queue saturation is observable and never changes DNS behavior.
    for (0..@import("store.zig").queue_capacity + 1) |_| store.submit(newer);
    try std.testing.expectEqual(@as(u64, 1), store.dropped.load(.monotonic));
}

test "metrics reject invalid dates, limits, bucket counts, duplicate filters and changed cursor filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = try timestamp("2026-11-13T12:00:00Z");
    try std.testing.expectError(error.InvalidTimestamp, timestamp("2026-02-30T00:00:00Z"));
    try std.testing.expectError(error.InvalidLimit, filter(a, "limit=101", now));
    try std.testing.expectError(error.DuplicateParameter, filter(a, "limit=1&limit=2", now));
    try std.testing.expectError(error.InvalidTimeRange, filter(a, "from=0", now));
    try std.testing.expectError(error.TooManyBuckets, filter(a, "interval=1m", now));
    try std.testing.expectError(error.InvalidResolution, filter(a, "resolution=unknown", now));
    const cursor = try encodeCursor(a, .{ .from = now - retention_ms, .to = now, .high = 5, .last = 1, .time = now, .fingerprint = 0 });
    const next = try filter(a, try std.fmt.allocPrint(a, "after={s}", .{cursor}), now + 10_000);
    try std.testing.expectEqual(now - retention_ms, next.from);
    try std.testing.expectError(error.ExpiredCursor, filter(a, try std.fmt.allocPrint(a, "after={s}", .{cursor}), now + retention_ms));
}
