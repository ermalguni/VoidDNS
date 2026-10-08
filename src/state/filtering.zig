const std = @import("std");
const State = @import("state.zig").State;
const Source = @import("../blocklist/source.zig").Source;

/// Builds owned RAM filtering state from the already validated config root.
/// Relative sources are anchored to the configuration file's directory.
pub fn parse(allocator: std.mem.Allocator, io: std.Io, root: std.json.ObjectMap, base_dir: []const u8) !State {
    var state = State.init(allocator);
    errdefer state.deinit();
    if (root.get("blocks")) |value| {
        const blocks = try object(value, &.{ "lists", "domains" });
        if (blocks.get("domains")) |domains| {
            for (try array(domains)) |domain| try state.domains.block(try string(domain));
        }
        if (blocks.get("lists")) |lists| {
            for (try array(lists)) |item| {
                const fields = try object(item, &.{ "id", "name", "enabled", "source", "format" });
                const source_fields = try object(try required(fields, "source"), &.{ "kind", "value" });
                const source: Source = .{
                    .id = try string(try required(fields, "id")),
                    .name = if (fields.get("name")) |name| try string(name) else null,
                    .enabled = if (fields.get("enabled")) |enabled| try boolean(enabled) else true,
                    .source = .{
                        .kind = std.meta.stringToEnum(@FieldType(@FieldType(Source, "source"), "kind"), try string(try required(source_fields, "kind"))) orelse return error.InvalidSourceKind,
                        .value = try string(try required(source_fields, "value")),
                    },
                    .format = std.meta.stringToEnum(@FieldType(Source, "format"), try string(try required(fields, "format"))) orelse return error.InvalidListFormat,
                };
                state.lists.add(io, source, base_dir) catch |err| {
                    // JSON escaping prevents operator-controlled metadata injecting log lines.
                    std.log.err("blocklist id={f} name={f}: {s}", .{
                        std.json.fmt(source.id, .{}), std.json.fmt(source.name, .{}), @errorName(err),
                    });
                    return err;
                };
            }
        }
    }
    if (root.get("allows")) |value| {
        const allows = try object(value, &.{"domains"});
        if (allows.get("domains")) |domains| {
            for (try array(domains)) |domain| try state.domains.allow(try string(domain));
        }
    }
    return state;
}

fn object(value: std.json.Value, allowed: []const []const u8) !std.json.ObjectMap {
    if (value != .object) return error.ExpectedStateObject;
    for (value.object.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else return error.UnknownStateField;
    }
    return value.object;
}

fn required(fields: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return fields.get(key) orelse error.MissingStateField;
}

fn array(value: std.json.Value) ![]const std.json.Value {
    if (value != .array) return error.ExpectedStateArray;
    return value.array.items;
}

fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.ExpectedStateString;
    return value.string;
}

fn boolean(value: std.json.Value) !bool {
    if (value != .bool) return error.ExpectedStateBoolean;
    return value.bool;
}
