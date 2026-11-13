const std = @import("std");
const decode = @import("../dns/decode.zig");
const domain = @import("../domains/domain.zig");

pub const Resolution = enum { blocked, cached, forwarded, local, rejected };

/// Entirely owned, fixed-size queue payload. No packet/state pointers escape.
pub const Event = struct {
    ip: [4]u8,
    received_at_ms: i64,
    started: std.Io.Timestamp,
    name: [253]u8 = undefined,
    name_len: u8 = 0,
    query_type: ?u16 = null,
    query_class: ?u16 = null,
    transport: enum { udp, tcp },
    resolution: Resolution = .rejected,
    rcode: ?u16 = null,
    duration_us: i64 = 0,
    failure: ?[]const u8 = null, // Static @errorName only.

    pub fn begin(io: std.Io, ip: [4]u8, packet: []const u8, transport: @FieldType(Event, "transport")) Event {
        var event: Event = .{ .ip = ip, .received_at_ms = now(io), .started = std.Io.Clock.awake.now(io), .transport = transport };
        if (decode.question(packet)) |question| {
            event.query_type = @backingInt(question.qtype);
            event.query_class = @backingInt(question.qclass);
            if (domain.fromWire(&question.name, &event.name)) |name| event.name_len = @intCast(name.len);
        } else |_| {}
        return event;
    }

    pub fn finish(self: *Event, io: std.Io, response: ?[]const u8, failure: ?anyerror) void {
        self.duration_us = @max(0, self.started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds());
        if (response) |packet| if (packet.len >= 12) {
            self.rcode = decode.flags(packet) & 15;
        };
        self.failure = if (failure) |err| @errorName(err) else null;
    }
};

pub fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}
