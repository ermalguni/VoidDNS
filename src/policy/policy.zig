const State = @import("../state/state.zig").State;

pub const Decision = enum { block, local, forward };

// Explicit blocks always win. Allows bypass imported lists, not local answers.
// A local answer takes precedence over imported lists even without an allow.
pub fn decide(state: *const State, canonical: []const u8, has_local: bool) Decision {
    if (state.domains.isBlocked(canonical)) return .block;
    if (state.domains.isAllowed(canonical)) return if (has_local) .local else .forward;
    if (has_local) return .local;
    if (state.lists.contains(canonical)) return .block;
    return .forward;
}
