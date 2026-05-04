//! Typed column storage for decoded result blocks.
//!
//! ClickHouse Native format writes fixed-size numeric columns as
//! tightly-packed little-endian bytes (count is implicit from the
//! Block's num_rows), and String columns as a sequence of varint(len)
//! + bytes per row. We mirror that on the read side here. Unsupported
//! type names surface as `error.UnsupportedColumnType` so downstream
//! type coverage can grow incrementally without breaking known callers.

const std = @import("std");
const wire = @import("wire.zig");
const varint = @import("varint.zig");

pub const TypeId = enum {
    UInt8, UInt16, UInt32, UInt64,
    Int8, Int16, Int32, Int64,
    Float32, Float64,
    String,
};

pub const Column = union(TypeId) {
    UInt8: []u8,
    UInt16: []u16,
    UInt32: []u32,
    UInt64: []u64,
    Int8: []i8,
    Int16: []i16,
    Int32: []i32,
    Int64: []i64,
    Float32: []f32,
    Float64: []f64,
    /// Each entry owned independently (one alloc for the slice-of-slices
    /// plus per-row allocs for the bytes). Callers freeing a Column must
    /// walk the inner slice for `String`.
    String: [][]u8,

    pub fn deinit(self: Column, allocator: std.mem.Allocator) void {
        switch (self) {
            .String => |rows| {
                for (rows) |row| allocator.free(row);
                allocator.free(rows);
            },
            inline else => |slice| allocator.free(slice),
        }
    }

    pub fn len(self: Column) usize {
        return switch (self) {
            inline else => |slice| slice.len,
        };
    }
};

pub const Error = error{
    UnsupportedColumnType,
};

/// Map a ClickHouse type-name string to a TypeId. Handles both bare
/// names ("UInt32", "Date") and parameterised forms ("DateTime('UTC')",
/// "DateTime64(3, 'UTC')") via prefix match. Returns null for types
/// we don't yet decode (Array, Tuple, Map, Nullable, LowCardinality,
/// Decimal, FixedString, IPv4/IPv6, Enum16, etc.).
pub fn typeIdFromName(type_name: []const u8) ?TypeId {
    const eq = std.mem.eql;
    const startsWith = std.mem.startsWith;
    if (eq(u8, type_name, "UInt8") or eq(u8, type_name, "Bool")) return .UInt8;
    if (eq(u8, type_name, "UInt16")) return .UInt16;
    if (eq(u8, type_name, "UInt32")) return .UInt32;
    if (eq(u8, type_name, "UInt64")) return .UInt64;
    if (eq(u8, type_name, "Int8") or startsWith(u8, type_name, "Enum8")) return .Int8;
    if (eq(u8, type_name, "Int16") or startsWith(u8, type_name, "Enum16")) return .Int16;
    if (eq(u8, type_name, "Int32") or eq(u8, type_name, "Date32")) return .Int32;
    if (eq(u8, type_name, "Int64")) return .Int64;
    if (eq(u8, type_name, "Float32")) return .Float32;
    if (eq(u8, type_name, "Float64")) return .Float64;
    if (eq(u8, type_name, "String")) return .String;
    if (eq(u8, type_name, "Date")) return .UInt16;
    // DateTime64(N, ...) is u64 (millisecond/microsecond/nanosecond ticks).
    // DateTime(...) is u32 seconds-since-epoch.
    if (startsWith(u8, type_name, "DateTime64")) return .UInt64;
    if (startsWith(u8, type_name, "DateTime")) return .UInt32;
    return null;
}

pub fn readColumn(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    num_rows: u64,
) !Column {
    const tid = typeIdFromName(type_name) orelse return error.UnsupportedColumnType;
    const n: usize = @intCast(num_rows);
    return switch (tid) {
        .UInt8 => .{ .UInt8 = try readFixed(u8, reader, allocator, n) },
        .UInt16 => .{ .UInt16 = try readFixed(u16, reader, allocator, n) },
        .UInt32 => .{ .UInt32 = try readFixed(u32, reader, allocator, n) },
        .UInt64 => .{ .UInt64 = try readFixed(u64, reader, allocator, n) },
        .Int8 => .{ .Int8 = try readFixed(i8, reader, allocator, n) },
        .Int16 => .{ .Int16 = try readFixed(i16, reader, allocator, n) },
        .Int32 => .{ .Int32 = try readFixed(i32, reader, allocator, n) },
        .Int64 => .{ .Int64 = try readFixed(i64, reader, allocator, n) },
        .Float32 => .{ .Float32 = try readFixed(f32, reader, allocator, n) },
        .Float64 => .{ .Float64 = try readFixed(f64, reader, allocator, n) },
        .String => blk: {
            const rows = try allocator.alloc([]u8, n);
            errdefer allocator.free(rows);
            var i: usize = 0;
            errdefer for (rows[0..i]) |r| allocator.free(r);
            while (i < n) : (i += 1) {
                const len_v = try varint.readVarUInt(reader, u64);
                rows[i] = try reader.readAlloc(allocator, @intCast(len_v));
            }
            break :blk .{ .String = rows };
        },
    };
}

/// Read `n` fixed-size little-endian values back-to-back. Assumes host
/// endianness == little-endian (x86_64, aarch64); a big-endian host
/// would need byte-swapping after the read.
fn readFixed(comptime T: type, reader: *std.Io.Reader, allocator: std.mem.Allocator, n: usize) ![]T {
    const slice = try allocator.alloc(T, n);
    errdefer allocator.free(slice);
    try reader.readSliceAll(std.mem.sliceAsBytes(slice));
    return slice;
}

const testing = std.testing;

test "typeIdFromName resolves known primitives" {
    try testing.expectEqual(TypeId.UInt8, typeIdFromName("UInt8").?);
    try testing.expectEqual(TypeId.String, typeIdFromName("String").?);
    try testing.expectEqual(TypeId.Float64, typeIdFromName("Float64").?);
    try testing.expectEqual(@as(?TypeId, null), typeIdFromName("Nullable(UInt8)"));
}

test "readColumn UInt32 round-trips" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u32, 256, .little);
    try w.writeInt(u32, 0xDEADBEEF, .little);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, testing.allocator, "UInt32", 3);
    defer col.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), col.len());
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 256, 0xDEADBEEF }, col.UInt32);
}

test "readColumn String round-trips multibyte rows" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try wire.writeStringBinary(&w, "hello");
    try wire.writeStringBinary(&w, "");
    try wire.writeStringBinary(&w, "héllo");

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, testing.allocator, "String", 3);
    defer col.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", col.String[0]);
    try testing.expectEqualStrings("", col.String[1]);
    try testing.expectEqualStrings("héllo", col.String[2]);
}

test "readColumn rejects unknown type" {
    var r: std.Io.Reader = .fixed(&[_]u8{});
    try testing.expectError(error.UnsupportedColumnType, readColumn(&r, testing.allocator, "Nullable(Int32)", 0));
}
