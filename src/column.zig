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

/// Identifies a primitive (non-wrapped) column type.
pub const TypeId = enum {
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Int8, Int16, Int32, Int64, Int128,
    Float32, Float64,
    String,
};

pub const Column = union(enum) {
    UInt8: []u8,
    UInt16: []u16,
    UInt32: []u32,
    UInt64: []u64,
    UInt128: []u128,
    Int8: []i8,
    Int16: []i16,
    Int32: []i32,
    Int64: []i64,
    Int128: []i128,
    Float32: []f32,
    Float64: []f64,
    String: [][]u8,
    /// Nullable(T) — boxed because Zig unions can't hold a recursive
    /// payload by value. Owns the mask and the inner column. Caller
    /// reads `n.mask[i] != 0` then `n.inner.<TypeTag>[i]` for the value.
    Nullable: *Nullable,
    /// Array(T). `offsets[i]` = cumulative element count after row i.
    /// Row i's elements are `inner[offsets[i-1]..offsets[i]]`
    /// (with offsets[-1] = 0). Inner column holds the flattened
    /// concatenation across all rows.
    Array: *Array,
    /// FixedString(N). Width in bytes is held alongside the flat data
    /// `data.len = num_rows * width`. Row i bytes: `data[i*width..][0..width]`.
    FixedString: FixedString,
    /// UUID — 16 bytes per row, big-endian network order. Caller
    /// interprets via `[16]u8` directly.
    UUID: [][16]u8,

    pub fn deinit(self: Column, allocator: std.mem.Allocator) void {
        switch (self) {
            .String => |rows| {
                for (rows) |row| allocator.free(row);
                allocator.free(rows);
            },
            .Nullable => |n| n.deinit(allocator),
            .Array => |a| a.deinit(allocator),
            .FixedString => |fs| allocator.free(fs.data),
            .UUID => |rows| allocator.free(rows),
            inline else => |slice| allocator.free(slice),
        }
    }

    pub fn len(self: Column) usize {
        return switch (self) {
            .Nullable => |n| n.mask.len,
            .Array => |a| a.offsets.len,
            .FixedString => |fs| if (fs.width == 0) 0 else fs.data.len / fs.width,
            inline else => |slice| slice.len,
        };
    }
};

pub const Nullable = struct {
    mask: []u8,
    inner: Column,

    pub fn deinit(self: *Nullable, allocator: std.mem.Allocator) void {
        allocator.free(self.mask);
        self.inner.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Array = struct {
    /// Cumulative end-offsets per row. Length == num_rows.
    offsets: []u64,
    inner: Column,

    pub fn deinit(self: *Array, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        self.inner.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const FixedString = struct {
    width: usize,
    data: []u8,
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
    if (eq(u8, type_name, "UInt32") or eq(u8, type_name, "IPv4")) return .UInt32;
    if (eq(u8, type_name, "UInt64")) return .UInt64;
    if (eq(u8, type_name, "UInt128")) return .UInt128;
    if (eq(u8, type_name, "Int8") or startsWith(u8, type_name, "Enum8")) return .Int8;
    if (eq(u8, type_name, "Int16") or startsWith(u8, type_name, "Enum16")) return .Int16;
    if (eq(u8, type_name, "Int32") or eq(u8, type_name, "Date32")) return .Int32;
    if (eq(u8, type_name, "Int64")) return .Int64;
    if (eq(u8, type_name, "Int128")) return .Int128;
    if (eq(u8, type_name, "Float32")) return .Float32;
    if (eq(u8, type_name, "Float64")) return .Float64;
    if (eq(u8, type_name, "String")) return .String;
    if (eq(u8, type_name, "Date")) return .UInt16;
    // DateTime64(N, ...) is u64 (millisecond/microsecond/nanosecond ticks).
    // DateTime(...) is u32 seconds-since-epoch.
    if (startsWith(u8, type_name, "DateTime64")) return .UInt64;
    if (startsWith(u8, type_name, "DateTime")) return .UInt32;
    // Decimal aliases: scaled int. Caller multiplies by 10^scale to
    // recover the rational value. Decimal128/256(S) → underlying int.
    if (startsWith(u8, type_name, "Decimal32")) return .Int32;
    if (startsWith(u8, type_name, "Decimal64")) return .Int64;
    if (startsWith(u8, type_name, "Decimal128")) return .Int128;
    if (startsWith(u8, type_name, "Decimal(")) {
        // Decimal(P, S): underlying int width determined by P.
        //   P <=  9 → Int32   (Decimal32)
        //   P <= 18 → Int64   (Decimal64)
        //   P <= 38 → Int128  (Decimal128)
        //   P <= 76 → Int256  (not yet supported; returns null)
        const inside = type_name[8..type_name.len - 1];
        const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return null;
        const p_str = std.mem.trim(u8, inside[0..comma], " ");
        const p = std.fmt.parseInt(u8, p_str, 10) catch return null;
        if (p <= 9) return .Int32;
        if (p <= 18) return .Int64;
        if (p <= 38) return .Int128;
        return null;
    }
    return null;
}

pub fn readColumn(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    num_rows: u64,
) !Column {
    if (extractNullableInner(type_name)) |inner_name| {
        const n_rows: usize = @intCast(num_rows);
        const ptr = try allocator.create(Nullable);
        errdefer allocator.destroy(ptr);
        const mask = try allocator.alloc(u8, n_rows);
        errdefer allocator.free(mask);
        try reader.readSliceAll(mask);
        ptr.* = .{
            .mask = mask,
            .inner = try readColumn(reader, allocator, inner_name, num_rows),
        };
        return .{ .Nullable = ptr };
    }
    if (extractArrayInner(type_name)) |inner_name| {
        const n_rows: usize = @intCast(num_rows);
        const ptr = try allocator.create(Array);
        errdefer allocator.destroy(ptr);
        const offsets = try allocator.alloc(u64, n_rows);
        errdefer allocator.free(offsets);
        try reader.readSliceAll(std.mem.sliceAsBytes(offsets));
        const total: u64 = if (n_rows == 0) 0 else offsets[n_rows - 1];
        ptr.* = .{
            .offsets = offsets,
            .inner = try readColumn(reader, allocator, inner_name, total),
        };
        return .{ .Array = ptr };
    }
    if (extractFixedStringWidth(type_name)) |width| {
        const total = @as(usize, @intCast(num_rows)) * width;
        const data = try allocator.alloc(u8, total);
        errdefer allocator.free(data);
        try reader.readSliceAll(data);
        return .{ .FixedString = .{ .width = width, .data = data } };
    }
    if (std.mem.eql(u8, type_name, "UUID")) {
        const n_rows: usize = @intCast(num_rows);
        const rows = try allocator.alloc([16]u8, n_rows);
        errdefer allocator.free(rows);
        try reader.readSliceAll(std.mem.sliceAsBytes(rows));
        return .{ .UUID = rows };
    }
    // IPv6 is canonically a 16-byte fixed-width column on the wire.
    if (std.mem.eql(u8, type_name, "IPv6")) {
        const total = @as(usize, @intCast(num_rows)) * 16;
        const data = try allocator.alloc(u8, total);
        errdefer allocator.free(data);
        try reader.readSliceAll(data);
        return .{ .FixedString = .{ .width = 16, .data = data } };
    }
    const tid = typeIdFromName(type_name) orelse return error.UnsupportedColumnType;
    const n: usize = @intCast(num_rows);
    return switch (tid) {
        .UInt8 => .{ .UInt8 = try readFixed(u8, reader, allocator, n) },
        .UInt16 => .{ .UInt16 = try readFixed(u16, reader, allocator, n) },
        .UInt32 => .{ .UInt32 = try readFixed(u32, reader, allocator, n) },
        .UInt64 => .{ .UInt64 = try readFixed(u64, reader, allocator, n) },
        .UInt128 => .{ .UInt128 = try readFixed(u128, reader, allocator, n) },
        .Int8 => .{ .Int8 = try readFixed(i8, reader, allocator, n) },
        .Int16 => .{ .Int16 = try readFixed(i16, reader, allocator, n) },
        .Int32 => .{ .Int32 = try readFixed(i32, reader, allocator, n) },
        .Int64 => .{ .Int64 = try readFixed(i64, reader, allocator, n) },
        .Int128 => .{ .Int128 = try readFixed(i128, reader, allocator, n) },
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

/// Write a Column to the wire in the same Native format the server
/// emits. Caller must have already written the column header (name +
/// type + has_custom_serialization byte) — this function writes only
/// the data payload. Symmetric to `readColumn`.
pub fn writeColumn(writer: *std.Io.Writer, col: Column) std.Io.Writer.Error!void {
    switch (col) {
        .String => |rows| {
            for (rows) |row| try wire.writeStringBinary(writer, row);
        },
        .Nullable => |n| {
            try writer.writeAll(n.mask);
            try writeColumn(writer, n.inner);
        },
        .Array => |a| {
            try writer.writeAll(std.mem.sliceAsBytes(a.offsets));
            try writeColumn(writer, a.inner);
        },
        .FixedString => |fs| try writer.writeAll(fs.data),
        .UUID => |rows| try writer.writeAll(std.mem.sliceAsBytes(rows)),
        inline else => |slice| try writer.writeAll(std.mem.sliceAsBytes(slice)),
    }
}

pub fn extractArrayInner(type_name: []const u8) ?[]const u8 {
    const prefix = "Array(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

pub fn extractFixedStringWidth(type_name: []const u8) ?usize {
    const prefix = "FixedString(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    const inside = type_name[prefix.len .. type_name.len - 1];
    return std.fmt.parseInt(usize, inside, 10) catch null;
}

/// Returns the inner type name if `type_name` matches "Nullable(...)",
/// otherwise null. Trims surrounding whitespace conservatively. Does
/// not validate the inner string — `readColumn` recurses and that
/// recursion will reject if the inner is itself unsupported.
pub fn extractNullableInner(type_name: []const u8) ?[]const u8 {
    const prefix = "Nullable(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

/// Resolve a TypeId back to its canonical wire type name. Round-trip
/// is lossy for type-aliases (Date -> UInt16 -> "UInt16"; DateTime ->
/// UInt32 -> "UInt32") — callers needing the original type name (for
/// INSERTs into a Date column) must pass the type string explicitly
/// via `InsertColumn.type_name`.
pub fn canonicalTypeName(tid: TypeId) []const u8 {
    return switch (tid) {
        .UInt8 => "UInt8",
        .UInt16 => "UInt16",
        .UInt32 => "UInt32",
        .UInt64 => "UInt64",
        .Int8 => "Int8",
        .Int16 => "Int16",
        .Int32 => "Int32",
        .Int64 => "Int64",
        .Float32 => "Float32",
        .Float64 => "Float64",
        .String => "String",
    };
}

test "writeColumn UInt32 round-trips through readColumn" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const original = [_]u32{ 7, 13, 0xFFFFFFFF };
    const col_in: Column = .{ .UInt32 = @constCast(&original) };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "UInt32", 3);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &original, col_out.UInt32);
}

test "extractNullableInner peels Nullable wrapper" {
    try testing.expectEqualStrings("UInt32", extractNullableInner("Nullable(UInt32)").?);
    try testing.expectEqualStrings("String", extractNullableInner("Nullable(String)").?);
    try testing.expectEqual(@as(?[]const u8, null), extractNullableInner("UInt32"));
    try testing.expectEqual(@as(?[]const u8, null), extractNullableInner("Array(UInt8)"));
}

test "Array(UInt32) round-trips" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Three rows: [10, 20], [], [30]
    var offsets = [_]u64{ 2, 2, 3 };
    var values = [_]u32{ 10, 20, 30 };
    var array_box: Array = .{
        .offsets = &offsets,
        .inner = .{ .UInt32 = &values },
    };
    const col_in: Column = .{ .Array = &array_box };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "Array(UInt32)", 3);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &offsets, col_out.Array.offsets);
    try testing.expectEqualSlices(u32, &values, col_out.Array.inner.UInt32);
    try testing.expectEqual(@as(usize, 3), col_out.len());
}

test "FixedString(4) round-trips" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var data = [_]u8{ 'a','b','c','d', 'e','f','g','h', 'i','j','k','l' };
    const col_in: Column = .{ .FixedString = .{ .width = 4, .data = &data } };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "FixedString(4)", 3);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), col_out.FixedString.width);
    try testing.expectEqualSlices(u8, &data, col_out.FixedString.data);
    try testing.expectEqual(@as(usize, 3), col_out.len());
}

test "UUID round-trips" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rows: [2][16]u8 = .{ .{1}**16, .{2,2,2,2, 2,2,2,2, 2,2,2,2, 2,2,2,2} };
    const col_in: Column = .{ .UUID = &rows };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "UUID", 2);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &rows[0], &col_out.UUID[0]);
    try testing.expectEqualSlices(u8, &rows[1], &col_out.UUID[1]);
}

test "extractArrayInner / extractFixedStringWidth" {
    try testing.expectEqualStrings("UInt32", extractArrayInner("Array(UInt32)").?);
    try testing.expectEqualStrings("Nullable(Int8)", extractArrayInner("Array(Nullable(Int8))").?);
    try testing.expectEqual(@as(?[]const u8, null), extractArrayInner("UInt32"));
    try testing.expectEqual(@as(?usize, 8), extractFixedStringWidth("FixedString(8)"));
    try testing.expectEqual(@as(?usize, 256), extractFixedStringWidth("FixedString(256)"));
    try testing.expectEqual(@as(?usize, null), extractFixedStringWidth("String"));
}

test "Nullable(UInt32) round-trips with mixed null/non-null" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 4 rows: 100, NULL, 300, 400.
    var mask = [_]u8{ 0, 1, 0, 0 };
    var values = [_]u32{ 100, 0xDEADBEEF, 300, 400 }; // value at idx 1 is placeholder
    var inner_box: Nullable = .{
        .mask = &mask,
        .inner = .{ .UInt32 = &values },
    };
    const col_in: Column = .{ .Nullable = &inner_box };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "Nullable(UInt32)", 4);
    defer col_out.deinit(testing.allocator);
    const n = col_out.Nullable;
    try testing.expectEqualSlices(u8, &mask, n.mask);
    try testing.expectEqualSlices(u32, &values, n.inner.UInt32);
    try testing.expectEqual(@as(usize, 4), col_out.len());
}

test "writeColumn String round-trips" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rows = [_][]u8{ @constCast("a"), @constCast("bb"), @constCast("") };
    const col_in: Column = .{ .String = &rows };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "String", 3);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualStrings("a", col_out.String[0]);
    try testing.expectEqualStrings("bb", col_out.String[1]);
    try testing.expectEqualStrings("", col_out.String[2]);
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
    // Decimal/Map/Tuple/IPv4/IPv6 — pick one that v0.16.0 still doesn't
    // decode. Update when support lands.
    try testing.expectError(error.UnsupportedColumnType, readColumn(&r, testing.allocator, "Decimal(18, 4)", 0));
}
