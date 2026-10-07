const std = @import("std");
const Name = @import("name.zig");

pub const port: u16 = 53;
pub const packet_capacity: usize = std.math.maxInt(u16);

pub const RecordType = enum(u16) {
    a = 1,
    aaaa = 28,
    _,
};

pub const Class = enum(u16) {
    internet = 1,
    _,
};

pub const Header = struct {
    pub const len = 12;
    pub const id_offset = 0;
    pub const flags_offset = 2;
    pub const question_count_offset = 4;
};

pub const Flags = struct {
    pub const response: u16 = 0x8000;
    pub const opcode_mask: u16 = 0x7800;
    pub const recursion_desired: u16 = 0x0100;
    pub const recursion_available: u16 = 0x0080;
    pub const checking_disabled: u16 = 0x0010;
};

pub const Question = struct {
    id: u16,
    flags: u16,
    name: Name,
    qtype: RecordType,
    qclass: Class,
};
