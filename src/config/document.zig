const std = @import("std");
const config = @import("config.zig");
const Source = @import("../blocklist/source.zig").Source;

/// JSON-shaped editable data. A parsed document owns its strings and arrays;
/// constructed documents may borrow data until converted with fromDocument.
pub const Document = struct {
    schema_version: u32,
    dns: struct {
        listen: struct {
            address: []const u8 = "127.0.0.1",
            port: u16 = 53,
        } = .{},
    } = .{},
    upstream: struct {
        servers: []const struct {
            address: []const u8,
            port: u16 = 53,
        },
        timeout_ms: u32 = 3000,
    },
    cache: struct {
        capacity: usize = 4096,
    } = .{},
    logging: struct {
        level: std.log.Level = .info,
    } = .{},
    blocks: struct {
        lists: []const Source = &.{},
        domains: []const []const u8 = &.{},
    } = .{},
    allows: struct {
        domains: []const []const u8 = &.{},
    } = .{},
};

/// Decode without borrowing the input. Semantic validation belongs to
/// config.fromDocument, including for documents constructed directly in Zig.
pub fn parse(allocator: std.mem.Allocator, contents: []const u8, diagnostic: *config.Diagnostic) !std.json.Parsed(Document) {
    diagnostic.* = .{};
    if (contents.len > config.max_file_size) {
        diagnostic.set("configuration file exceeds the 1 MiB limit", .{});
        return error.FileTooLarge;
    }

    var scanner = std.json.Scanner.initCompleteInput(allocator, contents);
    defer scanner.deinit();
    var location: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&location);
    var contract: Contract = .{ .scanner = &scanner, .allocator = allocator, .diagnostic = diagnostic };
    contract.check(Document, "") catch |err| {
        if (err == error.OutOfMemory or err == error.InvalidConfig) return err;
        diagnostic.set("JSON at line {d}, column {d}: {s}", .{ location.getLine(), location.getColumn(), @errorName(err) });
        return error.InvalidJson;
    };
    const end = scanner.next() catch |err| {
        if (err == error.OutOfMemory) return err;
        diagnostic.set("JSON at line {d}, column {d}: {s}", .{ location.getLine(), location.getColumn(), @errorName(err) });
        return error.InvalidJson;
    };
    if (end != .end_of_document) {
        diagnostic.set("JSON: unexpected trailing content", .{});
        return error.InvalidJson;
    }

    var typed_scanner = std.json.Scanner.initCompleteInput(allocator, contents);
    defer typed_scanner.deinit();
    location = .{};
    typed_scanner.enableDiagnostics(&location);
    return std.json.parseFromTokenSource(Document, allocator, &typed_scanner, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |err| {
        diagnostic.set("JSON at line {d}, column {d}: {s}", .{ location.getLine(), location.getColumn(), @errorName(err) });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SyntaxError, error.UnexpectedEndOfInput, error.DuplicateField => error.InvalidJson,
            else => error.InvalidConfig,
        };
    };
}

/// Only closes std.json's coercion gaps. The document type supplies field names
/// and shapes; the standard decoder still handles structural validation,
/// required/unknown/duplicate fields, enum membership, and integer ranges.
/// No values are retained, and only escaped object keys need string allocation.
const Contract = struct {
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    diagnostic: *config.Diagnostic,

    fn check(self: *Contract, comptime T: type, path: []const u8) anyerror!void {
        const token_type = try self.scanner.peekNextTokenType();
        switch (token_type) {
            .object_end, .array_end, .end_of_document => return error.UnexpectedEndOfInput,
            else => {},
        }
        switch (@typeInfo(T)) {
            .int => {
                if (token_type != .number) return self.invalid(path, "expected an integer JSON number");
                const token = try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
                defer self.freeToken(token);
                const number = switch (token) {
                    .number, .allocated_number => |text| text,
                    else => unreachable,
                };
                for (number) |byte| {
                    if (byte < '0' or byte > '9') return self.invalid(path, "expected an unsigned integer without fractions or exponents");
                }
            },
            .@"enum" => try self.string(path),
            .optional => |optional| try self.check(optional.child, path),
            .pointer => |pointer| {
                if (pointer.child == u8) return self.string(path);
                if (token_type != .array_begin) return self.scanner.skipValue();
                _ = try self.scanner.next();
                var index: usize = 0;
                while (try self.scanner.peekNextTokenType() != .array_end) : (index += 1) {
                    var buffer: [256]u8 = undefined;
                    const child_path = try std.fmt.bufPrint(&buffer, "{s}[{d}]", .{ path, index });
                    try self.check(pointer.child, child_path);
                }
                _ = try self.scanner.next();
            },
            .@"struct" => |structure| {
                if (token_type != .object_begin) return self.scanner.skipValue();
                _ = try self.scanner.next();
                while (try self.scanner.peekNextTokenType() != .object_end) {
                    const token = try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
                    defer self.freeToken(token);
                    const key = switch (token) {
                        .string, .allocated_string => |text| text,
                        else => return error.SyntaxError,
                    };
                    inline for (structure.fields) |field| {
                        if (std.mem.eql(u8, key, field.name)) {
                            var buffer: [256]u8 = undefined;
                            const child_path = try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ path, if (path.len == 0) "" else ".", field.name });
                            try self.check(field.type, child_path);
                            break;
                        }
                    } else try self.scanner.skipValue();
                }
                _ = try self.scanner.next();
            },
            else => try self.scanner.skipValue(),
        }
    }

    fn string(self: *Contract, path: []const u8) !void {
        if (try self.scanner.peekNextTokenType() != .string) return self.invalid(path, "expected a JSON string");
        try self.scanner.skipValue();
    }

    fn invalid(self: *Contract, path: []const u8, message: []const u8) error{InvalidConfig} {
        self.diagnostic.set("{s}: {s}", .{ path, message });
        return error.InvalidConfig;
    }

    fn freeToken(self: *Contract, token: std.json.Token) void {
        switch (token) {
            .allocated_string, .allocated_number => |text| self.allocator.free(text),
            else => {},
        }
    }
};
