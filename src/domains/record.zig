const Record = @This();
const RecordType = @import("../dns/message.zig").RecordType;

pub const ipv4_address_len = 4;
pub const ipv6_address_len = 16;
pub const default_ttl_seconds: u32 = 60;

name: []const u8,
ttl_seconds: u32 = default_ttl_seconds,
addresses: union(enum) {
    a: []const [ipv4_address_len]u8,
    aaaa: []const [ipv6_address_len]u8,
},

pub fn recordType(self: *const Record) RecordType {
    return switch (self.addresses) {
        .a => .a,
        .aaaa => .aaaa,
    };
}
