const std = @import("std");
const httpz = @import("httpz");
const embedded = @import("ui_assets");

pub const Result = enum { served, not_found, method_not_allowed };

/// Only the declared client routes fall back to the SPA. Missing asset names,
/// unknown routes, encodings and traversal attempts never return index.html.
fn isFrontendRoute(path: []const u8) bool {
    const routes = std.StaticStringMap(void).initComptime(.{
        .{ "/", {} },
        .{ "/domains", {} },
        .{ "/records", {} },
        .{ "/blocklists", {} },
        .{ "/policy", {} },
        .{ "/settings", {} },
        .{ "/configuration", {} },
        .{ "/clients", {} },
        .{ "/requests", {} },
    });
    return routes.has(path);
}

fn find(path: []const u8) ?*const embedded.Asset {
    var low: usize = 0;
    var high: usize = embedded.assets.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const asset = &embedded.assets[middle];
        switch (std.mem.order(u8, path, asset.path)) {
            .eq => return asset,
            .lt => high = middle,
            .gt => low = middle + 1,
        }
    }
    return null;
}

/// Direct immutable slices: no filesystem access, bridge calls, state locks,
/// response-sized allocations or copies on the static request path.
pub fn serve(enabled: bool, req: *httpz.Request, res: *httpz.Response) Result {
    if (!enabled) return .not_found;
    if (req.method != .GET and req.method != .HEAD) return .method_not_allowed;
    const path = if (isFrontendRoute(req.url.path)) "/index.html" else req.url.path;
    const asset = find(path) orelse return .not_found;
    res.content_type = null;
    res.header("Content-Type", asset.mime);
    res.header("Cache-Control", asset.cache_control);
    if (req.method == .HEAD) {
        // httpz only honors a supplied Content-Length when body.len == 0.
        // Supplying both a nonempty body and this header would duplicate it.
        res.header("Content-Length", asset.content_length);
        res.body = "";
    } else {
        res.body = asset.body;
    }
    return .served;
}

test "only declared SPA routes resolve to the production index" {
    for ([_][]const u8{ "/", "/domains", "/records", "/blocklists", "/policy", "/settings", "/configuration", "/clients", "/requests" }) |path| {
        var request = httpz.testing.init(.{});
        defer request.deinit();
        request.url(path);
        try std.testing.expectEqual(Result.served, serve(true, request.req, request.res));
        try std.testing.expectEqualStrings(find("/index.html").?.body, request.res.body);
        try request.expectHeader("Content-Type", "text/html; charset=utf-8");
        try request.expectHeader("Cache-Control", "no-cache");
    }
    for ([_][]const u8{ "/unknown", "/domains/nested", "/assets/missing.js", "/favicon-missing.ico", "/../index.html", "/%69ndex.html" }) |path| {
        var request = httpz.testing.init(.{});
        defer request.deinit();
        request.url(path);
        try std.testing.expectEqual(Result.not_found, serve(true, request.req, request.res));
    }
}

test "HEAD reports actual GET byte length without a body and scripts have safe caching" {
    for (&embedded.assets) |*asset| {
        var get = httpz.testing.init(.{});
        defer get.deinit();
        get.url(asset.path);
        try std.testing.expectEqual(Result.served, serve(true, get.req, get.res));
        const get_body = try get.getBody();
        const length = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{get_body.len});
        defer std.testing.allocator.free(length);
        if (std.mem.startsWith(u8, asset.path, "/assets/")) {
            if (std.mem.endsWith(u8, asset.path, ".js")) {
                try get.expectHeader("Content-Type", "text/javascript; charset=utf-8");
                try get.expectHeader("Cache-Control", "public, max-age=31536000, immutable");
            } else if (std.mem.endsWith(u8, asset.path, ".css")) {
                try get.expectHeader("Content-Type", "text/css; charset=utf-8");
                try get.expectHeader("Cache-Control", "public, max-age=31536000, immutable");
            }
        }

        var head = httpz.testing.init(.{});
        defer head.deinit();
        head.url(asset.path);
        head.req.method = .HEAD;
        try std.testing.expectEqual(Result.served, serve(true, head.req, head.res));
        try head.expectBody("");
        try head.expectHeader("Content-Length", length);
    }
}

test "disabled UI never serves files and enabled UI rejects other methods" {
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.url("/");
    try std.testing.expectEqual(Result.not_found, serve(false, request.req, request.res));
    request.req.method = .POST;
    try std.testing.expectEqual(Result.not_found, serve(false, request.req, request.res));
    try std.testing.expectEqual(Result.method_not_allowed, serve(true, request.req, request.res));
}
