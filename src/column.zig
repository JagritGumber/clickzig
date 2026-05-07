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

/// Defensive read-side caps for server-controlled block payloads.
/// ClickHouse normally ships result blocks orders of magnitude smaller
/// than these; the values are intentionally high enough for analytical
/// use while preventing hostile length prefixes from becoming allocation
/// requests in the GiB/TiB range.
pub const MAX_COLUMN_ROWS: u64 = 10_000_000;
pub const MAX_STRING_VALUE_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_COLUMN_BYTES: usize = 1024 * 1024 * 1024;

/// Identifies a primitive (non-wrapped) column type.
pub const TypeId = enum {
    UInt8, UInt16, UInt32, UInt64, UInt128, UInt256,
    Int8, Int16, Int32, Int64, Int128, Int256,
    Float32, Float64,
    String,
};

pub const Column = union(enum) {
    UInt8: []u8,
    UInt16: []u16,
    UInt32: []u32,
    UInt64: []u64,
    UInt128: []u128,
    UInt256: []u256,
    Int8: []i8,
    Int16: []i16,
    Int32: []i32,
    Int64: []i64,
    Int128: []i128,
    Int256: []i256,
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
    /// Tuple(T1, T2, ...). Each element column has the same row-count
    /// as the parent block. Wire format: N inner columns concatenated
    /// (NO per-row tag, NO offsets — the row-count is shared).
    Tuple: *Tuple,
    /// Map(K, V). Wire format identical to Array(Tuple(K, V)): a
    /// cumulative offset table followed by interleaved key/value
    /// columns of total `offsets[N-1]` length each.
    Map: *Map,
    /// JSON values carried through Native string serialization. Each row
    /// is the raw JSON text for the value.
    JSON: [][]u8,
    /// Dynamic values preserve row discriminators and the nested columns
    /// for concrete types present in the block.
    Dynamic: *Dynamic,

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
            .Tuple => |t| t.deinit(allocator),
            .Map => |m| m.deinit(allocator),
            .JSON => |rows| {
                for (rows) |row| allocator.free(row);
                allocator.free(rows);
            },
            .Dynamic => |d| d.deinit(allocator),
            inline else => |slice| allocator.free(slice),
        }
    }

    pub fn len(self: Column) usize {
        return switch (self) {
            .Nullable => |n| n.mask.len,
            .Array => |a| a.offsets.len,
            .FixedString => |fs| if (fs.width == 0) 0 else fs.data.len / fs.width,
            .Tuple => |t| t.row_count,
            .Map => |m| m.offsets.len,
            .JSON => |rows| rows.len,
            .Dynamic => |d| d.discriminators.len,
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

pub const Tuple = struct {
    /// Number of rows shared across every element column.
    row_count: u64,
    /// One Column per tuple element. Owned.
    elements: []Column,

    pub fn deinit(self: *Tuple, allocator: std.mem.Allocator) void {
        for (self.elements) |e| e.deinit(allocator);
        allocator.free(self.elements);
        allocator.destroy(self);
    }
};

pub const Map = struct {
    /// Cumulative end-offsets per outer row. Length == num_rows.
    offsets: []u64,
    /// Flattened keys; length == offsets[N-1].
    keys: Column,
    /// Flattened values; length == offsets[N-1].
    values: Column,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        self.keys.deinit(allocator);
        self.values.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Dynamic = struct {
    type_names: [][]u8,
    discriminators: []u8,
    values: []Column,

    pub fn deinit(self: *Dynamic, allocator: std.mem.Allocator) void {
        for (self.type_names) |name| allocator.free(name);
        allocator.free(self.type_names);
        allocator.free(self.discriminators);
        for (self.values) |value| value.deinit(allocator);
        allocator.free(self.values);
        allocator.destroy(self);
    }
};

pub const Error = error{
    UnsupportedColumnType,
    ColumnTooLarge,
    StringValueTooLarge,
    InvalidArrayOffsets,
    /// Wire-format violation specific to LowCardinality: bad version,
    /// missing dictionary, malformed serialization_type, out-of-range
    /// index, or unknown index integer width. Distinct from
    /// `UnsupportedColumnType` so production logs can disambiguate
    /// "type we don't decode" from "server sent garbage we can't trust."
    LowCardinalityCorruptFrame,
    /// User passed an `InsertColumn` whose `data` union tag does not
    /// match the leaf type implied by `type_name`. Catches the common
    /// mistake of declaring `LowCardinality(String)` but handing in a
    /// `.{ .UInt32 = ... }` column — without this check the server
    /// rejects the wire payload AFTER it lands and the connection ends
    /// up in `.broken` state with an opaque "wrong format" error.
    InsertColumnTypeMismatch,
    CustomSerializationUnsupported,
    CustomSerializationTooLarge,
};

/// LowCardinality(T) on-wire constants. Mirrors upstream
/// `SerializationLowCardinality.cpp`. The serialization-version prefix
/// is written by upstream `serializeBinaryBulkStatePrefix`; the per-block
/// `serialization_type` packs the index integer width in the low byte
/// (0=UInt8 ... 3=UInt64) and three feature bits.
const LC_KEY_VERSION: u64 = 1;
const LC_INDEX_TYPE_MASK: u64 = 0xff;
const LC_INDEX_UINT8: u64 = 0;
const LC_INDEX_UINT16: u64 = 1;
const LC_INDEX_UINT32: u64 = 2;
const LC_INDEX_UINT64: u64 = 3;
const LC_NEED_GLOBAL_DICT_BIT: u64 = 1 << 8;
const LC_HAS_ADDITIONAL_KEYS_BIT: u64 = 1 << 9;
const LC_NEED_UPDATE_DICT_BIT: u64 = 1 << 10;

/// Map a ClickHouse type-name string to a TypeId. Handles both bare
/// names ("UInt32", "Date") and parameterised forms ("DateTime('UTC')",
/// "DateTime64(3, 'UTC')") via prefix match. Returns null for parametric
/// composite types (Array, Tuple, Map, Nullable, LowCardinality,
/// FixedString) — `readColumn` dispatches those above the TypeId table.
pub fn typeIdFromName(type_name: []const u8) ?TypeId {
    const eq = std.mem.eql;
    const startsWith = std.mem.startsWith;
    if (eq(u8, type_name, "UInt8") or eq(u8, type_name, "Bool")) return .UInt8;
    if (eq(u8, type_name, "UInt16")) return .UInt16;
    if (eq(u8, type_name, "UInt32") or eq(u8, type_name, "IPv4")) return .UInt32;
    if (eq(u8, type_name, "UInt64")) return .UInt64;
    if (eq(u8, type_name, "UInt128")) return .UInt128;
    if (eq(u8, type_name, "UInt256")) return .UInt256;
    if (eq(u8, type_name, "Int8") or startsWith(u8, type_name, "Enum8")) return .Int8;
    if (eq(u8, type_name, "Int16") or startsWith(u8, type_name, "Enum16")) return .Int16;
    if (eq(u8, type_name, "Int32") or eq(u8, type_name, "Date32")) return .Int32;
    if (eq(u8, type_name, "Int64")) return .Int64;
    if (eq(u8, type_name, "Int128")) return .Int128;
    if (eq(u8, type_name, "Int256")) return .Int256;
    if (eq(u8, type_name, "Float32")) return .Float32;
    if (eq(u8, type_name, "Float64")) return .Float64;
    if (eq(u8, type_name, "String")) return .String;
    if (eq(u8, type_name, "JSON") or startsWith(u8, type_name, "JSON(")) return .String;
    if (eq(u8, type_name, "Date")) return .UInt16;
    // DateTime64(N, ...) is i64 (signed fractional-second ticks).
    // DateTime(...) is u32 seconds-since-epoch.
    if (startsWith(u8, type_name, "DateTime64")) return .Int64;
    if (startsWith(u8, type_name, "DateTime")) return .UInt32;
    if (startsWith(u8, type_name, "Interval")) return .Int64;
    // Decimal aliases: scaled int. Caller multiplies by 10^scale to
    // recover the rational value. Decimal128/256(S) → underlying int.
    if (startsWith(u8, type_name, "Decimal32")) return .Int32;
    if (startsWith(u8, type_name, "Decimal64")) return .Int64;
    if (startsWith(u8, type_name, "Decimal128")) return .Int128;
    if (startsWith(u8, type_name, "Decimal256")) return .Int256;
    if (startsWith(u8, type_name, "Decimal(")) {
        // Decimal(P, S): underlying int width determined by P.
        //   P <=  9 → Int32   (Decimal32)
        //   P <= 18 → Int64   (Decimal64)
        //   P <= 38 → Int128  (Decimal128)
        //   P <= 76 → Int256  (Decimal256)
        const inside = type_name[8..type_name.len - 1];
        const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return null;
        const p_str = std.mem.trim(u8, inside[0..comma], " ");
        const p = std.fmt.parseInt(u8, p_str, 10) catch return null;
        if (p <= 9) return .Int32;
        if (p <= 18) return .Int64;
        if (p <= 38) return .Int128;
        if (p <= 76) return .Int256;
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
    if (extractSimpleAggregateFunctionInner(type_name)) |inner| {
        return readColumn(reader, allocator, inner, num_rows);
    }
    if (geoAliasExpansion(type_name)) |expanded| {
        return readColumn(reader, allocator, expanded, num_rows);
    }
    const n_rows = try checkedRowCount(num_rows);
    if (extractNullableInner(type_name)) |inner_name| {
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
        const ptr = try allocator.create(Array);
        errdefer allocator.destroy(ptr);
        const offsets = try allocator.alloc(u64, n_rows);
        errdefer allocator.free(offsets);
        try reader.readSliceAll(std.mem.sliceAsBytes(offsets));
        const total: u64 = if (n_rows == 0) 0 else offsets[n_rows - 1];
        try validateOffsets(offsets, total);
        ptr.* = .{
            .offsets = offsets,
            .inner = try readColumn(reader, allocator, inner_name, total),
        };
        return .{ .Array = ptr };
    }
    if (extractFixedStringWidth(type_name)) |width| {
        const total = try checkedByteCount(n_rows, width);
        const data = try allocator.alloc(u8, total);
        errdefer allocator.free(data);
        try reader.readSliceAll(data);
        return .{ .FixedString = .{ .width = width, .data = data } };
    }
    if (std.mem.eql(u8, type_name, "UUID")) {
        const rows = try allocator.alloc([16]u8, n_rows);
        errdefer allocator.free(rows);
        try reader.readSliceAll(std.mem.sliceAsBytes(rows));
        return .{ .UUID = rows };
    }
    if (extractMapKV(type_name)) |kv| {
        // Map(K, V) wire format = Array(Tuple(K, V)): one offsets table
        // covering both key and value columns; keys flat then values flat.
        const ptr = try allocator.create(Map);
        errdefer allocator.destroy(ptr);
        const offsets = try allocator.alloc(u64, n_rows);
        errdefer allocator.free(offsets);
        try reader.readSliceAll(std.mem.sliceAsBytes(offsets));
        const total: u64 = if (n_rows == 0) 0 else offsets[n_rows - 1];
        try validateOffsets(offsets, total);
        const keys = try readColumn(reader, allocator, kv.key, total);
        errdefer keys.deinit(allocator);
        const values = try readColumn(reader, allocator, kv.value, total);
        ptr.* = .{ .offsets = offsets, .keys = keys, .values = values };
        return .{ .Map = ptr };
    }
    if (extractNestedArgs(type_name)) |args_str| {
        return readNested(reader, allocator, args_str, num_rows);
    }
    if (extractLowCardinalityInner(type_name)) |inner_name| {
        return readLowCardinality(reader, allocator, inner_name, num_rows);
    }
    if (extractTupleArgs(type_name)) |args_str| {
        const ptr = try allocator.create(Tuple);
        errdefer allocator.destroy(ptr);
        // Count comma-separated top-level args; each one is an element type.
        var elements_list: std.ArrayListUnmanaged(Column) = .empty;
        errdefer {
            for (elements_list.items) |c| c.deinit(allocator);
            elements_list.deinit(allocator);
        }
        var iter = topLevelTupleSplit(args_str);
        while (iter.next()) |elem_type| {
            const elem = try readColumn(reader, allocator, elem_type, num_rows);
            try elements_list.append(allocator, elem);
        }
        ptr.* = .{ .row_count = num_rows, .elements = try elements_list.toOwnedSlice(allocator) };
        return .{ .Tuple = ptr };
    }
    // IPv6 is canonically a 16-byte fixed-width column on the wire.
    if (std.mem.eql(u8, type_name, "IPv6")) {
        const total = try checkedByteCount(n_rows, 16);
        const data = try allocator.alloc(u8, total);
        errdefer allocator.free(data);
        try reader.readSliceAll(data);
        return .{ .FixedString = .{ .width = 16, .data = data } };
    }
    const tid = typeIdFromName(type_name) orelse return error.UnsupportedColumnType;
    const n = n_rows;
    return switch (tid) {
        .UInt8 => .{ .UInt8 = try readFixed(u8, reader, allocator, n) },
        .UInt16 => .{ .UInt16 = try readFixed(u16, reader, allocator, n) },
        .UInt32 => .{ .UInt32 = try readFixed(u32, reader, allocator, n) },
        .UInt64 => .{ .UInt64 = try readFixed(u64, reader, allocator, n) },
        .UInt128 => .{ .UInt128 = try readFixed(u128, reader, allocator, n) },
        .UInt256 => .{ .UInt256 = try readFixed(u256, reader, allocator, n) },
        .Int8 => .{ .Int8 = try readFixed(i8, reader, allocator, n) },
        .Int16 => .{ .Int16 = try readFixed(i16, reader, allocator, n) },
        .Int32 => .{ .Int32 = try readFixed(i32, reader, allocator, n) },
        .Int64 => .{ .Int64 = try readFixed(i64, reader, allocator, n) },
        .Int128 => .{ .Int128 = try readFixed(i128, reader, allocator, n) },
        .Int256 => .{ .Int256 = try readFixed(i256, reader, allocator, n) },
        .Float32 => .{ .Float32 = try readFixed(f32, reader, allocator, n) },
        .Float64 => .{ .Float64 = try readFixed(f64, reader, allocator, n) },
        .String => .{ .String = try readStringRows(reader, allocator, n) },
    };
}

pub fn hasCustomSerialization(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "JSON")
        or std.mem.startsWith(u8, type_name, "JSON(")
        or std.mem.eql(u8, type_name, "Dynamic")
        or extractSparseInner(type_name) != null;
}

pub fn readCustomColumn(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    num_rows: u64,
) !Column {
    if (std.mem.eql(u8, type_name, "JSON") or std.mem.startsWith(u8, type_name, "JSON(")) {
        const version = try reader.takeInt(u64, .little);
        if (version != 1) return error.CustomSerializationUnsupported;
        return .{ .JSON = try readStringRows(reader, allocator, try checkedRowCount(num_rows)) };
    }
    if (std.mem.eql(u8, type_name, "Dynamic")) {
        return readDynamic(reader, allocator, num_rows);
    }
    if (extractSparseInner(type_name)) |inner| {
        return readSparseMaterialized(reader, allocator, inner, num_rows);
    }
    return error.CustomSerializationUnsupported;
}

fn readStringRows(reader: *std.Io.Reader, allocator: std.mem.Allocator, n: usize) ![][]u8 {
    const rows = try allocator.alloc([]u8, n);
    errdefer allocator.free(rows);
    var i: usize = 0;
    errdefer for (rows[0..i]) |r| allocator.free(r);
    while (i < n) : (i += 1) {
        const len_v = try varint.readVarUInt(reader, u64);
        if (len_v > MAX_STRING_VALUE_BYTES) return error.StringValueTooLarge;
        rows[i] = try reader.readAlloc(allocator, @intCast(len_v));
    }
    return rows;
}

fn readDynamic(reader: *std.Io.Reader, allocator: std.mem.Allocator, num_rows: u64) !Column {
    const n_rows = try checkedRowCount(num_rows);
    const version = try reader.takeInt(u64, .little);
    if (version != 1) return error.CustomSerializationUnsupported;
    const type_count_v = try varint.readVarUInt(reader, u64);
    if (type_count_v > 256) return error.CustomSerializationTooLarge;
    const type_count: usize = @intCast(type_count_v);

    const dyn = try allocator.create(Dynamic);
    errdefer allocator.destroy(dyn);
    const type_names = try allocator.alloc([]u8, type_count);
    errdefer allocator.free(type_names);
    var names_built: usize = 0;
    errdefer for (type_names[0..names_built]) |name| allocator.free(name);
    while (names_built < type_count) : (names_built += 1) {
        type_names[names_built] = try wire.readStringOwned(reader, allocator, wire.MAX_DEFAULT_STRING);
    }

    const discriminators = try allocator.alloc(u8, n_rows);
    errdefer allocator.free(discriminators);
    try reader.readSliceAll(discriminators);

    const counts = try allocator.alloc(u64, type_count);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (discriminators) |d| {
        if (d == 0xff) continue;
        if (d >= type_count) return error.CustomSerializationUnsupported;
        counts[d] += 1;
    }

    const values = try allocator.alloc(Column, type_count);
    errdefer allocator.free(values);
    var built: usize = 0;
    errdefer for (values[0..built]) |value| value.deinit(allocator);
    while (built < type_count) : (built += 1) {
        values[built] = try readColumn(reader, allocator, type_names[built], counts[built]);
    }
    dyn.* = .{ .type_names = type_names, .discriminators = discriminators, .values = values };
    return .{ .Dynamic = dyn };
}

fn readSparseMaterialized(reader: *std.Io.Reader, allocator: std.mem.Allocator, inner: []const u8, num_rows: u64) !Column {
    const n_rows = try checkedRowCount(num_rows);
    const non_default_v = try varint.readVarUInt(reader, u64);
    if (non_default_v > num_rows) return error.CustomSerializationTooLarge;
    const non_default: usize = @intCast(non_default_v);
    const indexes = try allocator.alloc(u64, non_default);
    defer allocator.free(indexes);
    try reader.readSliceAll(std.mem.sliceAsBytes(indexes));
    var prev: u64 = 0;
    for (indexes, 0..) |idx, i| {
        if (idx >= num_rows) return error.InvalidArrayOffsets;
        if (i != 0 and idx <= prev) return error.InvalidArrayOffsets;
        prev = idx;
    }
    const sparse_values = try readColumn(reader, allocator, inner, non_default);
    defer sparse_values.deinit(allocator);
    return materializeSparse(allocator, inner, n_rows, indexes, sparse_values);
}

fn materializeSparse(allocator: std.mem.Allocator, inner: []const u8, n_rows: usize, indexes: []const u64, sparse_values: Column) !Column {
    if (typeIdFromName(inner)) |tid| switch (tid) {
        .UInt8 => {
            const dense = try allocator.alloc(u8, n_rows);
            @memset(dense, 0);
            for (indexes, 0..) |idx, i| dense[@intCast(idx)] = sparse_values.UInt8[i];
            return .{ .UInt8 = dense };
        },
        .UInt32 => {
            const dense = try allocator.alloc(u32, n_rows);
            @memset(dense, 0);
            for (indexes, 0..) |idx, i| dense[@intCast(idx)] = sparse_values.UInt32[i];
            return .{ .UInt32 = dense };
        },
        else => {},
    };
    return error.CustomSerializationUnsupported;
}

/// Read `n` fixed-size little-endian values back-to-back. Assumes host
/// endianness == little-endian (x86_64, aarch64); a big-endian host
/// would need byte-swapping after the read.
fn readFixed(comptime T: type, reader: *std.Io.Reader, allocator: std.mem.Allocator, n: usize) ![]T {
    _ = try checkedByteCount(n, @sizeOf(T));
    const slice = try allocator.alloc(T, n);
    errdefer allocator.free(slice);
    try reader.readSliceAll(std.mem.sliceAsBytes(slice));
    return slice;
}

fn checkedRowCount(n: u64) Error!usize {
    if (n > MAX_COLUMN_ROWS) return error.ColumnTooLarge;
    if (n > std.math.maxInt(usize)) return error.ColumnTooLarge;
    return @intCast(n);
}

fn checkedByteCount(count: usize, elem_size: usize) Error!usize {
    if (elem_size != 0 and count > MAX_COLUMN_BYTES / elem_size) return error.ColumnTooLarge;
    return count * elem_size;
}

fn validateOffsets(offsets: []const u64, total: u64) Error!void {
    var prev: u64 = 0;
    for (offsets) |offset| {
        if (offset < prev) return error.InvalidArrayOffsets;
        prev = offset;
    }
    _ = try checkedRowCount(total);
}

/// Type-aware column writer. Dispatches `LowCardinality(...)` to the
/// LC encoder (which builds a dictionary on the fly), and forwards every
/// other type to the plain `writeColumn` flat-bytes path. `num_rows` is
/// the column's row count from the enclosing Block; passed in here so
/// the LC encoder can emit `num_indexes` without re-deriving the count
/// from each variant's len().
pub fn writeColumnTyped(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    col: Column,
    num_rows: u64,
) !void {
    if (extractSimpleAggregateFunctionInner(type_name)) |_| {
        return writeColumn(writer, col);
    }
    if (geoAliasExpansion(type_name)) |_| {
        return writeColumn(writer, col);
    }
    if (extractNestedArgs(type_name)) |_| {
        return writeColumn(writer, col);
    }
    if (hasCustomSerialization(type_name)) {
        return writeCustomColumnTyped(writer, allocator, type_name, col, num_rows);
    }
    if (extractLowCardinalityInner(type_name)) |inner_name| {
        return writeLowCardinality(writer, allocator, inner_name, col, num_rows);
    }
    return writeColumn(writer, col);
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
        .Tuple => |t| {
            for (t.elements) |e| try writeColumn(writer, e);
        },
        .Map => |m| {
            try writer.writeAll(std.mem.sliceAsBytes(m.offsets));
            try writeColumn(writer, m.keys);
            try writeColumn(writer, m.values);
        },
        .JSON => |rows| {
            for (rows) |row| try wire.writeStringBinary(writer, row);
        },
        .Dynamic => {},
        inline else => |slice| try writer.writeAll(std.mem.sliceAsBytes(slice)),
    }
}

pub fn writeCustomColumnTyped(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    col: Column,
    num_rows: u64,
) !void {
    _ = allocator;
    _ = num_rows;
    if (std.mem.eql(u8, type_name, "JSON") or std.mem.startsWith(u8, type_name, "JSON(")) {
        try writer.writeInt(u64, 1, .little);
        switch (col) {
            .JSON => |rows| for (rows) |row| try wire.writeStringBinary(writer, row),
            .String => |rows| for (rows) |row| try wire.writeStringBinary(writer, row),
            else => return error.InsertColumnTypeMismatch,
        }
        return;
    }
    return error.CustomSerializationUnsupported;
}

pub fn extractArrayInner(type_name: []const u8) ?[]const u8 {
    const prefix = "Array(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

pub fn geoAliasExpansion(type_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, type_name, "Point")) return "Tuple(Float64, Float64)";
    if (std.mem.eql(u8, type_name, "Ring")) return "Array(Point)";
    if (std.mem.eql(u8, type_name, "LineString")) return "Array(Point)";
    if (std.mem.eql(u8, type_name, "MultiLineString")) return "Array(LineString)";
    if (std.mem.eql(u8, type_name, "Polygon")) return "Array(Ring)";
    if (std.mem.eql(u8, type_name, "MultiPolygon")) return "Array(Polygon)";
    return null;
}

pub fn extractSparseInner(type_name: []const u8) ?[]const u8 {
    const prefix = "Sparse(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

pub const MapKV = struct { key: []const u8, value: []const u8 };

/// Split "Map(K, V)" into K and V at the top-level comma. Inner commas
/// inside nested types are skipped via depth tracking.
pub fn extractMapKV(type_name: []const u8) ?MapKV {
    const prefix = "Map(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    const inside = type_name[prefix.len .. type_name.len - 1];
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < inside.len) : (i += 1) {
        switch (inside[i]) {
            '(' => depth += 1,
            ')' => if (depth > 0) { depth -= 1; },
            ',' => if (depth == 0) {
                const k = std.mem.trim(u8, inside[0..i], " ");
                const v = std.mem.trim(u8, inside[i + 1 ..], " ");
                return .{ .key = k, .value = v };
            },
            else => {},
        }
    }
    return null;
}

pub fn extractSimpleAggregateFunctionInner(type_name: []const u8) ?[]const u8 {
    const prefix = "SimpleAggregateFunction(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    const inside = type_name[prefix.len .. type_name.len - 1];
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < inside.len) : (i += 1) {
        switch (inside[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) return std.mem.trim(u8, inside[i + 1 ..], " "),
            else => {},
        }
    }
    return null;
}

pub fn extractNestedArgs(type_name: []const u8) ?[]const u8 {
    const prefix = "Nested(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

fn nestedFieldType(field_decl: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, field_decl, " ");
    if (trimmed.len == 0) return null;
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        switch (trimmed[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ' ', '\t', '\r', '\n' => if (depth == 0) {
                return std.mem.trim(u8, trimmed[i + 1 ..], " ");
            },
            else => {},
        }
    }
    return null;
}

fn readNested(reader: *std.Io.Reader, allocator: std.mem.Allocator, args_str: []const u8, num_rows: u64) !Column {
    const n_rows = try checkedRowCount(num_rows);
    const ptr = try allocator.create(Array);
    errdefer allocator.destroy(ptr);
    const offsets = try allocator.alloc(u64, n_rows);
    errdefer allocator.free(offsets);
    try reader.readSliceAll(std.mem.sliceAsBytes(offsets));
    const total: u64 = if (n_rows == 0) 0 else offsets[n_rows - 1];
    try validateOffsets(offsets, total);

    const tuple_ptr = try allocator.create(Tuple);
    errdefer allocator.destroy(tuple_ptr);
    var elements_list: std.ArrayListUnmanaged(Column) = .empty;
    errdefer {
        for (elements_list.items) |c| c.deinit(allocator);
        elements_list.deinit(allocator);
    }

    var iter = topLevelTupleSplit(args_str);
    while (iter.next()) |field_decl| {
        const elem_type = nestedFieldType(field_decl) orelse return error.UnsupportedColumnType;
        const elem = try readColumn(reader, allocator, elem_type, total);
        try elements_list.append(allocator, elem);
    }
    tuple_ptr.* = .{ .row_count = total, .elements = try elements_list.toOwnedSlice(allocator) };
    ptr.* = .{ .offsets = offsets, .inner = .{ .Tuple = tuple_ptr } };
    return .{ .Array = ptr };
}

pub fn extractTupleArgs(type_name: []const u8) ?[]const u8 {
    const prefix = "Tuple(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

/// Iterator over comma-separated top-level type-names inside a Tuple
/// or similar. Tracks nesting depth so commas inside Array(...) /
/// Tuple(...) etc don't split prematurely.
pub const TopLevelSplit = struct {
    src: []const u8,
    pos: usize = 0,
    pub fn next(self: *TopLevelSplit) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        var depth: u32 = 0;
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) depth -= 1;
            if (c == ',' and depth == 0) {
                const piece = std.mem.trim(u8, self.src[start..self.pos], " ");
                self.pos += 1;
                return piece;
            }
        }
        const tail = std.mem.trim(u8, self.src[start..self.pos], " ");
        return tail;
    }
};

pub fn topLevelTupleSplit(src: []const u8) TopLevelSplit {
    return .{ .src = src };
}

pub fn extractFixedStringWidth(type_name: []const u8) ?usize {
    const prefix = "FixedString(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    const inside = type_name[prefix.len .. type_name.len - 1];
    return std.fmt.parseInt(usize, inside, 10) catch null;
}

/// Returns the inner type name if `type_name` matches "LowCardinality(...)".
pub fn extractLowCardinalityInner(type_name: []const u8) ?[]const u8 {
    const prefix = "LowCardinality(";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    if (!std.mem.endsWith(u8, type_name, ")")) return null;
    return type_name[prefix.len .. type_name.len - 1];
}

/// Decode a LowCardinality(T) column body. Materializes the (dictionary,
/// indexes) wire layout into a regular Column<T> with `num_rows` entries
/// so callers see the same shape they would for an unwrapped T column.
/// LC(Nullable(T)) is materialized as Nullable(T) where mask[i]=1 means
/// the wire-side index pointed at the dictionary's null sentinel (idx 0).
///
/// State assumption: each block carries its own version+serialization
/// prefix, so this function is safe to call per-block. If the server is
/// configured for cross-block stream state (uncommon), the second block
/// would fail to decode here — out of scope for v0.16.0.
fn readLowCardinality(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    inner_name: []const u8,
    num_rows: u64,
) anyerror!Column {
    const inner_is_nullable = extractNullableInner(inner_name);
    // For LC(Nullable(T)) the dictionary stores T (NOT Nullable(T));
    // index 0 is the null sentinel. For LC(T) the dictionary is T as-is.
    const dict_inner_name = inner_is_nullable orelse inner_name;

    if (num_rows == 0) {
        // Empty block: no LC payload was emitted (matches upstream and
        // klickhouse). Return an empty materialized column matching the
        // surface type the caller expects.
        if (inner_is_nullable) |_| {
            const ptr = try allocator.create(Nullable);
            errdefer allocator.destroy(ptr);
            const mask = try allocator.alloc(u8, 0);
            errdefer allocator.free(mask);
            ptr.* = .{
                .mask = mask,
                .inner = try readColumn(reader, allocator, dict_inner_name, 0),
            };
            return .{ .Nullable = ptr };
        }
        return readColumn(reader, allocator, dict_inner_name, 0);
    }

    const key_version = try reader.takeInt(u64, .little);
    if (key_version != LC_KEY_VERSION) return error.LowCardinalityCorruptFrame;

    const ser_type = try reader.takeInt(u64, .little);
    const idx_type = ser_type & LC_INDEX_TYPE_MASK;
    const has_global_dict = (ser_type & LC_NEED_GLOBAL_DICT_BIT) != 0;
    const has_add_keys = (ser_type & LC_HAS_ADDITIONAL_KEYS_BIT) != 0;

    var global_dict: ?Column = null;
    defer if (global_dict) |g| g.deinit(allocator);
    if (has_global_dict) {
        const dict_size = try reader.takeInt(u64, .little);
        global_dict = try readColumn(reader, allocator, dict_inner_name, dict_size);
    }

    var add_keys: ?Column = null;
    defer if (add_keys) |a| a.deinit(allocator);
    if (has_add_keys) {
        const add_size = try reader.takeInt(u64, .little);
        add_keys = try readColumn(reader, allocator, dict_inner_name, add_size);
    }

    // The active dictionary for materialization: prefer per-block
    // additional keys (the common case for ClickHouse server output).
    const dict = add_keys orelse global_dict orelse return error.LowCardinalityCorruptFrame;

    const num_indexes = try reader.takeInt(u64, .little);
    if (num_indexes != num_rows) return error.LowCardinalityCorruptFrame;

    const indexes = try readLcIndexes(reader, allocator, idx_type, num_rows);
    defer allocator.free(indexes);

    const dict_len = dict.len();
    for (indexes) |idx| {
        if (idx >= dict_len) return error.LowCardinalityCorruptFrame;
    }

    if (inner_is_nullable) |_| {
        return materializeNullableLc(allocator, dict, indexes);
    }
    return materializeLc(allocator, dict, indexes);
}

fn readLcIndexes(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    idx_type: u64,
    n: u64,
) ![]u64 {
    const n_usize: usize = @intCast(n);
    const out = try allocator.alloc(u64, n_usize);
    errdefer allocator.free(out);
    switch (idx_type) {
        LC_INDEX_UINT8 => {
            const buf = try allocator.alloc(u8, n_usize);
            defer allocator.free(buf);
            try reader.readSliceAll(buf);
            for (buf, 0..) |b, i| out[i] = b;
        },
        LC_INDEX_UINT16 => {
            const buf = try allocator.alloc(u16, n_usize);
            defer allocator.free(buf);
            try reader.readSliceAll(std.mem.sliceAsBytes(buf));
            for (buf, 0..) |v, i| out[i] = v;
        },
        LC_INDEX_UINT32 => {
            const buf = try allocator.alloc(u32, n_usize);
            defer allocator.free(buf);
            try reader.readSliceAll(std.mem.sliceAsBytes(buf));
            for (buf, 0..) |v, i| out[i] = v;
        },
        LC_INDEX_UINT64 => try reader.readSliceAll(std.mem.sliceAsBytes(out)),
        else => return error.LowCardinalityCorruptFrame,
    }
    return out;
}

fn cloneByIndexT(
    comptime T: type,
    allocator: std.mem.Allocator,
    src: []const T,
    indexes: []const u64,
) ![]T {
    const out = try allocator.alloc(T, indexes.len);
    errdefer allocator.free(out);
    for (indexes, 0..) |idx, i| out[i] = src[@intCast(idx)];
    return out;
}

fn materializeLc(allocator: std.mem.Allocator, dict: Column, indexes: []const u64) !Column {
    return switch (dict) {
        .UInt8 => |s| .{ .UInt8 = try cloneByIndexT(u8, allocator, s, indexes) },
        .UInt16 => |s| .{ .UInt16 = try cloneByIndexT(u16, allocator, s, indexes) },
        .UInt32 => |s| .{ .UInt32 = try cloneByIndexT(u32, allocator, s, indexes) },
        .UInt64 => |s| .{ .UInt64 = try cloneByIndexT(u64, allocator, s, indexes) },
        .UInt128 => |s| .{ .UInt128 = try cloneByIndexT(u128, allocator, s, indexes) },
        .UInt256 => |s| .{ .UInt256 = try cloneByIndexT(u256, allocator, s, indexes) },
        .Int8 => |s| .{ .Int8 = try cloneByIndexT(i8, allocator, s, indexes) },
        .Int16 => |s| .{ .Int16 = try cloneByIndexT(i16, allocator, s, indexes) },
        .Int32 => |s| .{ .Int32 = try cloneByIndexT(i32, allocator, s, indexes) },
        .Int64 => |s| .{ .Int64 = try cloneByIndexT(i64, allocator, s, indexes) },
        .Int128 => |s| .{ .Int128 = try cloneByIndexT(i128, allocator, s, indexes) },
        .Int256 => |s| .{ .Int256 = try cloneByIndexT(i256, allocator, s, indexes) },
        .Float32 => |s| .{ .Float32 = try cloneByIndexT(f32, allocator, s, indexes) },
        .Float64 => |s| .{ .Float64 = try cloneByIndexT(f64, allocator, s, indexes) },
        .UUID => |s| .{ .UUID = try cloneByIndexT([16]u8, allocator, s, indexes) },
        .String => |rows| blk: {
            const out = try allocator.alloc([]u8, indexes.len);
            errdefer allocator.free(out);
            var produced: usize = 0;
            errdefer for (out[0..produced]) |r| allocator.free(r);
            for (indexes, 0..) |idx, i| {
                out[i] = try allocator.dupe(u8, rows[@intCast(idx)]);
                produced = i + 1;
            }
            break :blk .{ .String = out };
        },
        .FixedString => |fs| blk: {
            const out = try allocator.alloc(u8, indexes.len * fs.width);
            errdefer allocator.free(out);
            for (indexes, 0..) |idx, i| {
                const src_off: usize = @as(usize, @intCast(idx)) * fs.width;
                @memcpy(out[i * fs.width ..][0..fs.width], fs.data[src_off..][0..fs.width]);
            }
            break :blk .{ .FixedString = .{ .width = fs.width, .data = out } };
        },
        else => error.UnsupportedColumnType,
    };
}

fn materializeNullableLc(allocator: std.mem.Allocator, dict: Column, indexes: []const u64) !Column {
    const ptr = try allocator.create(Nullable);
    errdefer allocator.destroy(ptr);
    const mask = try allocator.alloc(u8, indexes.len);
    errdefer allocator.free(mask);
    for (indexes, 0..) |idx, i| mask[i] = if (idx == 0) 1 else 0;
    ptr.* = .{
        .mask = mask,
        .inner = try materializeLc(allocator, dict, indexes),
    };
    return .{ .Nullable = ptr };
}

/// Encode a LowCardinality(T) column body. Caller has already written the
/// column header (name + type + has_custom_serialization byte). Builds a
/// per-block dictionary via hashmap dedup, picks the smallest index integer
/// width that fits, and emits the frame:
///
///     u64 keyVersion (== 1)
///     u64 ser_type   (= idx_width | HAS_ADDITIONAL_KEYS_BIT)
///     u64 add_keys_size
///     dict body  (existing column writer over the deduplicated values)
///     u64 num_indexes  (== num_rows)
///     indexes  (num_rows entries at idx_width)
///
/// For LC(Nullable(T)), `col` MUST be a Nullable wrapper. Index 0 in the
/// emitted dictionary is the null sentinel (a zero-T value: `""` for
/// String, 0 for numerics, all-zero bytes for FixedString); rows where
/// `mask[i] != 0` emit index 0.
pub fn writeLowCardinality(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    inner_name: []const u8,
    col: Column,
    num_rows: u64,
) !void {
    const inner_is_nullable = extractNullableInner(inner_name);
    const leaf_name = inner_is_nullable orelse inner_name;

    // Pre-flight: catch type-name vs union-tag mismatch BEFORE we emit
    // any wire bytes. Without this, the server rejects after-the-fact
    // and the connection lands in `.broken` with an opaque error.
    const leaf_data: Column = if (inner_is_nullable) |_| blk: {
        if (col != .Nullable) return error.InsertColumnTypeMismatch;
        break :blk col.Nullable.inner;
    } else col;
    if (!lcLeafTypeMatches(leaf_name, leaf_data)) {
        return error.InsertColumnTypeMismatch;
    }

    if (num_rows == 0) {
        // Empty block: emit no LC payload (matches what we accept on
        // read). Unreachable from public client.insert API today —
        // num_rows is always > 0 there. Lock contract via test.
        return;
    }

    // Note: for LC(Nullable(T)) where a non-null row's value equals the
    // T-zero (e.g. UInt32 0, empty String, all-zero FixedString), the
    // dictionary will end up with TWO copies of that value: index 0
    // (the null sentinel) and a fresh slot from dedup. This is required
    // by the read-side contract at `materializeNullableLc`, which
    // derives `mask[i]` from `idx == 0` — collapsing the duplicate
    // would mark every real-zero row as NULL on read-back. The minor
    // dict-size inflation is acceptable; round-trip correctness is not.
    var built: DedupResult = if (inner_is_nullable) |_|
        try dedupNullableForLc(allocator, col)
    else
        try dedupForLc(allocator, col);
    defer built.dict.deinit(allocator);
    defer allocator.free(built.indexes);

    const dict_size = built.dict.len();
    const idx_width = pickLcIndexWidth(dict_size);

    try writer.writeInt(u64, LC_KEY_VERSION, .little);
    try writer.writeInt(u64, idx_width | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try writer.writeInt(u64, dict_size, .little);
    try writeColumn(writer, built.dict);
    try writer.writeInt(u64, @as(u64, built.indexes.len), .little);
    try writeLcIndexes(writer, idx_width, built.indexes);
}

const DedupResult = struct {
    dict: Column,
    indexes: []u64,
};

fn lcLeafTypeMatches(type_name: []const u8, col: Column) bool {
    if (extractFixedStringWidth(type_name) != null) return col == .FixedString;
    if (std.mem.eql(u8, type_name, "String")) return col == .String;
    const tid = typeIdFromName(type_name) orelse return false;
    return switch (col) {
        .UInt8 => tid == .UInt8,
        .UInt16 => tid == .UInt16,
        .UInt32 => tid == .UInt32,
        .UInt64 => tid == .UInt64,
        .Int8 => tid == .Int8,
        .Int16 => tid == .Int16,
        .Int32 => tid == .Int32,
        .Int64 => tid == .Int64,
        .String => tid == .String,
        else => false,
    };
}

fn pickLcIndexWidth(dict_size: usize) u64 {
    if (dict_size <= (1 << 8)) return LC_INDEX_UINT8;
    if (dict_size <= (1 << 16)) return LC_INDEX_UINT16;
    if (dict_size <= (1 << 32)) return LC_INDEX_UINT32;
    return LC_INDEX_UINT64;
}

fn writeLcIndexes(writer: *std.Io.Writer, idx_width: u64, indexes: []const u64) !void {
    switch (idx_width) {
        LC_INDEX_UINT8 => for (indexes) |idx| try writer.writeByte(@intCast(idx)),
        LC_INDEX_UINT16 => for (indexes) |idx| try writer.writeInt(u16, @intCast(idx), .little),
        LC_INDEX_UINT32 => for (indexes) |idx| try writer.writeInt(u32, @intCast(idx), .little),
        LC_INDEX_UINT64 => for (indexes) |idx| try writer.writeInt(u64, idx, .little),
        else => unreachable,
    }
}

fn dedupForLc(allocator: std.mem.Allocator, col: Column) !DedupResult {
    return switch (col) {
        .UInt8 => |s| dedupNumericForLc(u8, allocator, s, .UInt8, false, null),
        .UInt16 => |s| dedupNumericForLc(u16, allocator, s, .UInt16, false, null),
        .UInt32 => |s| dedupNumericForLc(u32, allocator, s, .UInt32, false, null),
        .UInt64 => |s| dedupNumericForLc(u64, allocator, s, .UInt64, false, null),
        .Int8 => |s| dedupNumericForLc(i8, allocator, s, .Int8, false, null),
        .Int16 => |s| dedupNumericForLc(i16, allocator, s, .Int16, false, null),
        .Int32 => |s| dedupNumericForLc(i32, allocator, s, .Int32, false, null),
        .Int64 => |s| dedupNumericForLc(i64, allocator, s, .Int64, false, null),
        .String => |rows| dedupStringForLc(allocator, rows, null),
        .FixedString => |fs| dedupFixedStringForLc(allocator, fs, null),
        else => error.UnsupportedColumnType,
    };
}

fn dedupNullableForLc(allocator: std.mem.Allocator, col: Column) !DedupResult {
    const n = col.Nullable;
    return switch (n.inner) {
        .UInt8 => |s| dedupNumericForLc(u8, allocator, s, .UInt8, true, n.mask),
        .UInt16 => |s| dedupNumericForLc(u16, allocator, s, .UInt16, true, n.mask),
        .UInt32 => |s| dedupNumericForLc(u32, allocator, s, .UInt32, true, n.mask),
        .UInt64 => |s| dedupNumericForLc(u64, allocator, s, .UInt64, true, n.mask),
        .Int8 => |s| dedupNumericForLc(i8, allocator, s, .Int8, true, n.mask),
        .Int16 => |s| dedupNumericForLc(i16, allocator, s, .Int16, true, n.mask),
        .Int32 => |s| dedupNumericForLc(i32, allocator, s, .Int32, true, n.mask),
        .Int64 => |s| dedupNumericForLc(i64, allocator, s, .Int64, true, n.mask),
        .String => |rows| dedupStringForLc(allocator, rows, n.mask),
        .FixedString => |fs| dedupFixedStringForLc(allocator, fs, n.mask),
        else => error.UnsupportedColumnType,
    };
}

fn dedupNumericForLc(
    comptime T: type,
    allocator: std.mem.Allocator,
    src: []const T,
    comptime tag: anytype,
    nullable: bool,
    mask: ?[]const u8,
) !DedupResult {
    var seen: std.AutoHashMap(T, u64) = .init(allocator);
    defer seen.deinit();
    var dict: std.ArrayListUnmanaged(T) = .empty;
    errdefer dict.deinit(allocator);

    if (nullable) try dict.append(allocator, std.mem.zeroes(T));

    const indexes = try allocator.alloc(u64, src.len);
    errdefer allocator.free(indexes);

    for (src, 0..) |v, i| {
        if (nullable and mask.?[i] != 0) {
            indexes[i] = 0;
            continue;
        }
        const gop = try seen.getOrPut(v);
        if (!gop.found_existing) {
            gop.value_ptr.* = dict.items.len;
            try dict.append(allocator, v);
        }
        indexes[i] = gop.value_ptr.*;
    }

    const owned = try dict.toOwnedSlice(allocator);
    return .{
        .dict = @unionInit(Column, @tagName(tag), owned),
        .indexes = indexes,
    };
}

fn dedupStringForLc(
    allocator: std.mem.Allocator,
    src: []const []u8,
    mask: ?[]const u8,
) !DedupResult {
    // The hashmap holds slice references into `src` (stable for this
    // function's lifetime — the caller's input). `dict_origins[k]` is
    // either an index into `src` for the row that introduced dict
    // entry k, or null for the empty-string null sentinel at index 0.
    var seen: std.StringHashMap(u64) = .init(allocator);
    defer seen.deinit();
    var dict_origins: std.ArrayListUnmanaged(?usize) = .empty;
    defer dict_origins.deinit(allocator);

    if (mask) |_| try dict_origins.append(allocator, null);

    const indexes = try allocator.alloc(u64, src.len);
    errdefer allocator.free(indexes);

    for (src, 0..) |v, i| {
        if (mask) |m| if (m[i] != 0) {
            indexes[i] = 0;
            continue;
        };
        const gop = try seen.getOrPut(v);
        if (!gop.found_existing) {
            gop.value_ptr.* = dict_origins.items.len;
            try dict_origins.append(allocator, i);
        }
        indexes[i] = gop.value_ptr.*;
    }

    // Materialize the dictionary as owned []u8 per row.
    const owned_dict = try allocator.alloc([]u8, dict_origins.items.len);
    errdefer allocator.free(owned_dict);
    var produced: usize = 0;
    errdefer for (owned_dict[0..produced]) |s| allocator.free(s);
    for (dict_origins.items, 0..) |maybe_idx, k| {
        const bytes: []const u8 = if (maybe_idx) |idx| src[idx] else &[_]u8{};
        owned_dict[k] = try allocator.dupe(u8, bytes);
        produced = k + 1;
    }
    return .{ .dict = .{ .String = owned_dict }, .indexes = indexes };
}

fn dedupFixedStringForLc(
    allocator: std.mem.Allocator,
    fs: FixedString,
    mask: ?[]const u8,
) !DedupResult {
    const num_rows = if (fs.width == 0) 0 else fs.data.len / fs.width;
    var seen: std.StringHashMap(u64) = .init(allocator);
    defer seen.deinit();
    // Track input row indices that introduced each dict entry. The
    // hashmap keys are slices into `fs.data` (stable for this function).
    var dict_origins: std.ArrayListUnmanaged(?usize) = .empty;
    defer dict_origins.deinit(allocator);

    if (mask) |_| try dict_origins.append(allocator, null);

    const indexes = try allocator.alloc(u64, num_rows);
    errdefer allocator.free(indexes);

    var i: usize = 0;
    while (i < num_rows) : (i += 1) {
        if (mask) |m| if (m[i] != 0) {
            indexes[i] = 0;
            continue;
        };
        const row = fs.data[i * fs.width ..][0..fs.width];
        const gop = try seen.getOrPut(row);
        if (!gop.found_existing) {
            gop.value_ptr.* = dict_origins.items.len;
            try dict_origins.append(allocator, i);
        }
        indexes[i] = gop.value_ptr.*;
    }

    const data = try allocator.alloc(u8, dict_origins.items.len * fs.width);
    errdefer allocator.free(data);
    for (dict_origins.items, 0..) |maybe_idx, k| {
        const dst = data[k * fs.width ..][0..fs.width];
        if (maybe_idx) |idx| {
            @memcpy(dst, fs.data[idx * fs.width ..][0..fs.width]);
        } else {
            @memset(dst, 0);
        }
    }
    return .{
        .dict = .{ .FixedString = .{ .width = fs.width, .data = data } },
        .indexes = indexes,
    };
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

test "extractMapKV handles nested commas" {
    const kv = extractMapKV("Map(String, Array(UInt32))").?;
    try testing.expectEqualStrings("String", kv.key);
    try testing.expectEqualStrings("Array(UInt32)", kv.value);
}

test "SimpleAggregateFunction peels value type" {
    try testing.expectEqualStrings("UInt64", extractSimpleAggregateFunctionInner("SimpleAggregateFunction(sum, UInt64)").?);
    try testing.expectEqualStrings("Nullable(UInt32)", extractSimpleAggregateFunctionInner("SimpleAggregateFunction(any, Nullable(UInt32))").?);
    try testing.expectEqual(@as(?[]const u8, null), extractSimpleAggregateFunctionInner("AggregateFunction(sum, UInt64)"));
}

test "Nested field parser extracts field value types" {
    const args = extractNestedArgs("Nested(x UInt32, y String, z Array(Nullable(Int8)))").?;
    var it = topLevelTupleSplit(args);
    try testing.expectEqualStrings("UInt32", nestedFieldType(it.next().?).?);
    try testing.expectEqualStrings("String", nestedFieldType(it.next().?).?);
    try testing.expectEqualStrings("Array(Nullable(Int8))", nestedFieldType(it.next().?).?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "extractTupleArgs + topLevelTupleSplit" {
    const args = extractTupleArgs("Tuple(UInt8, String, Array(Int32))").?;
    var it = topLevelTupleSplit(args);
    try testing.expectEqualStrings("UInt8", it.next().?);
    try testing.expectEqualStrings("String", it.next().?);
    try testing.expectEqualStrings("Array(Int32)", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "geo aliases expand to Native tuple/array shapes" {
    try testing.expectEqualStrings("Tuple(Float64, Float64)", geoAliasExpansion("Point").?);
    try testing.expectEqualStrings("Array(Point)", geoAliasExpansion("Ring").?);
    try testing.expectEqualStrings("Array(Point)", geoAliasExpansion("LineString").?);
    try testing.expectEqualStrings("Array(LineString)", geoAliasExpansion("MultiLineString").?);
    try testing.expectEqualStrings("Array(Ring)", geoAliasExpansion("Polygon").?);
    try testing.expectEqualStrings("Array(Polygon)", geoAliasExpansion("MultiPolygon").?);
    try testing.expectEqual(@as(?[]const u8, null), geoAliasExpansion("Tuple(Float64, Float64)"));
}

test "Point alias round-trips as Tuple(Float64, Float64)" {
    const ally = testing.allocator;
    var xs = [_]f64{ 1.25, 3.5 };
    var ys = [_]f64{ 2.75, 4.5 };
    var elements = [_]Column{
        .{ .Float64 = &xs },
        .{ .Float64 = &ys },
    };
    var point_box: Tuple = .{ .row_count = 2, .elements = &elements };
    const col_in: Column = .{ .Tuple = &point_box };

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeColumnTyped(&w, ally, "Point", col_in, 2);
    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "Point", 2);
    defer col_out.deinit(ally);

    try testing.expectEqual(@as(usize, 2), col_out.Tuple.elements.len);
    try testing.expectEqualSlices(f64, &xs, col_out.Tuple.elements[0].Float64);
    try testing.expectEqualSlices(f64, &ys, col_out.Tuple.elements[1].Float64);
}

test "DateTime64 maps to signed Int64 ticks" {
    try testing.expectEqual(TypeId.Int64, typeIdFromName("DateTime64(3)").?);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rows = [_]i64{ -315619200000, 0 };
    try writeColumnTyped(&w, testing.allocator, "DateTime64(3)", .{ .Int64 = &rows }, 2);
    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "DateTime64(3)", 2);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualSlices(i64, &rows, col_out.Int64);
}

test "Nested round-trips as Array(Tuple(...))" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const offsets = [_]u64{ 2, 3 };
    var ids = [_]u32{ 1, 2, 3 };
    var names = [_][]u8{ @constCast("a"), @constCast("b"), @constCast("c") };
    var elements = [_]Column{ .{ .UInt32 = &ids }, .{ .String = &names } };
    var tuple_box: Tuple = .{ .row_count = 3, .elements = &elements };
    var nested_box: Array = .{ .offsets = @constCast(&offsets), .inner = .{ .Tuple = &tuple_box } };

    try writeColumnTyped(&w, ally, "Nested(id UInt32, name String)", .{ .Array = &nested_box }, 2);
    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "Nested(id UInt32, name String)", 2);
    defer col_out.deinit(ally);

    try testing.expectEqualSlices(u64, &offsets, col_out.Array.offsets);
    try testing.expectEqualSlices(u32, &ids, col_out.Array.inner.Tuple.elements[0].UInt32);
    try testing.expectEqualStrings("c", col_out.Array.inner.Tuple.elements[1].String[2]);
}

test "Ring alias round-trips as Array(Point)" {
    const ally = testing.allocator;
    var xs = [_]f64{ 0, 1, 1, 0 };
    var ys = [_]f64{ 0, 0, 1, 1 };
    var elements = [_]Column{
        .{ .Float64 = &xs },
        .{ .Float64 = &ys },
    };
    var tuple_box: Tuple = .{ .row_count = 4, .elements = &elements };
    var offsets = [_]u64{4};
    var ring_box: Array = .{
        .offsets = &offsets,
        .inner = .{ .Tuple = &tuple_box },
    };
    const col_in: Column = .{ .Array = &ring_box };

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeColumnTyped(&w, ally, "Ring", col_in, 1);
    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "Ring", 1);
    defer col_out.deinit(ally);

    try testing.expectEqualSlices(u64, &offsets, col_out.Array.offsets);
    try testing.expectEqualSlices(f64, &xs, col_out.Array.inner.Tuple.elements[0].Float64);
    try testing.expectEqualSlices(f64, &ys, col_out.Array.inner.Tuple.elements[1].Float64);
}

test "Tuple(UInt32, String) round-trips" {
    const ally = testing.allocator;
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ids = [_]u32{ 1, 2, 3 };
    var labels = [_][]u8{ @constCast("a"), @constCast("bb"), @constCast("ccc") };
    var elements = [_]Column{
        .{ .UInt32 = &ids },
        .{ .String = &labels },
    };
    var tup_box: Tuple = .{ .row_count = 3, .elements = &elements };
    const col_in: Column = .{ .Tuple = &tup_box };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "Tuple(UInt32, String)", 3);
    defer col_out.deinit(ally);
    try testing.expectEqualSlices(u32, &ids, col_out.Tuple.elements[0].UInt32);
    try testing.expectEqualStrings("ccc", col_out.Tuple.elements[1].String[2]);
    try testing.expectEqual(@as(usize, 3), col_out.len());
}

test "Int256 round-trips" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var values = [_]i256{ 1, -1, std.math.maxInt(i256) };
    const col_in: Column = .{ .Int256 = &values };
    try writeColumn(&w, col_in);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, testing.allocator, "Int256", 3);
    defer col_out.deinit(testing.allocator);
    try testing.expectEqualSlices(i256, &values, col_out.Int256);
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
    // Pick a column type genuinely outside v0.16.0's coverage.
    try testing.expectError(error.UnsupportedColumnType, readColumn(&r, testing.allocator, "DefinitelyNotAType", 0));
}

test "custom JSON string serialization decodes raw rows" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, 1, .little);
    try wire.writeStringBinary(&w, "{\"a\":1}");
    try wire.writeStringBinary(&w, "null");

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readCustomColumn(&r, testing.allocator, "JSON", 2);
    defer col.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"a\":1}", col.JSON[0]);
    try testing.expectEqualStrings("null", col.JSON[1]);
}

test "custom Dynamic fixture decodes mixed scalar/null rows" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, 1, .little);
    try varint.writeVarUInt(&w, 2);
    try wire.writeStringBinary(&w, "UInt32");
    try wire.writeStringBinary(&w, "String");
    try w.writeAll(&.{ 0, 1, 0xff, 0 });
    try w.writeAll(std.mem.sliceAsBytes(&[_]u32{ 10, 20 }));
    try wire.writeStringBinary(&w, "x");

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readCustomColumn(&r, testing.allocator, "Dynamic", 4);
    defer col.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0xff, 0 }, col.Dynamic.discriminators);
    try testing.expectEqualStrings("UInt32", col.Dynamic.type_names[0]);
    try testing.expectEqual(@as(u32, 20), col.Dynamic.values[0].UInt32[1]);
    try testing.expectEqualStrings("x", col.Dynamic.values[1].String[0]);
}

test "custom Sparse UInt8 materializes dense values" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try varint.writeVarUInt(&w, 2);
    try w.writeAll(std.mem.sliceAsBytes(&[_]u64{ 1, 3 }));
    try w.writeAll(&.{ 9, 7 });

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readCustomColumn(&r, testing.allocator, "Sparse(UInt8)", 5);
    defer col.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0, 9, 0, 7, 0 }, col.UInt8);
}

test "custom serialization count cap trips before allocation" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, 1, .little);
    try varint.writeVarUInt(&w, 257);
    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.CustomSerializationTooLarge, readCustomColumn(&r, testing.allocator, "Dynamic", 0));
}

test "extractLowCardinalityInner peels the wrapper" {
    try testing.expectEqualStrings("String", extractLowCardinalityInner("LowCardinality(String)").?);
    try testing.expectEqualStrings("Nullable(UInt32)", extractLowCardinalityInner("LowCardinality(Nullable(UInt32))").?);
    try testing.expectEqual(@as(?[]const u8, null), extractLowCardinalityInner("String"));
}

test "LowCardinality(String) materializes through dict + indexes" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Wire layout for 4 rows of LC(String) with a 3-element add-keys dict.
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 3, .little); // add_keys size
    try wire.writeStringBinary(&w, "alpha");
    try wire.writeStringBinary(&w, "beta");
    try wire.writeStringBinary(&w, "gamma");
    try w.writeInt(u64, 4, .little); // num_indexes
    try w.writeAll(&[_]u8{ 0, 1, 2, 1 }); // 4 UInt8 indexes

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(String)", 4);
    defer col.deinit(ally);
    try testing.expectEqualStrings("alpha", col.String[0]);
    try testing.expectEqualStrings("beta", col.String[1]);
    try testing.expectEqualStrings("gamma", col.String[2]);
    try testing.expectEqualStrings("beta", col.String[3]);
    try testing.expectEqual(@as(usize, 4), col.len());
}

test "LowCardinality(Nullable(String)) marks index-0 rows as null" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // 5 rows; dict = ["", "x", "y"]. idx 0 is the null sentinel.
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 3, .little);
    try wire.writeStringBinary(&w, "");
    try wire.writeStringBinary(&w, "x");
    try wire.writeStringBinary(&w, "y");
    try w.writeInt(u64, 5, .little);
    try w.writeAll(&[_]u8{ 1, 0, 2, 0, 1 });

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(Nullable(String))", 5);
    defer col.deinit(ally);
    const n = col.Nullable;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1, 0 }, n.mask);
    try testing.expectEqualStrings("x", n.inner.String[0]);
    try testing.expectEqualStrings("y", n.inner.String[2]);
    try testing.expectEqualStrings("x", n.inner.String[4]);
}

test "LowCardinality rejects out-of-range index" {
    const ally = testing.allocator;
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 2, .little);
    try wire.writeStringBinary(&w, "a");
    try wire.writeStringBinary(&w, "b");
    try w.writeInt(u64, 1, .little);
    try w.writeAll(&[_]u8{42}); // out of range for a 2-element dict

    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.LowCardinalityCorruptFrame, readColumn(&r, ally, "LowCardinality(String)", 1));
}

test "LowCardinality(FixedString(4)) materializes preserving width" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 2, .little);
    try w.writeAll("aaaa");
    try w.writeAll("bbbb");
    try w.writeInt(u64, 3, .little);
    try w.writeAll(&[_]u8{ 1, 0, 1 });

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(FixedString(4))", 3);
    defer col.deinit(ally);
    try testing.expectEqual(@as(usize, 4), col.FixedString.width);
    try testing.expectEqualSlices(u8, "bbbbaaaabbbb", col.FixedString.data);
}

test "LowCardinality(Nullable(UInt32)) routes through numeric materializer" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 3, .little);
    try w.writeInt(u32, 0, .little); // null sentinel default
    try w.writeInt(u32, 42, .little);
    try w.writeInt(u32, 99, .little);
    try w.writeInt(u64, 4, .little);
    try w.writeAll(&[_]u8{ 0, 1, 2, 0 });

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(Nullable(UInt32))", 4);
    defer col.deinit(ally);
    const n = col.Nullable;
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 1 }, n.mask);
    try testing.expectEqual(@as(u32, 42), n.inner.UInt32[1]);
    try testing.expectEqual(@as(u32, 99), n.inner.UInt32[2]);
}

test "writeLowCardinality(String) round-trips through readColumn" {
    const ally = testing.allocator;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rows = [_][]u8{
        @constCast("alpha"),
        @constCast("beta"),
        @constCast("alpha"),
        @constCast("gamma"),
        @constCast("beta"),
        @constCast("alpha"),
    };
    const col_in: Column = .{ .String = &rows };
    try writeLowCardinality(&w, ally, "String", col_in, 6);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "LowCardinality(String)", 6);
    defer col_out.deinit(ally);
    try testing.expectEqualStrings("alpha", col_out.String[0]);
    try testing.expectEqualStrings("beta", col_out.String[1]);
    try testing.expectEqualStrings("alpha", col_out.String[2]);
    try testing.expectEqualStrings("gamma", col_out.String[3]);
    try testing.expectEqualStrings("beta", col_out.String[4]);
    try testing.expectEqualStrings("alpha", col_out.String[5]);
}

test "writeLowCardinality(Nullable(UInt32)) round-trips with index-0 sentinel" {
    const ally = testing.allocator;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var mask = [_]u8{ 0, 1, 0, 1, 0 }; // rows 1 and 3 are NULL
    var values = [_]u32{ 100, 0xDEADBEEF, 200, 0xDEADBEEF, 100 };
    var nullable_box: Nullable = .{
        .mask = &mask,
        .inner = .{ .UInt32 = &values },
    };
    const col_in: Column = .{ .Nullable = &nullable_box };
    try writeLowCardinality(&w, ally, "Nullable(UInt32)", col_in, 5);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "LowCardinality(Nullable(UInt32))", 5);
    defer col_out.deinit(ally);
    const n = col_out.Nullable;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1, 0 }, n.mask);
    try testing.expectEqual(@as(u32, 100), n.inner.UInt32[0]);
    try testing.expectEqual(@as(u32, 200), n.inner.UInt32[2]);
    try testing.expectEqual(@as(u32, 100), n.inner.UInt32[4]);
}

test "writeLowCardinality picks UInt8 width for small dicts" {
    const ally = testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Dict size 200 < 256 → UInt8 indexes.
    var values: [200]u32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    const col_in: Column = .{ .UInt32 = &values };
    try writeLowCardinality(&w, ally, "UInt32", col_in, 200);

    // Verify the ser_type field has UInt8 width selected.
    const out = w.buffered();
    // Skip key_version (8 bytes), read ser_type.
    var r: std.Io.Reader = .fixed(out[8..]);
    const ser_type = try r.takeInt(u64, .little);
    try testing.expectEqual(LC_INDEX_UINT8 | LC_HAS_ADDITIONAL_KEYS_BIT, ser_type & ~@as(u64, 0));
}

test "writeLowCardinality picks UInt16 width when dict exceeds 256" {
    const ally = testing.allocator;
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 300 unique values → dict_size = 300 > 256 → UInt16 indexes.
    var values: [300]u32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    const col_in: Column = .{ .UInt32 = &values };
    try writeLowCardinality(&w, ally, "UInt32", col_in, 300);

    const out = w.buffered();
    var r: std.Io.Reader = .fixed(out[8..]);
    const ser_type = try r.takeInt(u64, .little);
    try testing.expectEqual(LC_INDEX_UINT16 | LC_HAS_ADDITIONAL_KEYS_BIT, ser_type);

    // Round-trip through the decoder.
    var r2: std.Io.Reader = .fixed(out);
    const col_out = try readColumn(&r2, ally, "LowCardinality(UInt32)", 300);
    defer col_out.deinit(ally);
    try testing.expectEqual(@as(u32, 0), col_out.UInt32[0]);
    try testing.expectEqual(@as(u32, 299), col_out.UInt32[299]);
}

test "writeLowCardinality(FixedString(4)) round-trips" {
    const ally = testing.allocator;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var data = [_]u8{ 'a','a','a','a',  'b','b','b','b',  'a','a','a','a' };
    const col_in: Column = .{ .FixedString = .{ .width = 4, .data = &data } };
    try writeLowCardinality(&w, ally, "FixedString(4)", col_in, 3);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "LowCardinality(FixedString(4))", 3);
    defer col_out.deinit(ally);
    try testing.expectEqualSlices(u8, &data, col_out.FixedString.data);
}

test "writeLowCardinality rejects type_name vs data union-tag mismatch" {
    const ally = testing.allocator;
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var nums = [_]u32{ 1, 2, 3 };
    const col_in: Column = .{ .UInt32 = &nums };
    // type_name says String but data is UInt32 — must reject locally.
    try testing.expectError(
        error.InsertColumnTypeMismatch,
        writeLowCardinality(&w, ally, "String", col_in, 3),
    );
    // Inverted: type_name says Nullable(...) but data isn't a Nullable.
    try testing.expectError(
        error.InsertColumnTypeMismatch,
        writeLowCardinality(&w, ally, "Nullable(UInt32)", col_in, 3),
    );
}

test "LC(Nullable(UInt32)) round-trips when a non-null row's value equals zero" {
    // Locks the dictionary-duplication contract documented in
    // writeLowCardinality: the null sentinel at idx 0 forces a real
    // zero-valued non-null row into a fresh dict slot, so the reader's
    // mask-from-idx-0 logic doesn't mismark it as NULL.
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var mask = [_]u8{ 0, 1, 0 }; // only row 1 is null
    var values = [_]u32{ 0, 0xDEADBEEF, 7 };
    var nullable_box: Nullable = .{
        .mask = &mask,
        .inner = .{ .UInt32 = &values },
    };
    const col_in: Column = .{ .Nullable = &nullable_box };
    try writeLowCardinality(&w, ally, "Nullable(UInt32)", col_in, 3);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col_out = try readColumn(&r, ally, "LowCardinality(Nullable(UInt32))", 3);
    defer col_out.deinit(ally);
    const n = col_out.Nullable;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0 }, n.mask);
    try testing.expectEqual(@as(u32, 0), n.inner.UInt32[0]);
    try testing.expectEqual(@as(u32, 7), n.inner.UInt32[2]);
}

test "writeLowCardinality on num_rows == 0 emits no payload" {
    const ally = testing.allocator;
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rows: [0][]u8 = .{};
    const col_in: Column = .{ .String = &rows };
    try writeLowCardinality(&w, ally, "String", col_in, 0);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "LowCardinality with UInt64 indexes" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT64 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 2, .little);
    try wire.writeStringBinary(&w, "alpha");
    try wire.writeStringBinary(&w, "beta");
    try w.writeInt(u64, 3, .little);
    try w.writeInt(u64, 1, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, 1, .little);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(String)", 3);
    defer col.deinit(ally);
    try testing.expectEqualStrings("beta", col.String[0]);
    try testing.expectEqualStrings("alpha", col.String[1]);
    try testing.expectEqualStrings("beta", col.String[2]);
}

test "LowCardinality(String) with num_rows == 0 returns empty without reading" {
    const ally = testing.allocator;
    var r: std.Io.Reader = .fixed(&[_]u8{}); // zero bytes available
    const col = try readColumn(&r, ally, "LowCardinality(String)", 0);
    defer col.deinit(ally);
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expectEqual(@as(usize, 0), col.String.len);
}

test "LowCardinality(Nullable(String)) with num_rows == 0 still produces a Nullable wrapper" {
    const ally = testing.allocator;
    var r: std.Io.Reader = .fixed(&[_]u8{});
    const col = try readColumn(&r, ally, "LowCardinality(Nullable(String))", 0);
    defer col.deinit(ally);
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expectEqual(@as(usize, 0), col.Nullable.mask.len);
}

test "LowCardinality with UInt32 indexes" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT32 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 2, .little);
    try wire.writeStringBinary(&w, "hot");
    try wire.writeStringBinary(&w, "cold");
    try w.writeInt(u64, 4, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u32, 0, .little);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(String)", 4);
    defer col.deinit(ally);
    try testing.expectEqualStrings("hot", col.String[0]);
    try testing.expectEqualStrings("cold", col.String[1]);
    try testing.expectEqualStrings("cold", col.String[2]);
    try testing.expectEqualStrings("hot", col.String[3]);
}

test "LowCardinality(UInt32) numeric round-trips via UInt16 indexes" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeInt(u64, LC_KEY_VERSION, .little);
    try w.writeInt(u64, LC_INDEX_UINT16 | LC_HAS_ADDITIONAL_KEYS_BIT, .little);
    try w.writeInt(u64, 3, .little);
    try w.writeInt(u32, 100, .little);
    try w.writeInt(u32, 200, .little);
    try w.writeInt(u32, 300, .little);
    try w.writeInt(u64, 3, .little);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little);

    var r: std.Io.Reader = .fixed(w.buffered());
    const col = try readColumn(&r, ally, "LowCardinality(UInt32)", 3);
    defer col.deinit(ally);
    try testing.expectEqualSlices(u32, &[_]u32{ 300, 100, 200 }, col.UInt32);
}
