const std = @import("std");
const Store = @import("../domains/store.zig").Store;
const Service = @import("../blocklist/service.zig").Service;
const Record = @import("../domains/record.zig");

/// Owned by main; managed reads and publication hold mutex.
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    /// Borrows the active configuration; reclaimed by main after publication.
    records: []const Record = &.{},
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
