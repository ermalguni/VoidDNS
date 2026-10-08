const std = @import("std");
const Store = @import("../domains/store.zig").Store;
const Service = @import("../blocklist/service.zig").Service;

/// Owned by main. Only complete states are exposed to the sequential DNS loop.
pub const State = struct {
    domains: Store,
    lists: Service,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .domains = Store.init(allocator), .lists = Service.init(allocator) };
    }

    pub fn deinit(self: *State) void {
        self.lists.deinit();
        self.domains.deinit();
        self.* = undefined;
    }
};
