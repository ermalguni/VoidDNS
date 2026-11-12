const std = @import("std");
const State = @import("state.zig").State;
const Definitions = @import("../config/definitions.zig").Definitions;

/// Builds independent RAM state from validated, owned configuration definitions.
/// Failed startup imports become disabled entries; definitions remain unchanged.
/// Relative sources are anchored to the configuration file's directory.
pub fn build(allocator: std.mem.Allocator, io: std.Io, definitions: *const Definitions, base_dir: []const u8) !State {
    var state = State.init(allocator);
    errdefer state.deinit();
    for (definitions.blocks.items) |domain| try state.domains.block(domain);
    for (definitions.sources.items) |source| {
        try source.validate();
        state.lists.add(io, source, base_dir) catch |err| {
            switch (err) {
                error.OutOfMemory, error.Canceled, error.ConcurrencyUnavailable, error.DuplicateSourceId => return err,
                else => {},
            }
            // Metadata is validated before logging; locations may contain secrets.
            std.log.warn("blocklist id={s} name={s}: {s}; disabling source at startup", .{
                source.id, source.name orelse "(unnamed)", @errorName(err),
            });
            var disabled = source;
            disabled.enabled = false;
            try state.lists.add(io, disabled, base_dir);
        };
    }
    for (definitions.allows.items) |domain| try state.domains.allow(domain);
    return state;
}
