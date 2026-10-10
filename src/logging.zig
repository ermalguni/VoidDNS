const std = @import("std");

var current_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));

/// Main changes the threshold between DNS workers; control may still log.
pub fn setLevel(level: std.log.Level) void {
    current_level.store(@intFromEnum(level), .monotonic);
}

pub fn enabled(comptime level: std.log.Level) bool {
    return @intFromEnum(level) <= current_level.load(.monotonic);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    std.log.defaultLog(level, scope, format, args);
}

test "runtime log level includes only the selected severity and higher" {
    const previous_level: std.log.Level = @enumFromInt(current_level.load(.monotonic));
    defer setLevel(previous_level);

    const cases = .{
        .{ std.log.Level.err, .{ true, false, false, false } },
        .{ std.log.Level.warn, .{ true, true, false, false } },
        .{ std.log.Level.info, .{ true, true, true, false } },
        .{ std.log.Level.debug, .{ true, true, true, true } },
    };
    inline for (cases) |case| {
        setLevel(case[0]);
        inline for (.{ .err, .warn, .info, .debug }, case[1]) |level, expected| {
            try std.testing.expectEqual(expected, enabled(level));
        }
    }
}
