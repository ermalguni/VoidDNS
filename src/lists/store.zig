const std = @import("std");
const sqlite = @import("sqlite");
const Names = @import("../blocklist/parse.zig").Names;

/// Imported snapshots have their own database and schema version. JSON remains
/// authoritative for definitions; these rows describe successful imports only.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: sqlite.Db,
    mutex: std.Io.Mutex = .init,

    pub const Snapshot = struct {
        names: Names,
        last_success_at_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Store {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        _ = try db.one(i64, "PRAGMA busy_timeout=2000", .{}, .{});
        const version = (try db.one(i64, "PRAGMA user_version", .{}, .{})).?;
        if (version != 0 and version != 1) return error.UnsupportedListsSchema;
        try db.exec("PRAGMA foreign_keys=ON", .{}, .{});
        try db.exec("BEGIN IMMEDIATE", .{}, .{});
        errdefer rollback(&db);
        try db.exec("CREATE TABLE IF NOT EXISTS lists(id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind='block'),fingerprint TEXT NOT NULL,last_success_at_ms INTEGER NOT NULL)", .{}, .{});
        try db.exec("CREATE TABLE IF NOT EXISTS domains(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE)", .{}, .{});
        try db.exec("CREATE TABLE IF NOT EXISTS list_domains(list_id TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,domain_id INTEGER NOT NULL REFERENCES domains(id),PRIMARY KEY(list_id,domain_id)) WITHOUT ROWID", .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS list_domains_domain ON list_domains(domain_id)", .{}, .{});
        if ((try db.one(i64, "SELECT count(*) FROM lists WHERE kind<>'block'", .{}, .{})).? != 0) return error.UnsupportedListKind;
        try db.exec("PRAGMA user_version=1", .{}, .{});
        try db.exec("COMMIT", .{}, .{});
        return .{ .allocator = allocator, .io = io, .db = db };
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
        self.* = undefined;
    }

    /// One transaction covers every replacement in a prepared refresh-all.
    /// Never call while holding the DNS publication mutex.
    pub fn begin(self: *Store) !Transaction {
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);
        try self.db.exec("BEGIN IMMEDIATE", .{}, .{});
        return .{ .store = self };
    }

    pub fn reconcile(self: *Store, ids: []const []const u8) !void {
        var transaction = try self.begin();
        defer transaction.deinit();
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        defer keep.deinit(self.allocator);
        for (ids) |id| try keep.put(self.allocator, id, {});
        try transaction.retain(&keep);
        try transaction.commit();
    }

    pub const Transaction = struct {
        store: *Store,
        finished: bool = false,
        memberships_changed: bool = false,

        pub fn deinit(self: *Transaction) void {
            if (!self.finished) {
                rollback(&self.store.db);
                self.store.mutex.unlock(self.store.io);
            }
            self.* = undefined;
        }

        pub fn commit(self: *Transaction) !void {
            if (self.memberships_changed)
                try self.store.db.exec("DELETE FROM domains WHERE NOT EXISTS (SELECT 1 FROM list_domains WHERE domain_id=domains.id)", .{}, .{});
            try self.store.db.exec("COMMIT", .{}, .{});
            self.finished = true;
            self.store.mutex.unlock(self.store.io);
        }

        pub fn replace(self: *Transaction, id: []const u8, kind: []const u8, fingerprint: []const u8, names: *const Names, at_ms: i64) !void {
            if (!std.mem.eql(u8, kind, "block")) return error.UnsupportedListKind;
            const db = &self.store.db;
            try db.exec("INSERT INTO lists(id,kind,fingerprint,last_success_at_ms) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,fingerprint=excluded.fingerprint,last_success_at_ms=excluded.last_success_at_ms", .{}, .{ id, kind, fingerprint, at_ms });
            try db.exec("DELETE FROM list_domains WHERE list_id=?", .{}, .{id});
            self.memberships_changed = true;
            var domain = try db.prepare("INSERT INTO domains(name) VALUES(?) ON CONFLICT(name) DO NOTHING");
            defer domain.deinit();
            var membership = try db.prepare("INSERT INTO list_domains(list_id,domain_id) VALUES(?,(SELECT id FROM domains WHERE name=?))");
            defer membership.deinit();
            var keys = names.entries.keyIterator();
            while (keys.next()) |key| {
                domain.reset();
                try domain.exec(.{}, .{key.*});
                membership.reset();
                try membership.exec(.{}, .{ id, key.* });
            }
        }

        /// Even successful fetches are published from these persisted rows, not
        /// from the parser's temporary object. Empty snapshots are real rows.
        pub fn load(self: *Transaction, allocator: std.mem.Allocator, id: []const u8, fingerprint: []const u8) !?Snapshot {
            const db = &self.store.db;
            const at_ms = try db.one(i64, "SELECT last_success_at_ms FROM lists WHERE id=? AND kind='block' AND fingerprint=?", .{}, .{ id, fingerprint }) orelse return null;
            var names: Names = .{ .allocator = allocator };
            errdefer names.deinit();
            var statement = try db.prepare("SELECT domains.name FROM list_domains JOIN domains ON domains.id=list_domains.domain_id WHERE list_domains.list_id=?");
            defer statement.deinit();
            var rows = try statement.iterator([]const u8, .{id});
            while (try rows.nextAlloc(allocator, .{})) |name| {
                errdefer allocator.free(name);
                try names.entries.putNoClobber(allocator, name, {});
            }
            return .{ .names = names, .last_success_at_ms = at_ms };
        }

        pub fn remove(self: *Transaction, id: []const u8) !void {
            try self.store.db.exec("DELETE FROM lists WHERE id=?", .{}, .{id});
            self.memberships_changed = self.memberships_changed or self.store.db.rowsAffected() != 0;
        }

        pub fn retain(self: *Transaction, ids: *const std.StringHashMapUnmanaged(void)) !void {
            const allocator = self.store.allocator;
            // Finish the read before deleting rows from the same connection.
            var obsolete: std.ArrayList([]const u8) = .empty;
            defer {
                for (obsolete.items) |id| allocator.free(id);
                obsolete.deinit(allocator);
            }
            {
                var statement = try self.store.db.prepare("SELECT id FROM lists");
                defer statement.deinit();
                var rows = try statement.iterator([]const u8, .{});
                while (try rows.nextAlloc(allocator, .{})) |id| {
                    if (ids.contains(id)) {
                        allocator.free(id);
                    } else {
                        errdefer allocator.free(id);
                        try obsolete.append(allocator, id);
                    }
                }
            }
            for (obsolete.items) |id| try self.remove(id);
        }
    };

    fn rollback(db: *sqlite.Db) void {
        db.exec("ROLLBACK", .{}, .{}) catch |err| {
            std.log.err("list snapshot rollback failed: {s}", .{@errorName(err)});
        };
    }
};

test "snapshot transaction rollback rejects unsupported kinds and reconciliation preserves overlap" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    var store = try Store.init(allocator, io, path);
    defer store.deinit();
    var names = try @import("../blocklist/parse.zig").parse(allocator, "common.test\nfirst.test\n", .domains);
    defer names.deinit();
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.replace("first", "block", "fingerprint", &names, 1234);
        try transaction.replace("second", "block", "fingerprint", &names, 1234);
        try transaction.commit();
    }
    var empty: Names = .{ .allocator = allocator };
    defer empty.deinit();
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        try transaction.replace("first", "block", "replacement", &empty, 9999);
        try std.testing.expectError(error.UnsupportedListKind, transaction.replace("second", "allow", "replacement", &empty, 9999));
        // Abandon the entire batch, including its successful first replacement.
    }
    {
        var transaction = try store.begin();
        defer transaction.deinit();
        var snapshot = (try transaction.load(allocator, "first", "fingerprint")).?;
        defer snapshot.names.deinit();
        try std.testing.expectEqual(@as(i64, 1234), snapshot.last_success_at_ms);
        try std.testing.expectEqual(@as(u32, 2), snapshot.names.entries.count());
        try std.testing.expect((try transaction.load(allocator, "first", "replacement")) == null);
        try transaction.commit();
    }
    try store.reconcile(&.{"second"});
    try std.testing.expectEqual(@as(i64, 1), (try store.db.one(i64, "SELECT count(*) FROM lists", .{}, .{})).?);
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "SELECT count(*) FROM domains", .{}, .{})).?);
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "SELECT count(*) FROM list_domains", .{}, .{})).?);
    try store.reconcile(&.{});
    try std.testing.expectEqual(@as(i64, 0), (try store.db.one(i64, "SELECT count(*) FROM domains", .{}, .{})).?);
}
