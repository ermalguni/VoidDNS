const std = @import("std");
const Name = @This();

pub const max_wire_len = 255;
pub const compression_pointer_tag: u16 = 0xc000;

const compression_offset_mask: u16 = 0x3fff;
const label_tag_mask: u8 = 0xc0;
const pointer_label_tag: u8 = 0xc0;
const pointer_len = @sizeOf(u16);
const label_prefix_len = @sizeOf(u8);
const root_label = 0;

wire: [max_wire_len]u8,
len: usize,

pub fn read(packet: []const u8, offset: *usize) !Name {
    var name: Name = undefined;
    name.len = 0;

    var cursor = offset.*;
    var jumped = false;
    var steps: usize = 0;

    while (steps < packet.len) : (steps += 1) {
        if (cursor >= packet.len) return error.InvalidName;
        const size = packet[cursor];

        if (size & label_tag_mask == pointer_label_tag) {
            if (packet.len - cursor < pointer_len)
                return error.InvalidName;

            if (!jumped) offset.* = cursor + pointer_len;

            const pointer = std.mem.readInt(
                u16,
                packet[cursor..][0..pointer_len],
                .big,
            );
            cursor = pointer & compression_offset_mask;
            jumped = true;
            continue;
        }

        if (size & label_tag_mask != 0) return error.InvalidName;

        const label_len = label_prefix_len + @as(usize, size);
        const end = cursor + label_len;

        if (end > packet.len or name.len + label_len > name.wire.len)
            return error.InvalidName;

        @memcpy(name.wire[name.len..][0..label_len], packet[cursor..end]);
        name.len += label_len;
        cursor = end;

        if (!jumped) offset.* = cursor;
        if (size == root_label) return name;
    }

    return error.InvalidName;
}

// Configured names are ASCII, dot-separated, without a trailing dot.
pub fn matches(self: *const Name, text: []const u8) bool {
    var labels = std.mem.splitScalar(u8, text, '.');
    var offset: usize = 0;

    while (self.wire[offset] != root_label) {
        const size = self.wire[offset];
        const label = labels.next() orelse return false;
        const start = offset + label_prefix_len;

        if (!std.ascii.eqlIgnoreCase(self.wire[start..][0..size], label))
            return false;

        offset = start + size;
    }

    return labels.next() == null;
}
