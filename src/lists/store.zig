const std = @import("std");
const sqlite = @import("sqlite");
const Names = @import("../blocklist/parse.zig").Names;

/// Imported snapshots have their own database and schema version. JSON remains
/// authoritative for definitions; these rows describe successful imports only.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: sqlite.Db,
    reader: sqlite.Db,
    reader_mutex: std.Io.Mutex = .init,
    mutex: std.Io.Mutex = .init,

    pub const Snapshot = struct {
        names: Names,
        last_success_at_ms: i64,
        version: [32]u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Store {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        _ = try db.one(i64, "PRAGMA busy_timeout=2000", .{}, .{});
        const version = (try db.one(i64, "PRAGMA user_version", .{}, .{})).?;
        if (version < 0 or version > 2) return error.UnsupportedListsSchema;
        const journal = (try db.oneAlloc([]const u8, allocator, "PRAGMA journal_mode=WAL", .{}, .{})).?;
        defer allocator.free(journal);
        if (!std.mem.eql(u8, journal, "wal")) return error.WalUnavailable;
        try db.exec("PRAGMA foreign_keys=ON", .{}, .{});
        try db.exec("BEGIN IMMEDIATE", .{}, .{});
        errdefer rollback(&db);
        try db.exec("CREATE TABLE IF NOT EXISTS lists(id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind='block'),fingerprint TEXT NOT NULL,last_success_at_ms INTEGER NOT NULL,version TEXT NOT NULL,domain_count INTEGER NOT NULL)", .{}, .{});
        try db.exec("CREATE TABLE IF NOT EXISTS domains(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE)", .{}, .{});
        try db.exec("CREATE TABLE IF NOT EXISTS list_domains(list_id TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,domain_id INTEGER NOT NULL REFERENCES domains(id),name TEXT NOT NULL,PRIMARY KEY(list_id,domain_id)) WITHOUT ROWID", .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS list_domains_domain ON list_domains(domain_id)", .{}, .{});
        if (version == 1) {
            try db.exec("ALTER TABLE lists ADD COLUMN version TEXT NOT NULL DEFAULT ''", .{}, .{});
            try db.exec("ALTER TABLE lists ADD COLUMN domain_count INTEGER NOT NULL DEFAULT 0", .{}, .{});
            try db.exec("ALTER TABLE list_domains ADD COLUMN name TEXT", .{}, .{});
            try db.exec("UPDATE list_domains SET name=(SELECT name FROM domains WHERE id=domain_id)", .{}, .{});
            try db.exec("UPDATE lists SET version=lower(hex(randomblob(16))),domain_count=(SELECT count(*) FROM list_domains WHERE list_id=lists.id)", .{}, .{});
        }
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS list_domains_name ON list_domains(list_id,name)", .{}, .{});
        if ((try db.one(i64, "SELECT count(*) FROM lists WHERE kind<>'block'", .{}, .{})).? != 0) return error.UnsupportedListKind;
        try db.exec("PRAGMA user_version=2", .{}, .{});
        try db.exec("COMMIT", .{}, .{});
        var reader = try sqlite.Db.init(.{ .mode = .{ .File = path } });
        errdefer reader.deinit();
        _ = try reader.one(i64, "PRAGMA busy_timeout=1000", .{}, .{});
        return .{ .allocator = allocator, .io = io, .db = db, .reader = reader };
    }

    pub fn deinit(self: *Store) void {
        self.reader.deinit();
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
            try db.exec("INSERT INTO lists(id,kind,fingerprint,last_success_at_ms,version,domain_count) VALUES(?,?,?,?,lower(hex(randomblob(16))),?) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,fingerprint=excluded.fingerprint,last_success_at_ms=excluded.last_success_at_ms,version=excluded.version,domain_count=excluded.domain_count", .{}, .{ id, kind, fingerprint, at_ms, names.entries.count() });
            try db.exec("DELETE FROM list_domains WHERE list_id=?", .{}, .{id});
            self.memberships_changed = true;
            var domain = try db.prepare("INSERT INTO domains(name) VALUES(?) ON CONFLICT(name) DO NOTHING");
            defer domain.deinit();
            var membership = try db.prepare("INSERT INTO list_domains(list_id,domain_id,name) VALUES(?,(SELECT id FROM domains WHERE name=?),?)");
            defer membership.deinit();
            var keys = names.entries.keyIterator();
            while (keys.next()) |key| {
                domain.reset();
                try domain.exec(.{}, .{key.*});
                membership.reset();
                try membership.exec(.{}, .{ id, key.*, key.* });
            }
        }

        /// Even successful fetches are published from these persisted rows, not
        /// from the parser's temporary object. Empty snapshots are real rows.
        pub fn load(self: *Transaction, allocator: std.mem.Allocator, id: []const u8, fingerprint: []const u8) !?Snapshot {
            const db = &self.store.db;
            const at_ms = try db.one(i64, "SELECT last_success_at_ms FROM lists WHERE id=? AND kind='block' AND fingerprint=?", .{}, .{ id, fingerprint }) orelse return null;
            const version_text = (try db.oneAlloc([]const u8, allocator, "SELECT version FROM lists WHERE id=?", .{}, .{id})).?;
            defer allocator.free(version_text);
            if (version_text.len != 32) return error.InvalidSnapshotVersion;
            var content_version: [32]u8 = undefined;
            @memcpy(&content_version, version_text);
            var names: Names = .{ .allocator = allocator };
            errdefer names.deinit();
            var statement = try db.prepare("SELECT domains.name FROM list_domains JOIN domains ON domains.id=list_domains.domain_id WHERE list_domains.list_id=?");
            defer statement.deinit();
            var rows = try statement.iterator([]const u8, .{id});
            while (try rows.nextAlloc(allocator, .{})) |name| {
                errdefer allocator.free(name);
                try names.entries.putNoClobber(allocator, name, {});
            }
            return .{ .names = names, .last_success_at_ms = at_ms, .version = content_version };
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

    pub const Page = struct {
        version: [32]u8,
        last_success_at_ms: i64,
        domain_count: usize,
        items: []const []const u8,
    };

    /// Independent WAL reader: never waits for the long import transaction.
    /// A single read transaction binds metadata and the bounded indexed page.
    pub fn browse(self: *Store, allocator: std.mem.Allocator, id: []const u8, fingerprint: []const u8, exact: ?[]const u8, prefix: ?[]const u8, after: []const u8, limit: usize) !?Page {
        if (limit == 0 or limit > 101) return error.InvalidLimit;
        self.reader_mutex.lockUncancelable(self.io);
        defer self.reader_mutex.unlock(self.io);
        var deadline: Deadline = .{ .io = self.io, .started = std.Io.Clock.awake.now(self.io) };
        sqlite.c.sqlite3_progress_handler(self.reader.db, 1000, Deadline.check, &deadline);
        defer sqlite.c.sqlite3_progress_handler(self.reader.db, 0, null, null);
        try self.reader.exec("BEGIN", .{}, .{});
        defer self.reader.exec("ROLLBACK", .{}, .{}) catch {};
        const Meta = struct { version: []const u8, last_success_at_ms: i64, domain_count: usize };
        const meta = try self.reader.oneAlloc(Meta, allocator, "SELECT version,last_success_at_ms,domain_count FROM lists WHERE id=? AND fingerprint=? AND kind='block'", .{}, .{ id, fingerprint }) orelse return null;
        defer allocator.free(meta.version);
        if (meta.version.len != 32) return error.InvalidSnapshotVersion;
        var result: Page = .{ .version = undefined, .last_success_at_ms = meta.last_success_at_ms, .domain_count = meta.domain_count, .items = &.{} };
        @memcpy(&result.version, meta.version);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item);
            items.deinit(allocator);
        }
        // All accepted prefix bytes are below '{'; this forms an indexed range.
        const lower = exact orelse prefix orelse "";
        const upper = try std.fmt.allocPrint(allocator, "{s}{{", .{lower});
        defer allocator.free(upper);
        var statement = try self.reader.prepare("SELECT name FROM list_domains WHERE list_id=? AND name>=? AND name<? AND name>? AND (? IS NULL OR name=?) ORDER BY name LIMIT ?");
        defer statement.deinit();
        var rows = try statement.iterator([]const u8, .{ id, lower, upper, after, exact, exact, limit });
        while (try rows.nextAlloc(allocator, .{})) |name| {
            errdefer allocator.free(name);
            try items.append(allocator, name);
        }
        result.items = try items.toOwnedSlice(allocator);
        return result;
    }

    const Deadline = struct {
        io: std.Io,
        started: std.Io.Timestamp,
        fn check(context: ?*anyopaque) callconv(.c) c_int {
            const self: *Deadline = @ptrCast(@alignCast(context.?));
            return @intFromBool(self.started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= 2000);
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

test "bounded WAL browsing sees committed snapshots while an import writer is open" {
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
    var old = try @import("../blocklist/parse.zig").parse(allocator, "z.test\ncommon.test\na.test\n", .domains);
    defer old.deinit();
    var fresh = try @import("../blocklist/parse.zig").parse(allocator, "new.test\n", .domains);
    defer fresh.deinit();
    {
        var tx = try store.begin();
        defer tx.deinit();
        try tx.replace("source", "block", "compatible", &old, 100);
        try tx.commit();
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = (try store.browse(a, "source", "compatible", null, null, "", 2)).?;
    try std.testing.expectEqual(@as(usize, 3), first.domain_count);
    try std.testing.expectEqualStrings("a.test", first.items[0]);
    try std.testing.expectEqualStrings("common.test", first.items[1]);
    const exact = (try store.browse(a, "source", "compatible", "common.test", null, "", 2)).?;
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    const prefix = (try store.browse(a, "source", "compatible", null, "com", "", 2)).?;
    try std.testing.expectEqualStrings("common.test", prefix.items[0]);
    const next = (try store.browse(a, "source", "compatible", null, null, "common.test", 2)).?;
    try std.testing.expectEqualStrings("z.test", next.items[0]);
    try std.testing.expect((try store.browse(a, "source", "incompatible", null, null, "", 2)) == null);
    try std.testing.expectError(error.InvalidLimit, store.browse(a, "source", "compatible", null, null, "", 102));
    {
        var tx = try store.begin();
        defer tx.deinit();
        try tx.replace("source", "block", "compatible", &fresh, 100);
        // Neither source I/O nor this uncommitted replacement blocks reads.
        const during = (try store.browse(a, "source", "compatible", null, null, "", 2)).?;
        try std.testing.expectEqualStrings(&first.version, &during.version);
        try std.testing.expectEqualStrings("a.test", during.items[0]);
        try tx.commit();
    }
    const after = (try store.browse(a, "source", "compatible", null, null, "", 2)).?;
    try std.testing.expect(!std.mem.eql(u8, &first.version, &after.version));
    try std.testing.expectEqual(@as(usize, 1), after.domain_count);
    try std.testing.expectEqualStrings("new.test", after.items[0]);
}

test "version one durable databases migrate retained names and content versions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/lists.db", .{base}, 0);
    defer allocator.free(path);
    {
        var db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true, .create = true } });
        defer db.deinit();
        try db.exec("CREATE TABLE lists(id TEXT PRIMARY KEY,kind TEXT NOT NULL,fingerprint TEXT NOT NULL,last_success_at_ms INTEGER NOT NULL)", .{}, .{});
        try db.exec("CREATE TABLE domains(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE)", .{}, .{});
        try db.exec("CREATE TABLE list_domains(list_id TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,domain_id INTEGER NOT NULL REFERENCES domains(id),PRIMARY KEY(list_id,domain_id)) WITHOUT ROWID", .{}, .{});
        try db.exec("INSERT INTO lists VALUES('source','block','compatible',100)", .{}, .{});
        try db.exec("INSERT INTO domains VALUES(1,'retained.test')", .{}, .{});
        try db.exec("INSERT INTO list_domains VALUES('source',1)", .{}, .{});
        try db.exec("PRAGMA user_version=1", .{}, .{});
    }
    var store = try Store.init(allocator, io, path);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const saved = (try store.browse(arena.allocator(), "source", "compatible", null, null, "", 1)).?;
    try std.testing.expectEqual(@as(usize, 1), saved.domain_count);
    try std.testing.expectEqualStrings("retained.test", saved.items[0]);
    try std.testing.expectEqual(@as(i64, 2), (try store.db.one(i64, "PRAGMA user_version", .{}, .{})).?);
}
