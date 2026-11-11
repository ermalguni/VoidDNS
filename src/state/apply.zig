const std = @import("std");
const Config = @import("../config/config.zig").Config;
const Record = @import("../domains/record.zig");
const Service = @import("../blocklist/service.zig").Service;
const State = @import("state.zig").State;

/// Main is the sole writer. Preparation only reads stable metadata; DNS readers
/// may concurrently use the published state. reserve/commit require its mutex.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    sources: Service.Plan,
    blocks: Rules,
    allows: Rules,
    records_changed: bool,
    reuse_records: std.ArrayList(RecordPair),

    pub fn prepare(allocator: std.mem.Allocator, io: std.Io, state: *const State, previous: *const Config, candidate: *const Config) !Plan {
        var sources = try state.lists.prepare(io, candidate.definitions.sources.items, candidate.base_dir, .none);
        errdefer sources.deinit();
        var blocks = try Rules.prepare(allocator, &state.domains.blocks, candidate.definitions.blocks.items);
        errdefer blocks.deinit();
        var allows = try Rules.prepare(allocator, &state.domains.allows, candidate.definitions.allows.items);
        errdefer allows.deinit();
        var reuse: std.ArrayList(RecordPair) = .empty;
        errdefer reuse.deinit(allocator);
        const Families = struct { a: ?usize = null, aaaa: ?usize = null };
        var old_records: std.StringHashMapUnmanaged(Families) = .empty;
        defer old_records.deinit(allocator);
        for (previous.records, 0..) |record, index| {
            const entry = try old_records.getOrPut(allocator, record.name);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            switch (record.addresses) {
                .a => entry.value_ptr.a = index,
                .aaaa => entry.value_ptr.aaaa = index,
            }
        }
        var records_changed = previous.records.len != candidate.records.len;
        for (candidate.records, 0..) |record, index| {
            const old_index = if (old_records.get(record.name)) |families| switch (record.addresses) {
                .a => families.a,
                .aaaa => families.aaaa,
            } else null;
            if (old_index) |old| {
                if (sameRecord(previous.records[old], record)) {
                    try reuse.append(allocator, .{ .previous = old, .candidate = index });
                    continue;
                }
            }
            records_changed = true;
        }
        return .{
            .allocator = allocator,
            .sources = sources,
            .blocks = blocks,
            .allows = allows,
            .records_changed = records_changed,
            .reuse_records = reuse,
        };
    }

    pub fn deinit(self: *Plan) void {
        self.sources.deinit();
        self.blocks.deinit();
        self.allows.deinit();
        self.reuse_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn changed(self: *const Plan) bool {
        return self.sources.changed() or self.blocks.changed() or self.allows.changed() or self.records_changed;
    }

    /// Capacity changes are invisible to readers and do not alter membership.
    /// A failure at any reservation leaves the entire logical state unchanged.
    pub fn reserve(self: *Plan, state: *State) !void {
        try self.sources.reserve(&state.lists);
        try self.blocks.reserve(&state.domains.blocks);
        try self.allows.reserve(&state.domains.allows);
    }

    /// No allocation or failure after reserve. Both configs own mutable backing
    /// arrays; exchange equal records to retain the published names/RRset bytes.
    /// Destroying previous afterward frees only replaced or candidate duplicates.
    pub fn commit(self: *Plan, state: *State, previous: *Config, candidate: *Config) void {
        self.sources.commit(&state.lists);
        self.blocks.commit(&state.domains.blocks);
        self.allows.commit(&state.domains.allows);
        for (self.reuse_records.items) |pair| {
            std.mem.swap(Record, &@constCast(previous.records)[pair.previous], &@constCast(candidate.records)[pair.candidate]);
        }
        state.records = candidate.records;
    }
};

const RecordPair = struct { previous: usize, candidate: usize };

fn sameRecord(a: Record, b: Record) bool {
    if (a.ttl_seconds != b.ttl_seconds or a.recordType() != b.recordType()) return false;
    return switch (a.addresses) {
        .a => |addresses| std.mem.eql(u8, std.mem.sliceAsBytes(addresses), std.mem.sliceAsBytes(b.addresses.a)),
        .aaaa => |addresses| std.mem.eql(u8, std.mem.sliceAsBytes(addresses), std.mem.sliceAsBytes(b.addresses.aaaa)),
    };
}

const Rules = struct {
    allocator: std.mem.Allocator,
    additions: std.ArrayList([]const u8) = .empty,
    removals: std.ArrayList([]const u8) = .empty,

    fn prepare(allocator: std.mem.Allocator, current: *const std.StringHashMapUnmanaged(void), values: []const []const u8) !Rules {
        var result: Rules = .{ .allocator = allocator };
        errdefer result.deinit();
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        defer wanted.deinit(allocator);
        for (values) |name| {
            const entry = try wanted.getOrPut(allocator, name);
            if (entry.found_existing or current.contains(name)) continue;
            const owned = try allocator.dupe(u8, name);
            errdefer allocator.free(owned);
            try result.additions.append(allocator, owned);
        }
        var keys = current.keyIterator();
        while (keys.next()) |key| {
            if (!wanted.contains(key.*)) try result.removals.append(allocator, key.*);
        }
        return result;
    }

    fn deinit(self: *Rules) void {
        for (self.additions.items) |name| self.allocator.free(name);
        self.additions.deinit(self.allocator);
        self.removals.deinit(self.allocator);
    }

    fn changed(self: *const Rules) bool {
        return self.additions.items.len != 0 or self.removals.items.len != 0;
    }

    fn reserve(self: *Rules, target: *std.StringHashMapUnmanaged(void)) !void {
        try target.ensureUnusedCapacity(self.allocator, @intCast(self.additions.items.len));
    }

    fn commit(self: *Rules, target: *std.StringHashMapUnmanaged(void)) void {
        for (self.removals.items) |name| {
            std.debug.assert(target.remove(name));
            self.allocator.free(name);
        }
        for (self.additions.items) |name| target.putAssumeCapacityNoClobber(name, {});
        self.additions.clearRetainingCapacity();
        self.removals.clearRetainingCapacity();
    }
};

test "record and rule diff preserves unchanged ownership and applies deletions" {
    const config = @import("../config/config.zig");
    const allocator = std.testing.allocator;
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"keep.test","type":"A","addresses":["192.0.2.1"]},{"name":"gone.test","type":"AAAA","addresses":["::1"]}],"blocks":{"domains":["keep.test","gone.test"]},"allows":{"domains":["allow.test"]}}
    , ".", &diagnostic);
    defer previous.deinit();
    var candidate = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"new.test","type":"A","addresses":["192.0.2.2"]},{"name":"KEEP.TEST.","type":"A","addresses":["192.0.2.1"]}],"blocks":{"domains":["KEEP.TEST.","new.test"]},"allows":{"domains":[]}}
    , ".", &diagnostic);
    defer candidate.deinit();
    var state = try previous.prepareState(std.testing.io, &diagnostic);
    defer state.deinit();
    state.records = previous.records;
    const name = previous.records[0].name.ptr;
    const addresses = previous.records[0].addresses.a.ptr;
    const rule = state.domains.blocks.getKey("keep.test").?.ptr;
    var plan = try Plan.prepare(allocator, std.testing.io, &state, &previous, &candidate);
    defer plan.deinit();
    try std.testing.expect(plan.changed());
    try plan.reserve(&state);
    plan.commit(&state, &previous, &candidate);
    try std.testing.expectEqual(name, state.records[1].name.ptr);
    try std.testing.expectEqual(addresses, state.records[1].addresses.a.ptr);
    try std.testing.expectEqual(rule, state.domains.blocks.getKey("keep.test").?.ptr);
    try std.testing.expect(state.domains.isBlocked("new.test"));
    try std.testing.expect(!state.domains.isBlocked("gone.test"));
    try std.testing.expect(!state.domains.isAllowed("allow.test"));
    try std.testing.expectEqualStrings("new.test", state.records[0].name);
}

test "normalized record reordering and duplicate explicit rules are a no-op" {
    const config = @import("../config/config.zig");
    const allocator = std.testing.allocator;
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"one.test","type":"A","addresses":["192.0.2.1"]},{"name":"two.test","type":"AAAA","addresses":["::1"]}],"blocks":{"domains":["one.test"]}}
    , ".", &diagnostic);
    defer previous.deinit();
    var candidate = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"TWO.TEST.","type":"AAAA","addresses":["::1"]},{"name":"one.test","type":"A","addresses":["192.0.2.1"]}],"blocks":{"domains":["ONE.TEST.","one.test"]}}
    , ".", &diagnostic);
    defer candidate.deinit();
    var state = try previous.prepareState(std.testing.io, &diagnostic);
    defer state.deinit();
    var plan = try Plan.prepare(allocator, std.testing.io, &state, &previous, &candidate);
    defer plan.deinit();
    try std.testing.expect(!plan.changed());
}

test "allocation failure during managed diff preparation or reservation preserves active state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const config = @import("../config/config.zig");
    var diagnostic: config.Diagnostic = .{};
    var previous = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"old.test","type":"A","addresses":["192.0.2.1"]}],"blocks":{"domains":["old.test"]}}
    , ".", &diagnostic);
    defer previous.deinit();
    var candidate = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"new.test","type":"A","addresses":["192.0.2.2"]}],"blocks":{"domains":["new.test"]},"allows":{"domains":["allow.test"]}}
    , ".", &diagnostic);
    defer candidate.deinit();
    var state = try previous.prepareState(std.testing.io, &diagnostic);
    defer state.deinit();
    state.records = previous.records;
    errdefer {
        std.debug.assert(state.domains.isBlocked("old.test"));
        std.debug.assert(!state.domains.isBlocked("new.test"));
        std.debug.assert(!state.domains.isAllowed("allow.test"));
        std.debug.assert(state.records.ptr == previous.records.ptr);
    }
    var plan = try Plan.prepare(allocator, std.testing.io, &state, &previous, &candidate);
    defer plan.deinit();
    try plan.reserve(&state);
    plan.commit(&state, &previous, &candidate);
    try std.testing.expect(!state.domains.isBlocked("old.test"));
    try std.testing.expect(state.domains.isBlocked("new.test"));
    try std.testing.expect(state.domains.isAllowed("allow.test"));
    try std.testing.expectEqualStrings("new.test", state.records[0].name);
}
