//! Native ClickHouse query parameters.
//!
//! SQL uses `{name:Type}` placeholders and this module sends the values
//! through the Query packet's WITH_PARAMETERS section. Values are not
//! interpolated into SQL text.

const std = @import("std");
const wire = @import("wire.zig");
const settings = @import("settings.zig");
const varint = @import("varint.zig");

const wire_prefix = "param_";
const parameter_flags: settings.Flags = .{ .custom = true };

pub const Error = error{
    InvalidParameterName,
    ParameterValueTooLarge,
};

pub const Map = std.StringHashMapUnmanaged([]const u8);
pub const ParameterMap = Parameters;

pub const Parameters = struct {
    map: Map = .empty,

    pub fn deinit(self: *Parameters, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(allocator);
        self.* = .{};
    }

    pub fn putRaw(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try validateName(name);
        if (value.len > wire.MAX_DEFAULT_STRING) return error.ParameterValueTooLarge;
        if (self.map.getEntry(name)) |entry| {
            const val = try allocator.dupe(u8, value);
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = val;
            return;
        }
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, value);
        errdefer allocator.free(val);
        try self.map.putNoClobber(allocator, key, val);
    }

    pub fn putString(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const text = try quoteString(allocator, value);
        defer allocator.free(text);
        try self.putRaw(allocator, name, text);
    }

    pub fn putBool(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: bool) !void {
        try self.putString(allocator, name, if (value) "1" else "0");
    }

    pub fn putInt(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(text);
        try self.putString(allocator, name, text);
    }

    pub fn putUInt(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(text);
        try self.putString(allocator, name, text);
    }

    pub fn putFloat(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
        defer allocator.free(text);
        try self.putString(allocator, name, text);
    }

    pub fn putDate(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, yyyy_mm_dd: []const u8) !void {
        try self.putString(allocator, name, yyyy_mm_dd);
    }

    pub fn putDateTime(self: *Parameters, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try self.putString(allocator, name, value);
    }
};

fn quoteString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |c| switch (c) {
        '\\' => try out.writer.writeAll("\\\\"),
        '\'' => try out.writer.writeAll("\\'"),
        '\n' => try out.writer.writeAll("\\n"),
        '\r' => try out.writer.writeAll("\\r"),
        '\t' => try out.writer.writeAll("\\t"),
        else => try out.writer.writeByte(c),
    };
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidParameterName;
    if (!isIdentStart(name[0])) return error.InvalidParameterName;
    for (name[1..]) |c| {
        if (!isIdentContinue(c)) return error.InvalidParameterName;
    }
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn writeParameters(writer: *std.Io.Writer, params: ?*const Parameters) std.Io.Writer.Error!void {
    if (params) |p| {
        var it = p.map.iterator();
        while (it.next()) |entry| {
            try wire.writeStringBinary(writer, entry.key_ptr.*);
            try varint.writeVarUInt(writer, @bitCast(parameter_flags));
            try wire.writeStringBinary(writer, entry.value_ptr.*);
        }
    }
    try wire.writeStringBinary(writer, "");
}

pub fn writeParameterSettingsEntries(writer: *std.Io.Writer, params: ?*const Parameters) std.Io.Writer.Error!void {
    if (params) |p| {
        var it = p.map.iterator();
        while (it.next()) |entry| {
            try varint.writeVarUInt(writer, @intCast(wire_prefix.len + entry.key_ptr.*.len));
            try writer.writeAll(wire_prefix);
            try writer.writeAll(entry.key_ptr.*);
            try varint.writeVarUInt(writer, @bitCast(parameter_flags));
            try wire.writeStringBinary(writer, entry.value_ptr.*);
        }
    }
}

const testing = std.testing;

test "writeParameters on null emits only sentinel" {
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeParameters(&w, null);
    try testing.expectEqual(@as(usize, 1), w.buffered().len);
    try testing.expectEqual(@as(u8, 0), w.buffered()[0]);
}

test "one parameter serializes as settings triple plus sentinel" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);
    try params.putUInt(testing.allocator, "n", @as(u64, 41));

    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeParameters(&w, &params);
    const out = w.buffered();
    try testing.expectEqual(@as(u8, 1), out[0]);
    try testing.expectEqual(@as(u8, 'n'), out[1]);
    try testing.expectEqual(@as(u8, 2), out[2]);
    try testing.expectEqual(@as(u8, 4), out[3]);
    try testing.expectEqualStrings("'41'", out[4..8]);
    try testing.expectEqual(@as(u8, 0), out[8]);
}

test "parameter settings entries use ClickHouse param_ prefix" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);
    try params.putUInt(testing.allocator, "n", @as(u64, 41));

    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeParameterSettingsEntries(&w, &params);
    const out = w.buffered();
    try testing.expectEqual(@as(u8, 7), out[0]);
    try testing.expectEqualStrings("param_n", out[1..8]);
    try testing.expectEqual(@as(u8, 2), out[8]);
    try testing.expectEqual(@as(u8, 4), out[9]);
    try testing.expectEqualStrings("'41'", out[10..14]);
}

test "typed helpers format scalar values" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);
    try params.putInt(testing.allocator, "i", @as(i32, -7));
    try params.putUInt(testing.allocator, "u", @as(u64, 9));
    try params.putFloat(testing.allocator, "f", @as(f64, 1.5));
    try params.putBool(testing.allocator, "b", true);
    try params.putString(testing.allocator, "s", "clickzig");
    try params.putDate(testing.allocator, "d", "2026-05-07");
    try params.putDateTime(testing.allocator, "dt", "2026-05-07 12:34:56");

    try testing.expectEqualStrings("'-7'", params.map.get("i").?);
    try testing.expectEqualStrings("'9'", params.map.get("u").?);
    try testing.expectEqualStrings("'1.5'", params.map.get("f").?);
    try testing.expectEqualStrings("'1'", params.map.get("b").?);
    try testing.expectEqualStrings("'clickzig'", params.map.get("s").?);
    try testing.expectEqualStrings("'2026-05-07'", params.map.get("d").?);
    try testing.expectEqualStrings("'2026-05-07 12:34:56'", params.map.get("dt").?);
}

test "string helper quotes field dumps safely" {
    const quoted = try quoteString(testing.allocator, "a'b\\c\n");
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("'a\\'b\\\\c\\n'", quoted);
}

test "invalid parameter names are rejected" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "1x", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "x-y", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "x;DROP", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "name with space", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "na.me", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "na/me", "x"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "ümlaut", "x"));
}

test "duplicate parameter names explicitly overwrite old value" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);

    try params.putString(testing.allocator, "name", "old");
    try params.putString(testing.allocator, "name", "new");

    try testing.expectEqual(@as(u32, 1), params.map.count());
    try testing.expectEqualStrings("'new'", params.map.get("name").?);
}

test "oversized parameter value is rejected before storing" {
    var params: Parameters = .{};
    defer params.deinit(testing.allocator);

    const value = try testing.allocator.alloc(u8, wire.MAX_DEFAULT_STRING + 1);
    defer testing.allocator.free(value);
    @memset(value, 'x');

    try testing.expectError(error.ParameterValueTooLarge, params.putRaw(testing.allocator, "too_big", value));
    try testing.expectEqual(@as(u32, 0), params.map.count());
}
