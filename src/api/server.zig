const std = @import("std");
const httpz = @import("httpz");
const config = @import("../config/config.zig");
const Auth = @import("auth.zig").Auth;
const Bridge = @import("bridge.zig").Bridge;

const max_config_body = 1024 * 1024;
const max_resource_body = 64 * 1024;
const max_headers = 64;
const HttpServer = httpz.Server(Handler);

/// The caller must keep this value at a stable address after start(), close the
/// management mailbox before deinit(), and keep the Bridge alive through deinit().
pub const Server = struct {
    http: HttpServer,
    thread: ?std.Thread = null,
    listen_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, settings: config.Api, bridge: *Bridge) !Server {
        const address = try std.Io.net.IpAddress.parseIp4(settings.listen_address, settings.port);
        if (settings.port == 0) return error.InvalidApiPort;
        var auth = try Auth.load(allocator, io, settings.key_file orelse return error.MissingApiKeyFile);
        errdefer auth.deinit();
        return .{
            .http = try HttpServer.init(io, allocator, .{
                .address = .{ .ip = address },
                .workers = .{ .count = 1, .max_conn = 128, .min_conn = 8 },
                .thread_pool = .{ .count = 4, .backlog = 64 },
                .request = .{
                    .buffer_size = 16 * 1024,
                    .max_header_count = max_headers,
                    .max_body_size = max_config_body,
                    // Authenticate and reject oversized Content-Length before
                    // receiving the body. Chunked decoding is bounded by httpz.
                    .lazy_read_size = 0,
                },
                .timeout = .{ .request = 15, .keepalive = 5, .request_count = 100 },
            }, .{ .auth = auth, .bridge = bridge }),
        };
    }

    pub fn start(self: *Server) !void {
        if (self.thread != null) return error.ApiAlreadyStarted;
        const io = self.http.io;
        // Use httpz's startup condition, but catch listen errors in our own
        // thread entry point instead of letting an error terminate that thread.
        self.http._mut.lockUncancelable(io);
        self.listen_error = null;
        self.thread = std.Thread.spawn(.{}, listen, .{self}) catch |err| {
            self.http._mut.unlock(io);
            return err;
        };
        while (self.http._listener == null and self.listen_error == null) {
            self.http._cond.waitUncancelable(io, &self.http._mut);
        }
        const startup_error = self.listen_error;
        self.http._mut.unlock(io);
        if (startup_error) |err| {
            self.thread.?.join();
            self.thread = null;
            return err;
        }
    }

    pub fn deinit(self: *Server) void {
        if (self.thread) |thread| {
            self.http.stop();
            thread.join();
            self.thread = null;
        }
        self.http.handler.auth.deinit();
        self.http.deinit();
    }

    fn listen(self: *Server) void {
        self.http.listen() catch |err| {
            const io = self.http.io;
            self.http._mut.lockUncancelable(io);
            defer self.http._mut.unlock(io);
            self.listen_error = err;
            self.http._cond.signal(io);
        };
    }
};

const Handler = struct {
    auth: Auth,
    bridge: *Bridge,

    // Taking over dispatch means every method and unknown /api/v1 route goes
    // through authentication, rather than bypassing it through router misses.
    pub fn handle(self: Handler, req: *httpz.Request, res: *httpz.Response) void {
        res.content_type = .JSON;
        res.header("Cache-Control", "no-store");
        res.header("X-Content-Type-Options", "nosniff");
        self.serve(req, res) catch {
            jsonError(res, 500, "internal_error");
            req.conn.handover = .close;
        };
        // Never let httpz drain an unread rejected body on a keepalive socket.
        if (req.unread_body != 0) req.conn.handover = .close;
    }

    fn serve(self: Handler, req: *httpz.Request, res: *httpz.Response) !void {
        if (!isApiPath(req.url.path)) return jsonError(res, 404, "not_found");
        // httpz stops storing headers when its fixed table fills. Reject at
        // capacity so a later duplicate API key cannot be silently discarded.
        if (req.headers.len >= max_headers) return jsonError(res, 431, "too_many_headers");
        const key = uniqueHeader(req.headers, "x-api-key") catch return jsonError(res, 401, "unauthorized");
        if (key == null or !self.auth.verify(key.?)) return jsonError(res, 401, "unauthorized");
        const if_match = uniqueHeader(req.headers, "if-match") catch return jsonError(res, 400, "duplicate_if_match");
        if (req.body_len > bodyLimit(req.url.path)) return jsonError(res, 413, "body_too_large");

        if (std.mem.eql(u8, req.url.path, "/api/v1/openapi.json")) {
            if (req.method != .GET) {
                res.header("Allow", "GET");
                return jsonError(res, 405, "method_not_allowed");
            }
            res.body = @embedFile("openapi.json");
            return;
        }

        const body: []const u8 = if (req.unread_body == 0) req.body() orelse "" else blk: {
            const bytes = try req.arena.alloc(u8, req.body_len);
            var reader = req.reader(5_000) catch return jsonError(res, 400, "invalid_body");
            const started = std.Io.Clock.awake.now(req.conn.io);
            var used: usize = 0;
            while (used < bytes.len) {
                if (started.durationTo(std.Io.Clock.awake.now(req.conn.io)).toMilliseconds() >= 15_000)
                    return jsonError(res, 408, "request_timeout");
                const count = reader.read(bytes[used..]) catch return jsonError(res, 400, "invalid_body");
                // httpz's lazy reader returns zero on a truncated socket, not
                // EndOfStream; handle that explicitly instead of spinning.
                if (count == 0) return jsonError(res, 400, "invalid_body");
                used += count;
            }
            break :blk bytes;
        };
        // Response memory must outlive the handler thread's temporary buffer;
        // allocate directly in the connection arena, not req.arena's fallback.
        const arena = req.conn.req_arena.allocator();
        const response = try self.bridge.handle(arena, .{
            .method = if (req.method == .OTHER) req.method_string else @tagName(req.method),
            .path = req.url.path,
            .query = req.url.query,
            .body = body,
            .if_match = if_match,
        });
        res.status = response.status;
        res.body = response.body;
        if (response.revision) |revision| {
            res.header("ETag", try std.fmt.allocPrint(arena, "\"{d}\"", .{revision}));
        }
    }
};

fn uniqueHeader(headers: *const httpz.key_value.StringKeyValue, name: []const u8) !?[]const u8 {
    var values = headers.getAll(name);
    const value = values.next();
    if (values.next() != null) return error.DuplicateHeader;
    return value;
}

fn isApiPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/api/v1") or std.mem.startsWith(u8, path, "/api/v1/");
}

fn bodyLimit(path: []const u8) usize {
    return if (std.mem.eql(u8, path, "/api/v1/config") or
        std.mem.eql(u8, path, "/api/v1/config/validate")) max_config_body else max_resource_body;
}

fn jsonError(res: *httpz.Response, status: u16, comptime code: []const u8) void {
    res.status = status;
    res.body = "{\"error\":{\"code\":\"" ++ code ++ "\",\"message\":\"" ++ code ++ "\"}}";
}

test "API headers reject duplicate keys instead of selecting one" {
    var headers = try httpz.key_value.StringKeyValue.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), try uniqueHeader(&headers, "x-api-key"));
    headers.add("x-api-key", "first");
    try std.testing.expectEqualStrings("first", (try uniqueHeader(&headers, "x-api-key")).?);
    headers.add("x-api-key", "second");
    try std.testing.expectError(error.DuplicateHeader, uniqueHeader(&headers, "x-api-key"));
    headers.add("if-match", "\"1\"");
    headers.add("if-match", "\"2\"");
    try std.testing.expectError(error.DuplicateHeader, uniqueHeader(&headers, "if-match"));
}

test "API namespace boundaries and configuration body limits" {
    try std.testing.expect(isApiPath("/api/v1"));
    try std.testing.expect(isApiPath("/api/v1/unknown"));
    try std.testing.expect(!isApiPath("/api/v10/status"));
    try std.testing.expect(!isApiPath("/api/v1evil"));
    try std.testing.expectEqual(max_config_body, bodyLimit("/api/v1/config"));
    try std.testing.expectEqual(max_config_body, bodyLimit("/api/v1/config/validate"));
    try std.testing.expectEqual(max_resource_body, bodyLimit("/api/v1/records"));
}
