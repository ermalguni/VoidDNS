const std = @import("std");
const config = @import("../config/config.zig");
const document = @import("../config/document.zig");
const Manager = @import("../config/manager.zig").Manager;
const State = @import("../state/state.zig").State;
const Worker = @import("../server/server.zig").Worker;
const control = @import("../server/control.zig");
const Apply = @import("../state/apply.zig").Plan;
const Service = @import("../blocklist/service.zig").Service;
const bridge = @import("bridge.zig");
const domain = @import("../domains/domain.zig");
const security = @import("../blocklist/security.zig");
const logging = @import("../logging.zig");
const Document = document.Document;
const Record = std.meta.Elem(@FieldType(Document, "records"));
const Source = std.meta.Elem(@FieldType(@FieldType(Document, "blocks"), "lists"));
const Domain = struct { id: []const u8, domain: []const u8, action: enum { allow, block } };
const RecordView = struct { id: []const u8, name: []const u8, type: @FieldType(Record, "type"), ttl: u32, addresses: []const []const u8 };
const Settings = struct { dns: @FieldType(Document, "dns"), upstream: @FieldType(Document, "upstream"), cache: @FieldType(Document, "cache"), logging: @FieldType(Document, "logging") };

pub const Management = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *Manager,
    settings: *config.Config,
    state: *State,
    worker: *Worker,
    mailbox: *control.Mailbox,
    next_generation: *u64,
    revision: u64 = 1,
    next_operation: u64 = 1,
    job: ?*Job = null,
    history: [64]?Operation = @splat(null),
    saved_matches_active: bool = true,
    pending: [control.request_capacity]control.Request = undefined,
    pending_count: usize = 0,
    quit_requested: bool = false,

    const Result = struct { saved: bool, active: bool, durability: enum { unchanged, durable, uncertain }, revision: u64, resource_id: ?[]const u8 = null };
    const Operation = struct { id: u64, status: enum { running, succeeded, failed }, result: ?Result = null, @"error": ?[]const u8 = null };
    const Job = struct {
        owner: *Management,
        id: u64,
        kind: enum { save, reload, refresh },
        api: bool = true,
        candidate: ?config.Config = null,
        plan: ?Apply = null,
        runtime: ?Worker.Update = null,
        refresh_plan: ?Service.Plan = null,
        selection: Service.Refresh = .all,
        path: ?[]const u8 = null,
        resource_id: ?[]const u8 = null,
        saved: bool = false,
        durability: @FieldType(Result, "durability") = .unchanged,
        failure: ?anyerror = null,
        future: ?std.Io.Future(void) = null,

        fn run(self: *Job) void {
            self.prepare() catch |err| {
                self.failure = err;
            };
            self.owner.mailbox.operationReady(self.owner.io);
        }

        fn prepare(self: *Job) !void {
            const owner = self.owner;
            var diagnostic: config.Diagnostic = .{};
            if (self.kind == .refresh) {
                self.refresh_plan = try owner.state.lists.prepare(owner.io, owner.settings.definitions.sources.items, owner.settings.base_dir, self.selection);
                return;
            }
            if (self.kind == .reload) {
                self.candidate = try owner.manager.load(owner.io, &diagnostic);
            } else if (self.path) |path| {
                const contents = try std.Io.Dir.cwd().readFileAlloc(owner.io, path, owner.allocator, .limited(config.max_file_size));
                defer owner.allocator.free(contents);
                self.candidate = try config.parse(owner.allocator, contents, owner.settings.base_dir, &diagnostic);
            }
            const candidate = &self.candidate.?;
            if (!try sameApi(owner.allocator, owner.settings, candidate)) return error.ApiRestartRequired;
            if (owner.settings.ui.enabled != candidate.ui.enabled) return error.UiRestartRequired;
            if (self.api) try security.validateApiSources(owner.allocator, owner.io, candidate, owner.settings);
            if (self.kind == .save) {
                var arena = std.heap.ArenaAllocator.init(owner.allocator);
                defer arena.deinit();
                const doc = try config.toDocument(arena.allocator(), candidate);
                owner.manager.save(owner.io, &doc, &diagnostic) catch |err| {
                    if (err == error.DurabilityUncertain) {
                        self.saved = true;
                        self.durability = .uncertain;
                    }
                    return err;
                };
                self.saved = true;
                self.durability = .durable;
            }
            self.plan = try Apply.prepare(owner.allocator, owner.io, owner.state, owner.settings, candidate);
            self.runtime = try Worker.Update.prepare(owner.allocator, owner.settings, candidate);
        }

        fn deinit(self: *Job) void {
            if (self.plan) |*plan| plan.deinit();
            if (self.runtime) |*runtime| runtime.deinit();
            if (self.refresh_plan) |*plan| plan.deinit();
            if (self.candidate) |*candidate| candidate.deinit();
            if (self.path) |path| self.owner.allocator.free(path);
            if (self.resource_id) |id| self.owner.allocator.free(id);
            if (self.selection == .one) self.owner.allocator.free(self.selection.one);
            self.owner.allocator.destroy(self);
        }
    };

    pub fn asBridge(self: *Management) bridge.Bridge {
        return .{ .context = self, .handleFn = dispatch };
    }

    fn dispatch(context: *anyopaque, allocator: std.mem.Allocator, request: bridge.Request) !bridge.Response {
        const self: *Management = @ptrCast(@alignCast(context));
        var call: bridge.Call = .{ .allocator = allocator, .request = request };
        self.mailbox.putApi(self.io, &call) catch |err| return failure(allocator, 503, @errorName(err), null);
        return call.awaitResult(self.io) catch |err| failure(allocator, 503, @errorName(err), null);
    }

    pub fn close(self: *Management) void {
        self.mailbox.closeApi(self.io);
        if (self.job) |job| {
            if (job.future) |*future| future.cancel(self.io);
            job.deinit();
            self.job = null;
        }
        for (self.pending[0..self.pending_count]) |request| request.deinit(self.allocator);
        self.pending_count = 0;
        for (&self.history) |*slot| {
            if (slot.*) |operation| if (operation.result) |result| if (result.resource_id) |id| self.allocator.free(id);
            slot.* = null;
        }
    }

    pub fn handleCall(self: *Management, call: *bridge.Call) void {
        const response = self.handle(call.allocator, call.request) catch |err| failure(call.allocator, switch (err) {
            error.OutOfMemory => 500,
            else => 400,
        }, @errorName(err), self.revision);
        call.finish(self.io, response);
    }

    pub fn complete(self: *Management) void {
        const job = self.job orelse return;
        if (job.future) |*future| future.await(self.io);
        if (job.failure == null) self.publish(job) catch |err| {
            job.failure = err;
        };
        // Failure results are published management state too, including a save
        // that changed disk without changing the active DNS configuration.
        if (job.failure != null) self.revision += 1;
        if (job.saved) self.saved_matches_active = job.failure == null;
        if (job.kind == .reload) self.saved_matches_active = job.failure == null;
        var result: Result = .{ .saved = job.saved, .active = job.failure == null, .durability = job.durability, .revision = self.revision };
        result.resource_id = job.resource_id;
        job.resource_id = null;
        const slot = &self.history[@intCast(job.id % self.history.len)];
        if (slot.*) |old| if (old.result) |old_result| if (old_result.resource_id) |id| self.allocator.free(id);
        slot.* = .{ .id = job.id, .status = if (job.failure == null) .succeeded else .failed, .result = result, .@"error" = if (job.failure) |err| @errorName(err) else null };
        if (job.failure) |err| std.log.err("management operation={d} failed saved={} active=false: {s}", .{ job.id, job.saved, @errorName(err) });
        job.deinit();
        self.job = null;
        while (self.job == null and self.pending_count != 0) {
            const request = self.pending[0];
            self.pending_count -= 1;
            std.mem.copyForwards(control.Request, self.pending[0..self.pending_count], self.pending[1..][0..self.pending_count]);
            defer request.deinit(self.allocator);
            self.stdin(request) catch |err| std.log.err("queued control request failed: {s}", .{@errorName(err)});
        }
    }

    fn publish(self: *Management, job: *Job) !void {
        if (job.refresh_plan) |*plan| {
            self.state.mutex.lockUncancelable(self.io);
            defer self.state.mutex.unlock(self.io);
            try plan.reserve(&self.state.lists);
            plan.commit(&self.state.lists);
            self.revision += 1;
            return;
        }
        const candidate = &job.candidate.?;
        const plan = &job.plan.?;
        const runtime = &job.runtime.?;
        self.state.mutex.lockUncancelable(self.io);
        plan.reserve(self.state) catch |err| {
            self.state.mutex.unlock(self.io);
            return err;
        };
        self.state.mutex.unlock(self.io);
        const listener_changed = !self.settings.listen_address.eql(&candidate.listen_address);
        if (listener_changed) self.worker.stop(self.io);
        const lock_runtime = listener_changed or runtime.needsLock();
        if (lock_runtime) self.worker.mutex.lockUncancelable(self.io);
        defer if (lock_runtime) self.worker.mutex.unlock(self.io);
        self.state.mutex.lockUncancelable(self.io);
        defer self.state.mutex.unlock(self.io);
        if (listener_changed) {
            self.worker.listen_address = candidate.listen_address;
            self.startWorker() catch |err| {
                self.worker.listen_address = self.settings.listen_address;
                self.startWorker() catch |rollback_err| {
                    self.mailbox.workerFailed(self.io, .{ .generation = self.worker.generation, .err = rollback_err });
                    return rollback_err;
                };
                return err;
            };
        }
        plan.commit(self.state, self.settings, candidate);
        if (!runtime.upstreams_changed) std.mem.swap([]const std.Io.net.IpAddress, &self.settings.upstream_addresses, &candidate.upstream_addresses);
        if (runtime.needsLock()) runtime.commit(self.worker);
        self.worker.setTcp(self.io, candidate.dns_tcp);
        std.mem.swap(config.Config, self.settings, candidate);
        logging.setLevel(self.settings.log_level);
        self.revision += 1;
    }

    fn startWorker(self: *Management) !void {
        const generation = self.next_generation.*;
        self.next_generation.* +%= 1;
        try self.worker.start(self.io, generation);
    }

    fn launch(self: *Management, job: *Job) !u64 {
        errdefer job.deinit();
        if (self.job != null) return error.OperationInProgress;
        job.id = self.next_operation;
        self.next_operation += 1;
        self.job = job;
        errdefer self.job = null;
        job.future = try self.io.concurrent(Job.run, .{job});
        return job.id;
    }

    fn newJob(self: *Management, kind: @FieldType(Job, "kind")) !*Job {
        const job = try self.allocator.create(Job);
        job.* = .{ .owner = self, .id = 0, .kind = kind };
        return job;
    }

    pub fn stdin(self: *Management, request: control.Request) !void {
        if (self.job != null) {
            if (self.pending_count == self.pending.len) return error.QueueFull;
            self.pending[self.pending_count] = switch (request) {
                .save => |path| .{ .save = try self.allocator.dupe(u8, path) },
                .refresh => |id| .{ .refresh = try self.allocator.dupe(u8, id) },
                else => request,
            };
            self.pending_count += 1;
            return;
        }
        const job = try self.newJob(switch (request) {
            .reload => .reload,
            .save => .save,
            .refresh, .refresh_all => .refresh,
            else => return,
        });
        job.api = false;
        switch (request) {
            .save => |path| job.path = self.allocator.dupe(u8, path) catch |err| {
                job.deinit();
                return err;
            },
            .refresh => |id| job.selection = .{ .one = self.allocator.dupe(u8, id) catch |err| {
                job.deinit();
                return err;
            } },
            else => {},
        }
        _ = try self.launch(job);
    }

    fn handle(self: *Management, a: std.mem.Allocator, request: bridge.Request) !bridge.Response {
        if (!std.mem.startsWith(u8, request.path, "/api/v1/")) return failure(a, 404, "NotFound", self.revision);
        const path = request.path[8..];
        const get = eq(request.method, "GET");
        const post = eq(request.method, "POST");
        const put = eq(request.method, "PUT");
        const delete = eq(request.method, "DELETE");
        if (eq(path, "config/validate")) {
            if (!post) return failure(a, 405, "MethodNotAllowed", self.revision);
            var diagnostic: config.Diagnostic = .{};
            var candidate = config.parse(self.allocator, request.body, self.settings.base_dir, &diagnostic) catch |err| return failure(a, 400, if (diagnostic.len != 0) diagnostic.text() else @errorName(err), self.revision);
            defer candidate.deinit();
            return json(a, 200, .{ .valid = true }, self.revision);
        }
        if (std.mem.startsWith(u8, path, "operations/")) {
            if (!get) return failure(a, 405, "MethodNotAllowed", self.revision);
            const id = std.fmt.parseInt(u64, path[11..], 10) catch return failure(a, 404, "OperationNotFound", self.revision);
            if (self.job) |job| if (job.id == id) return json(a, 200, Operation{ .id = id, .status = .running }, self.revision);
            if (self.history[@intCast(id % self.history.len)]) |operation| if (operation.id == id) return json(a, 200, operation, self.revision);
            return failure(a, 404, "OperationNotFound", self.revision);
        }
        if (eq(path, "status")) {
            if (!get) return failure(a, 405, "MethodNotAllowed", self.revision);
            return json(a, 200, .{ .dns = .{ .ready = self.worker.listener != null and self.worker.tcp_listener != null, .generation = self.worker.generation, .listen = try std.fmt.allocPrint(a, "{f}", .{self.settings.listen_address}) }, .revision = self.revision, .saved_matches_active = if (self.job == null) @as(?bool, self.saved_matches_active) else null, .operation_id = if (self.job) |job| @as(?u64, job.id) else null }, self.revision);
        }
        if (eq(path, "policy/check")) {
            if (!get) return failure(a, 405, "MethodNotAllowed", self.revision);
            return self.policy(a, request.query);
        }
        if (eq(path, "cache")) {
            if (!get) return failure(a, 405, "MethodNotAllowed", self.revision);
            self.worker.mutex.lockUncancelable(self.io);
            defer self.worker.mutex.unlock(self.io);
            return json(a, 200, .{ .capacity = self.worker.cache.slots.len, .occupied_slots = self.worker.cache.occupied() }, self.revision);
        }
        if (eq(path, "cache/entries")) {
            if (!delete) return failure(a, 405, "MethodNotAllowed", self.revision);
            if (try self.precondition(a, request)) |response| return response;
            self.worker.mutex.lockUncancelable(self.io);
            self.worker.cache.clear();
            self.worker.mutex.unlock(self.io);
            self.revision += 1;
            return json(a, 200, .{ .cleared = true, .revision = self.revision }, self.revision);
        }
        const refresh_all = post and eq(path, "blocklists/refresh");
        const refresh_one = path.len > "blocklists/".len + "/refresh".len and
            std.mem.startsWith(u8, path, "blocklists/") and std.mem.endsWith(u8, path, "/refresh");
        if (eq(path, "config/reload") or refresh_all or refresh_one) {
            if (!post) return failure(a, 405, "MethodNotAllowed", self.revision);
            if (try self.precondition(a, request)) |response| return response;
            const job = try self.newJob(if (eq(path, "config/reload")) .reload else .refresh);
            if (job.kind == .refresh and !eq(path, "blocklists/refresh")) {
                const id = decode(a, path["blocklists/".len .. path.len - "/refresh".len]) catch |err| {
                    job.deinit();
                    return err;
                };
                if (!self.state.lists.sources.contains(id)) {
                    job.deinit();
                    return failure(a, 404, "SourceNotFound", self.revision);
                }
                job.selection = .{ .one = self.allocator.dupe(u8, id) catch |err| {
                    job.deinit();
                    return err;
                } };
            }
            return self.accepted(a, try self.launch(job));
        }
        if (eq(path, "config") or eq(path, "settings")) {
            if (!get and !put) return failure(a, 405, "MethodNotAllowed", self.revision);
            var doc = try config.toDocument(a, self.settings);
            if (get) {
                if (eq(path, "config")) return .{
                    .status = 200,
                    .body = try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false }),
                    .revision = self.revision,
                };
                return json(a, 200, settingsView(doc), self.revision);
            }
            if (try self.precondition(a, request)) |response| return response;
            if (eq(path, "config")) {
                var diagnostic: config.Diagnostic = .{};
                const parsed = document.parse(a, request.body, &diagnostic) catch |err| return failure(a, 400, if (diagnostic.len != 0) diagnostic.text() else @errorName(err), self.revision);
                doc = parsed.value;
            } else {
                const replacement = try parseBody(Settings, a, request.body);
                doc.dns = replacement.dns;
                doc.upstream = replacement.upstream;
                doc.cache = replacement.cache;
                doc.logging = replacement.logging;
            }
            return self.saveDocument(a, doc, null);
        }
        inline for (.{ "domains", "records", "blocklists" }) |resource_kind| {
            if (eq(path, resource_kind) or (std.mem.startsWith(u8, path, resource_kind ++ "/") and path.len > resource_kind.len + 1)) {
                const id = if (path.len > resource_kind.len) try decode(a, path[resource_kind.len + 1 ..]) else null;
                if (get) return self.collection(a, resource_kind, id, request.query);
                if ((id == null and !post) or (id != null and !put and !delete)) return failure(a, 405, "MethodNotAllowed", self.revision);
                if (try self.precondition(a, request)) |response| return response;
                return self.mutate(a, resource_kind, id, delete, request.body);
            }
        }
        return failure(a, 404, "NotFound", self.revision);
    }

    fn precondition(self: *Management, a: std.mem.Allocator, request: bridge.Request) !?bridge.Response {
        const match = request.if_match orelse return try failure(a, 428, "IfMatchRequired", self.revision);
        const expected = try std.fmt.allocPrint(a, "\"{d}\"", .{self.revision});
        if (!eq(match, expected)) return try failure(a, 412, "RevisionMismatch", self.revision);
        if (self.job != null) return try failure(a, 409, "OperationInProgress", self.revision);
        return null;
    }

    fn accepted(self: *Management, a: std.mem.Allocator, id: u64) !bridge.Response {
        return json(a, 202, .{ .operation = Operation{ .id = id, .status = .running }, .revision = self.revision }, self.revision);
    }

    fn saveDocument(self: *Management, a: std.mem.Allocator, doc: Document, resource: ?[]const u8) !bridge.Response {
        var diagnostic: config.Diagnostic = .{};
        var candidate = config.fromDocument(self.allocator, &doc, self.settings.base_dir, &diagnostic) catch |err| return failure(a, 400, if (diagnostic.len != 0) diagnostic.text() else @errorName(err), self.revision);
        var owned = true;
        errdefer if (owned) candidate.deinit();
        if (!try sameApi(a, self.settings, &candidate)) {
            candidate.deinit();
            owned = false;
            return failure(a, 409, "ApiRestartRequired", self.revision);
        }
        if (self.settings.ui.enabled != candidate.ui.enabled) {
            candidate.deinit();
            owned = false;
            return failure(a, 409, "UiRestartRequired", self.revision);
        }
        const owned_resource = if (resource) |id| try self.allocator.dupe(u8, id) else null;
        errdefer if (owned) {
            if (owned_resource) |id| self.allocator.free(id);
        };
        const job = try self.newJob(.save);
        job.candidate = candidate;
        job.resource_id = owned_resource;
        owned = false;
        // launch owns the job, including candidate, on both success and failure.
        const id = self.launch(job) catch |err| return failure(a, 503, @errorName(err), self.revision);
        return self.accepted(a, id);
    }

    fn policy(self: *Management, a: std.mem.Allocator, query: []const u8) !bridge.Response {
        const raw = (try parameter(a, query, "name")) orelse return failure(a, 400, "NameRequired", self.revision);
        var buffer: [253]u8 = undefined;
        const name = try domain.normalize(raw, &buffer);
        const raw_type = (try parameter(a, query, "type")) orelse "A";
        const qtype: u16 = if (eq(raw_type, "A")) 1 else if (eq(raw_type, "AAAA")) 28 else try std.fmt.parseInt(u16, raw_type, 10);
        self.state.mutex.lockUncancelable(self.io);
        defer self.state.mutex.unlock(self.io);
        var local = false;
        for (self.state.records) |record| if (eq(record.name, name)) {
            if (@backingInt(record.recordType()) == qtype) local = true;
        };
        const explicit_block = self.state.domains.isBlocked(name);
        const explicit_allow = self.state.domains.isAllowed(name);
        const imported = self.state.lists.contains(name);
        const decision = @import("../policy/policy.zig").decide(self.state, name, local);
        const reason: []const u8 = if (explicit_block) "explicit_block" else if (explicit_allow and !local) "explicit_allow" else if (local) "local_record" else if (imported) "imported_blocklist" else "default_forward";
        return json(a, 200, .{ .name = name, .type = qtype, .decision = decision, .reason = reason, .exact = true, .explicit_block = explicit_block, .explicit_allow = explicit_allow, .imported_block = imported, .local_record = local, .upstream_queried = false }, self.revision);
    }

    fn collection(self: *Management, a: std.mem.Allocator, comptime kind: []const u8, id: ?[]const u8, query: []const u8) !bridge.Response {
        const doc = try config.toDocument(a, self.settings);
        if (comptime eq(kind, "domains")) {
            var items: std.ArrayList(Domain) = .empty;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(a);
            const action = try parameter(a, query, "action");
            if (action) |value| if (!eq(value, "allow") and !eq(value, "block")) return failure(a, 400, "InvalidAction", self.revision);
            var name_buffer: [253]u8 = undefined;
            const filter = if (try parameter(a, query, "domain")) |value| try domain.normalize(value, &name_buffer) else null;
            inline for (.{ "allow", "block" }) |which| {
                const names = if (comptime eq(which, "allow")) doc.allows.domains else doc.blocks.domains;
                for (names) |name| {
                    if (action) |value| if (!eq(value, which)) continue;
                    if (filter) |value| if (!eq(value, name)) continue;
                    const key = try std.fmt.allocPrint(a, which ++ ":{s}", .{name});
                    if ((try seen.getOrPut(a, key)).found_existing) continue;
                    const item: Domain = .{ .id = key, .domain = name, .action = @field(@FieldType(Domain, "action"), which) };
                    if (id) |wanted| {
                        if (eq(key, wanted)) return json(a, 200, item, self.revision);
                    } else try items.append(a, item);
                }
            }
            if (id != null) return failure(a, 404, "DomainNotFound", self.revision);
            return self.page(Domain, a, items.items, query);
        } else if (comptime eq(kind, "records")) {
            var items: std.ArrayList(RecordView) = .empty;
            for (doc.records) |record| {
                const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(record.type), record.name });
                const item: RecordView = .{ .id = key, .name = record.name, .type = record.type, .ttl = record.ttl, .addresses = record.addresses };
                if (id) |wanted| {
                    if (eq(key, wanted)) return json(a, 200, item, self.revision);
                } else try items.append(a, item);
            }
            if (id != null) return failure(a, 404, "RecordNotFound", self.revision);
            return self.page(RecordView, a, items.items, query);
        } else {
            if (id) |wanted| {
                for (doc.blocks.lists) |source| if (eq(source.id, wanted)) return json(a, 200, source, self.revision);
                return failure(a, 404, "SourceNotFound", self.revision);
            }
            return self.page(Source, a, try a.dupe(Source, doc.blocks.lists), query);
        }
    }

    fn page(self: *Management, comptime T: type, a: std.mem.Allocator, items: []T, query: []const u8) !bridge.Response {
        const raw_limit = (try parameter(a, query, "limit")) orelse "50";
        const limit = try std.fmt.parseInt(usize, raw_limit, 10);
        if (limit == 0 or limit > 100) return failure(a, 400, "InvalidLimit", self.revision);
        const after = try parameter(a, query, "after");
        std.mem.sort(T, items, {}, struct {
            fn less(_: void, left: T, right: T) bool {
                return std.mem.lessThan(u8, left.id, right.id);
            }
        }.less);
        var begin: usize = 0;
        if (after) |cursor| {
            const separator = std.mem.indexOfScalar(u8, cursor, ':') orelse return failure(a, 400, "InvalidCursor", self.revision);
            const revision = std.fmt.parseInt(u64, cursor[0..separator], 10) catch return failure(a, 400, "InvalidCursor", self.revision);
            if (revision != self.revision) return failure(a, 409, "StaleCursor", self.revision);
            const last = cursor[separator + 1 ..];
            while (begin < items.len and !std.mem.lessThan(u8, last, items[begin].id)) : (begin += 1) {}
        }
        const end = begin + @min(limit, items.len - begin);
        const next: ?[]const u8 = if (end < items.len) try std.fmt.allocPrint(a, "{d}:{s}", .{ self.revision, items[end - 1].id }) else null;
        return json(a, 200, .{ .items = items[begin..end], .next_cursor = next, .revision = self.revision }, self.revision);
    }

    fn mutate(self: *Management, a: std.mem.Allocator, comptime kind: []const u8, id: ?[]const u8, delete: bool, body: []const u8) !bridge.Response {
        var doc = try config.toDocument(a, self.settings);
        var resource: ?[]const u8 = id;
        if (comptime eq(kind, "domains")) {
            const Input = struct { domain: []const u8, action: @FieldType(Domain, "action") };
            var replacement: ?Input = null;
            if (!delete) {
                replacement = try parseBody(Input, a, body);
                var buffer: [253]u8 = undefined;
                replacement.?.domain = try a.dupe(u8, try domain.normalize(replacement.?.domain, &buffer));
                resource = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(replacement.?.action), replacement.?.domain });
            }
            var found = false;
            inline for (.{ "allow", "block" }) |which| {
                var names: std.ArrayList([]const u8) = .empty;
                const old = if (comptime eq(which, "allow")) doc.allows.domains else doc.blocks.domains;
                for (old) |name| {
                    const key = try std.fmt.allocPrint(a, which ++ ":{s}", .{name});
                    if (id) |wanted| if (eq(key, wanted)) {
                        found = true;
                        continue;
                    };
                    if (replacement != null and eq(key, resource.?)) return failure(a, 409, "DomainExists", self.revision);
                    try names.append(a, name);
                }
                if (replacement) |value| if (eq(@tagName(value.action), which)) try names.append(a, value.domain);
                if (comptime eq(which, "allow")) doc.allows.domains = names.items else doc.blocks.domains = names.items;
            }
            if (id != null and !found) return failure(a, 404, "DomainNotFound", self.revision);
        } else if (comptime eq(kind, "records")) {
            var replacement: ?Record = null;
            if (!delete) {
                replacement = try parseBody(Record, a, body);
                var buffer: [253]u8 = undefined;
                replacement.?.name = try a.dupe(u8, try domain.normalize(replacement.?.name, &buffer));
                resource = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(replacement.?.type), replacement.?.name });
            }
            var records: std.ArrayList(Record) = .empty;
            var found = false;
            for (doc.records) |record| {
                const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(record.type), record.name });
                if (id) |wanted| if (eq(key, wanted)) {
                    found = true;
                    continue;
                };
                if (replacement != null and eq(key, resource.?)) return failure(a, 409, "RecordExists", self.revision);
                try records.append(a, record);
            }
            if (id != null and !found) return failure(a, 404, "RecordNotFound", self.revision);
            if (replacement) |record| try records.append(a, record);
            doc.records = records.items;
        } else {
            const replacement: ?Source = if (delete) null else try parseBody(Source, a, body);
            if (replacement) |source| {
                resource = source.id;
                if (id) |wanted| if (!eq(wanted, source.id)) return failure(a, 400, "SourceIdImmutable", self.revision);
            }
            var sources: std.ArrayList(Source) = .empty;
            var found = false;
            for (doc.blocks.lists) |source| {
                if (id) |wanted| if (eq(source.id, wanted)) {
                    found = true;
                    continue;
                };
                if (replacement) |value| if (eq(source.id, value.id)) return failure(a, 409, "SourceExists", self.revision);
                try sources.append(a, source);
            }
            if (id != null and !found) return failure(a, 404, "SourceNotFound", self.revision);
            if (replacement) |source| try sources.append(a, source);
            doc.blocks.lists = sources.items;
        }
        return self.saveDocument(a, doc, resource);
    }
};

fn settingsView(doc: Document) Settings {
    return .{ .dns = doc.dns, .upstream = doc.upstream, .cache = doc.cache, .logging = doc.logging };
}
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn json(a: std.mem.Allocator, status: u16, value: anytype, revision: ?u64) !bridge.Response {
    return .{ .status = status, .body = try std.json.Stringify.valueAlloc(a, value, .{}), .revision = revision };
}
fn failure(a: std.mem.Allocator, status: u16, message: []const u8, revision: ?u64) !bridge.Response {
    const code: []const u8 = switch (status) {
        400 => "bad_request",
        404 => "not_found",
        405 => "method_not_allowed",
        409 => "conflict",
        412 => "precondition_failed",
        428 => "precondition_required",
        503 => "unavailable",
        else => "internal_error",
    };
    return json(a, status, .{ .@"error" = .{ .code = code, .message = message } }, revision);
}
fn parseBody(comptime T: type, a: std.mem.Allocator, body: []const u8) !T {
    const value = try std.json.parseFromSlice(std.json.Value, a, body, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer value.deinit();
    try strictShape(T, value.value);
    return (try std.json.parseFromSlice(T, a, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = false, .duplicate_field_behavior = .@"error" })).value;
}
fn strictShape(comptime T: type, value: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .int => if (value != .integer) {
            return error.InvalidJsonType;
        },
        .bool => if (value != .bool) {
            return error.InvalidJsonType;
        },
        .@"enum" => if (value != .string) {
            return error.InvalidJsonType;
        },
        .optional => |optional| if (value != .null) {
            try strictShape(optional.child, value);
        },
        .pointer => |pointer| {
            if (pointer.child == u8) {
                if (value != .string) return error.InvalidJsonType;
            } else {
                if (value != .array) return error.InvalidJsonType;
                for (value.array.items) |item| try strictShape(pointer.child, item);
            }
        },
        .@"struct" => |structure| {
            if (value != .object) return error.InvalidJsonType;
            inline for (structure.field_names, structure.field_types) |field_name, FieldType| if (value.object.get(field_name)) |child| try strictShape(FieldType, child);
        },
        else => {},
    }
}
fn sameApi(a: std.mem.Allocator, left: *const config.Config, right: *const config.Config) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    const l = try config.toDocument(allocator, left);
    const r = try config.toDocument(allocator, right);
    return eq(try std.json.Stringify.valueAlloc(allocator, l.api, .{}), try std.json.Stringify.valueAlloc(allocator, r.api, .{}));
}
fn decode(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%') {
            if (input.len - i < 3) return error.InvalidEncoding;
            const byte = try std.fmt.parseInt(u8, input[i + 1 ..][0..2], 16);
            if (byte == 0) return error.InvalidEncoding;
            try output.append(a, byte);
            i += 2;
        } else try output.append(a, if (input[i] == '+') ' ' else input[i]);
    }
    return output.items;
}
fn parameter(a: std.mem.Allocator, query: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, std.mem.trimStart(u8, query, "?"), '&');
    var result: ?[]const u8 = null;
    while (pairs.next()) |pair| {
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!eq(try decode(a, pair[0..split]), name)) continue;
        if (result != null) return error.DuplicateParameter;
        result = try decode(a, if (split == pair.len) "" else pair[split + 1 ..]);
    }
    return result;
}

test "typed resource JSON rejects coercions and ambiguous queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidJsonType, parseBody(Record, a,
        \\{"name":"home.test","type":"A","ttl":"60","addresses":["192.0.2.1"]}
    ));
    try std.testing.expectError(error.InvalidJsonType, parseBody(Record, a,
        \\{"name":"home.test","type":"A","ttl":1.5,"addresses":["192.0.2.1"]}
    ));
    try std.testing.expectError(error.DuplicateParameter, parameter(a, "limit=1&limit=2", "limit"));
    try std.testing.expectError(error.InvalidEncoding, decode(a, "bad%0"));
    try std.testing.expectError(error.InvalidEncoding, decode(a, "bad%00"));
    try std.testing.expectEqualStrings("block:home.test", try decode(a, "block%3Ahome.test"));
}

test "management policy matches record family and collections enforce revision cursors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var diagnostic: config.Diagnostic = .{};
    var settings = try config.parse(allocator,
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"records":[{"name":"HOME.test.","type":"A","addresses":["192.0.2.1"]}],"blocks":{"domains":["z.test","a.test"]},"allows":{"domains":["allow.test"]}}
    , ".", &diagnostic);
    defer settings.deinit();
    var state = try settings.prepareState(io, &diagnostic);
    defer state.deinit();
    state.records = settings.records;
    var mailbox: control.Mailbox = .{};
    defer mailbox.deinit(allocator);
    var worker = try Worker.init(allocator, &settings, &state, &mailbox);
    defer worker.deinit(io);
    var manager = try Manager.init(allocator, "not-used.json");
    defer manager.deinit();
    var next_generation: u64 = 1;
    var management: Management = .{ .allocator = allocator, .io = io, .manager = &manager, .settings = &settings, .state = &state, .worker = &worker, .mailbox = &mailbox, .next_generation = &next_generation };
    defer management.close();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var request: bridge.Request = .{ .method = "GET", .path = "/api/v1/policy/check", .query = "name=HOME.test.&type=A", .body = "", .if_match = null };
    const local = try management.handle(a, request);
    try std.testing.expect(std.mem.indexOf(u8, local.body, "\"reason\":\"local_record\"") != null);
    request.query = "name=home.test&type=AAAA";
    const other_family = try management.handle(a, request);
    try std.testing.expect(std.mem.indexOf(u8, other_family.body, "\"decision\":\"forward\"") != null);
    request.path = "/api/v1/domains";
    request.query = "limit=1";
    const first = try management.handle(a, request);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"next_cursor\":\"1:allow:allow.test\"") != null);
    request.query = "limit=1&after=1%3Aallow%3Aallow.test";
    const second = try management.handle(a, request);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"id\":\"block:a.test\"") != null);
    request.query = "after=0%3Aallow%3Aallow.test";
    try std.testing.expectEqual(@as(u16, 409), (try management.handle(a, request)).status);
    request.query = "limit=101";
    try std.testing.expectEqual(@as(u16, 400), (try management.handle(a, request)).status);
    request.path = "/api/v1/cache/entries";
    request.method = "DELETE";
    request.query = "";
    try std.testing.expectEqual(@as(u16, 428), (try management.handle(a, request)).status);
    request.if_match = "\"0\"";
    try std.testing.expectEqual(@as(u16, 412), (try management.handle(a, request)).status);
    request.if_match = "\"1\"";
    try std.testing.expectEqual(@as(u16, 200), (try management.handle(a, request)).status);
    try std.testing.expectEqual(@as(u64, 2), management.revision);
    request.method = "POST";
    request.path = "/api/v1/config/validate";
    request.if_match = null;
    request.body =
        \\{"schema_version":2,"api":{"enabled":false},"ui":{"enabled":false},"upstream":{"servers":[{"address":"127.0.0.1"}]},"blocks":{"lists":[{"id":"unread","source":{"kind":"file","value":"does-not-exist"},"format":"domains"}]}}
    ;
    try std.testing.expectEqual(@as(u16, 200), (try management.handle(a, request)).status);
    try state.lists.add(io, .{
        .id = "refresh",
        .enabled = false,
        .source = .{ .kind = .file, .value = "not-read" },
        .format = .domains,
    }, ".");
    request.path = "/api/v1/blocklists/refresh";
    request.method = "GET";
    request.body = "";
    // A valid source ID must not be hidden by the bulk-refresh action route.
    // Collection reads use the active document, so add the same definition.
    try settings.definitions.sources.append(allocator, try state.lists.sources.get("refresh").?.source.clone(allocator));
    try std.testing.expectEqual(@as(u16, 200), (try management.handle(a, request)).status);
    request.path = "/api/v1/blocklists/refresh/refresh";
    request.method = "POST";
    request.if_match = "\"2\"";
    try std.testing.expectEqual(@as(u16, 202), (try management.handle(a, request)).status);
    management.complete();
    try std.testing.expect(management.history[1].?.status == .succeeded);
    try management.stdin(.{ .refresh = @constCast("missing-source") });
    management.complete();
    try std.testing.expect(management.history[2].?.status == .failed);
    try std.testing.expectEqual(@as(u64, 4), management.history[2].?.result.?.revision);
}

test "restart-required HTTP updates preserve saved bytes before API and stdin save preparation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const original =
        \\{"schema_version":2,"api":{"key_file":"key"},"ui":{},"upstream":{"servers":[{"address":"127.0.0.1"}]}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = original });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", allocator);
    defer allocator.free(path);
    var manager = try Manager.init(allocator, path);
    defer manager.deinit();
    var diagnostic: config.Diagnostic = .{};
    var settings = try manager.load(io, &diagnostic);
    defer settings.deinit();
    // Rejection must happen before touching runtime state, worker, or mailbox.
    var owner: Management = undefined;
    owner.allocator = allocator;
    owner.io = io;
    owner.manager = &manager;
    owner.settings = &settings;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const active = try config.toDocument(arena.allocator(), &settings);
    for ([_]bool{ true, false }) |api_request| {
        for ([_]bool{ true, false }) |change_api| {
            var replacement = active;
            if (change_api) replacement.api.listen.port += 1 else replacement.ui.enabled = false;
            var job: Management.Job = .{
                .owner = &owner,
                .id = 1,
                .kind = .save,
                .api = api_request,
                .candidate = try config.fromDocument(allocator, &replacement, settings.base_dir, &diagnostic),
            };
            defer job.candidate.?.deinit();
            try std.testing.expectError(if (change_api) error.ApiRestartRequired else error.UiRestartRequired, job.prepare());
            try std.testing.expect(!job.saved);
            const saved = try tmp.dir.readFileAlloc(io, "config.json", allocator, .limited(config.max_file_size));
            defer allocator.free(saved);
            try std.testing.expectEqualStrings(original, saved);
            try std.testing.expect(settings.ui.enabled);
            try std.testing.expectEqual(@as(u16, 8080), settings.api.port);
        }
    }
}
