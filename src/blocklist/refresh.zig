const std = @import("std");

pub const Policy = struct {
    enabled: bool = true,
    interval_seconds: u32 = 86400,
    jitter_percent: u8 = 10,
    retry_initial_seconds: u32 = 300,
    retry_max_seconds: u32 = 21600,

    pub fn validate(self: Policy) !void {
        if (self.interval_seconds == 0 or self.retry_initial_seconds == 0 or
            self.retry_max_seconds == 0 or self.jitter_percent > 100 or
            self.retry_max_seconds < self.retry_initial_seconds)
            return error.InvalidRefreshPolicy;
    }
};

/// Requires a validated policy. The first failure uses the initial retry delay;
/// subsequent failures double it, capped by both the retry maximum and interval.
/// Jitter is sampled in whole seconds and never lets a retry exceed that cap.
pub fn delaySeconds(policy: Policy, failures: u32, random: u64) u64 {
    const cap: u64 = @min(policy.retry_max_seconds, policy.interval_seconds);
    const base: u64 = if (failures == 0)
        policy.interval_seconds
    else
        @min(cap, @as(u64, policy.retry_initial_seconds) << @as(u6, @intCast(@min(failures - 1, 32))));
    const spread = base * policy.jitter_percent / 100;
    const lower = @max(1, base - spread);
    const upper = if (failures == 0) base + spread else @min(cap, base + spread);
    return lower + random % (upper - lower + 1);
}

test "refresh policies reject nonpositive durations and invalid bounds even when disabled" {
    const invalid = [_]Policy{
        .{ .interval_seconds = 0 },
        .{ .retry_initial_seconds = 0 },
        .{ .retry_max_seconds = 0 },
        .{ .jitter_percent = 101 },
        .{ .retry_initial_seconds = 301, .retry_max_seconds = 300 },
        .{ .enabled = false, .interval_seconds = 0 },
    };
    for (invalid) |policy| try std.testing.expectError(error.InvalidRefreshPolicy, policy.validate());
    try (Policy{ .interval_seconds = 1, .retry_initial_seconds = 1, .retry_max_seconds = 1, .jitter_percent = 100 }).validate();
}

test "normal refresh jitter spans both sides and never produces zero" {
    const policy: Policy = .{ .interval_seconds = 100, .jitter_percent = 10 };
    try std.testing.expectEqual(@as(u64, 90), delaySeconds(policy, 0, 0));
    try std.testing.expectEqual(@as(u64, 100), delaySeconds(policy, 0, 10));
    try std.testing.expectEqual(@as(u64, 110), delaySeconds(policy, 0, 20));
    try std.testing.expectEqual(@as(u64, 90), delaySeconds(policy, 0, 21));
    try std.testing.expectEqual(@as(u64, 1), delaySeconds(.{ .interval_seconds = 1, .jitter_percent = 100 }, 0, 0));
    try std.testing.expectEqual(@as(u64, 2), delaySeconds(.{ .interval_seconds = 1, .jitter_percent = 100 }, 0, 1));
    try std.testing.expectEqual(@as(u64, 8589934590), delaySeconds(.{ .interval_seconds = std.math.maxInt(u32), .jitter_percent = 100 }, 0, 8589934589));
}

test "retry backoff saturates for arbitrary failure counts and caps jitter by interval and retry maximum" {
    const policy: Policy = .{ .interval_seconds = 100, .jitter_percent = 0, .retry_initial_seconds = 3, .retry_max_seconds = 20 };
    for ([_]u64{ 3, 6, 12, 20, 20 }, 1..) |expected, failures| {
        try std.testing.expectEqual(expected, delaySeconds(policy, @intCast(failures), 0));
    }
    try std.testing.expectEqual(@as(u64, 20), delaySeconds(policy, std.math.maxInt(u32), std.math.maxInt(u64)));
    const jittered: Policy = .{ .interval_seconds = 10, .jitter_percent = 100, .retry_initial_seconds = 8, .retry_max_seconds = 100 };
    try std.testing.expectEqual(@as(u64, 1), delaySeconds(jittered, 1, 0));
    try std.testing.expectEqual(@as(u64, 10), delaySeconds(jittered, 1, 9));
    try std.testing.expectEqual(@as(u64, 10), delaySeconds(jittered, std.math.maxInt(u32), 9));
    try std.testing.expectEqual(@as(u64, 1), delaySeconds(.{ .interval_seconds = 1, .jitter_percent = 100 }, std.math.maxInt(u32), std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), delaySeconds(.{
        .interval_seconds = std.math.maxInt(u32),
        .jitter_percent = 0,
        .retry_initial_seconds = std.math.maxInt(u32),
        .retry_max_seconds = std.math.maxInt(u32),
    }, std.math.maxInt(u32), 0));
}
