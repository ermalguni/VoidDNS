const Record = @This();
const RecordType = @import("../dns/message.zig").RecordType;

pub const ipv4_address_len = 4;
pub const ipv6_address_len = 16;
pub const default_ttl_seconds: u32 = 60;

name: []const u8,
ttl_seconds: u32 = default_ttl_seconds,
a: ?[ipv4_address_len]u8 = null,
aaaa: ?[ipv6_address_len]u8 = null,

pub fn data(self: *const Record, qtype: RecordType) ?[]const u8 {
    return switch (qtype) {
        .a => if (self.a) |*value| value else null,
        .aaaa => if (self.aaaa) |*value| value else null,
        else => null,
    };
}
