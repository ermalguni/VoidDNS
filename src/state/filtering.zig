const std = @import("std");
const State = @import("state.zig").State;
const Definitions = @import("../config/definitions.zig").Definitions;

/// Builds independently owned RAM state; the optional snapshot store is borrowed.
/// Relative sources are anchored to the configuration file's directory.
pub fn build(allocator: std.mem.Allocator, io: std.Io, definitions: *const Definitions, base_dir: []const u8, store: ?*@import("../lists/store.zig").Store) !State {
    var state = State.init(allocator);
    errdefer state.deinit();
    state.lists.store = store;
    for (definitions.blocks.items) |domain| try state.domains.block(domain);
    for (definitions.sources.items) |source| {
        try source.validate();
        try state.lists.add(io, source, base_dir);
    }
    for (definitions.allows.items) |domain| try state.domains.allow(domain);
    return state;
}
