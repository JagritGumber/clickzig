//! Block decoder — header + columns.
//!
//! Wire format mirrors NativeWriter::write:
//!   1. (gate WITH_BLOCK_INFO 51_903) BlockInfo: tag-prefixed fields,
//!      terminated by tag 0. We honour two known tags:
//!        tag 1 → u8 is_overflows
//!        tag 2 → i32 bucket_num
//!   2. varint(num_columns)
//!   3. varint(num_rows)
//!   4. per column:
//!        string(name)
//!        string(type)
//!        (gate WITH_CUSTOM_SERIALIZATION 54_454) u8 has_custom_serialization
//!        — if has_custom_serialization != 0, a serialization-kind stack
//!          follows. We don't support custom serialization yet (relevant
//!          for Sparse, Dynamic, JSON columns); reject with ProtocolError.
//!        column data — handled by column.zig (raw LE for fixed-size,
//!        per-row varint(len) + bytes for String).
//!
//! Block owns its column slice and every Column inside; the typical
//! caller pattern is `defer block.deinit()` and use the `query_allocator`
//! that's reset between queries.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");
const column_mod = @import("column.zig");

pub const BlockInfo = struct {
    is_overflows: bool = false,
    bucket_num: i32 = -1,
};

pub const ColumnEntry = struct {
    name: []const u8, // owned
    type_name: []const u8, // owned
    column: column_mod.Column,
};

pub const Block = struct {
    info: BlockInfo,
    table_name: []const u8, // owned (often empty for SELECT results)
    num_rows: u64,
    columns: []ColumnEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Block) void {
        self.allocator.free(self.table_name);
        for (self.columns) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.type_name);
            entry.column.deinit(self.allocator);
        }
        self.allocator.free(self.columns);
    }

    pub fn isEmpty(self: Block) bool {
        return self.num_rows == 0 and self.columns.len == 0;
    }
};

pub const Error = error{
    /// Server set has_custom_serialization on a column. Decoding the
    /// serialization-kind stack isn't implemented yet (Sparse, Dynamic,
    /// JSON columns trigger this).
    CustomSerializationUnsupported,
    /// BlockInfo carried a tag we don't recognise. Upstream defines
    /// 1=is_overflows, 2=bucket_num, 0=end. New tags would be a
    /// protocol bump that we haven't kept up with — refuse rather than
    /// silently misalign.
    UnknownBlockInfoTag,
};

/// One column to insert: name + ClickHouse type string + the column data.
/// The type-name string MUST exactly match the server's column type
/// declaration ("DateTime('UTC')", "Date", "Nullable(Int32)", etc.) —
/// the canonical TypeId-derived name from `column.canonicalTypeName`
/// is lossy for aliases. For Date/DateTime/Enum columns, pass the
/// original type-name explicitly.
pub const InsertColumn = struct {
    name: []const u8,
    type_name: []const u8,
    data: column_mod.Column,
};

/// Write a fully-populated Block (table_name + BlockInfo + columns).
/// Symmetric to `readBlock`. Used by the INSERT path; the SELECT-side
/// `writeEmptyDataTerminator` in query.zig is the zero-column variant
/// of this for terminating SELECTs.
pub fn writeBlock(
    writer: *std.Io.Writer,
    table_name: []const u8,
    info: BlockInfo,
    num_rows: u64,
    columns: []const InsertColumn,
    server_revision: u64,
) std.Io.Writer.Error!void {
    try wire.writeStringBinary(writer, table_name);
    if (server_revision >= protocol.Revision.WITH_BLOCK_INFO) {
        // Field 1: u8 is_overflows
        try varint.writeVarUInt(writer, 1);
        try writer.writeByte(@intFromBool(info.is_overflows));
        // Field 2: i32 bucket_num
        try varint.writeVarUInt(writer, 2);
        try writer.writeInt(i32, info.bucket_num, .little);
        // Field 0: end
        try varint.writeVarUInt(writer, 0);
    }
    try varint.writeVarUInt(writer, columns.len);
    try varint.writeVarUInt(writer, num_rows);
    for (columns) |col| {
        try wire.writeStringBinary(writer, col.name);
        try wire.writeStringBinary(writer, col.type_name);
        if (server_revision >= protocol.Revision.WITH_CUSTOM_SERIALIZATION) {
            try writer.writeByte(0); // we never emit custom-serialization columns
        }
        try column_mod.writeColumn(writer, col.data);
    }
}

pub fn readBlock(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    server_revision: u64,
) !Block {
    const table_name = try wire.readStringOwned(reader, allocator, wire.MAX_DEFAULT_STRING);
    errdefer allocator.free(table_name);

    var info: BlockInfo = .{};
    if (server_revision >= protocol.Revision.WITH_BLOCK_INFO) {
        while (true) {
            const tag = try varint.readVarUInt(reader, u64);
            if (tag == 0) break;
            switch (tag) {
                1 => info.is_overflows = (try reader.takeByte()) != 0,
                2 => info.bucket_num = try reader.takeInt(i32, .little),
                else => return error.UnknownBlockInfoTag,
            }
        }
    }

    const num_columns = try varint.readVarUInt(reader, u64);
    const num_rows = try varint.readVarUInt(reader, u64);

    const columns = try allocator.alloc(ColumnEntry, @intCast(num_columns));
    errdefer allocator.free(columns);
    var built: usize = 0;
    errdefer for (columns[0..built]) |e| {
        allocator.free(e.name);
        allocator.free(e.type_name);
        e.column.deinit(allocator);
    };

    var col_i: usize = 0;
    while (col_i < num_columns) : (col_i += 1) {
        const col_name = try wire.readStringOwned(reader, allocator, wire.MAX_DEFAULT_STRING);
        errdefer allocator.free(col_name);
        const col_type = try wire.readStringOwned(reader, allocator, wire.MAX_DEFAULT_STRING);
        errdefer allocator.free(col_type);

        if (server_revision >= protocol.Revision.WITH_CUSTOM_SERIALIZATION) {
            const has_custom = try reader.takeByte();
            if (has_custom != 0) return error.CustomSerializationUnsupported;
        }

        const col = try column_mod.readColumn(reader, allocator, col_type, num_rows);
        columns[col_i] = .{ .name = col_name, .type_name = col_type, .column = col };
        built = col_i + 1;
    }

    return .{
        .info = info,
        .table_name = table_name,
        .num_rows = num_rows,
        .columns = columns,
        .allocator = allocator,
    };
}

const testing = std.testing;

test "readBlock decodes a single-column UInt8 block at pinned revision" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Encode block: empty table_name + BlockInfo (is_overflows=false,
    // bucket_num=-1, end) + 1 column + 1 row + col_name "x" + type "UInt8"
    // + custom_serialization=0 + value 42.
    try wire.writeStringBinary(&w, "");
    try varint.writeVarUInt(&w, 1);
    try w.writeByte(0); // is_overflows = false
    try varint.writeVarUInt(&w, 2);
    try w.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&w, 0); // BlockInfo end
    try varint.writeVarUInt(&w, 1); // num_columns
    try varint.writeVarUInt(&w, 1); // num_rows
    try wire.writeStringBinary(&w, "x");
    try wire.writeStringBinary(&w, "UInt8");
    try w.writeByte(0); // has_custom_serialization = 0
    try w.writeByte(42); // the value

    var r: std.Io.Reader = .fixed(w.buffered());
    const block = try readBlock(&r, testing.allocator, protocol.CLIENT_REVISION);
    defer block.deinit();
    try testing.expectEqualStrings("", block.table_name);
    try testing.expectEqual(@as(u64, 1), block.num_rows);
    try testing.expectEqual(@as(usize, 1), block.columns.len);
    try testing.expectEqualStrings("x", block.columns[0].name);
    try testing.expectEqualStrings("UInt8", block.columns[0].type_name);
    try testing.expectEqual(@as(u8, 42), block.columns[0].column.UInt8[0]);
}

test "readBlock decodes an empty (0-row 0-col) block" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try wire.writeStringBinary(&w, "");
    try varint.writeVarUInt(&w, 1);
    try w.writeByte(0);
    try varint.writeVarUInt(&w, 2);
    try w.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&w, 0);
    try varint.writeVarUInt(&w, 0); // num_columns
    try varint.writeVarUInt(&w, 0); // num_rows

    var r: std.Io.Reader = .fixed(w.buffered());
    const block = try readBlock(&r, testing.allocator, protocol.CLIENT_REVISION);
    defer block.deinit();
    try testing.expect(block.isEmpty());
}

test "writeBlock + readBlock round-trip a 2-col 3-row block" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ids = [_]u32{ 1, 2, 3 };
    var names = [_][]u8{ @constCast("alpha"), @constCast("beta"), @constCast("gamma") };
    const cols = [_]InsertColumn{
        .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &names } },
    };
    try writeBlock(&w, "", .{}, 3, &cols, protocol.CLIENT_REVISION);

    var r: std.Io.Reader = .fixed(w.buffered());
    const block = try readBlock(&r, ally, protocol.CLIENT_REVISION);
    defer block.deinit();
    try testing.expectEqual(@as(u64, 3), block.num_rows);
    try testing.expectEqual(@as(usize, 2), block.columns.len);
    try testing.expectEqualSlices(u32, &ids, block.columns[0].column.UInt32);
    try testing.expectEqualStrings("beta", block.columns[1].column.String[1]);
}

test "readBlock rejects custom_serialization byte != 0" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try wire.writeStringBinary(&w, "");
    try varint.writeVarUInt(&w, 0); // BlockInfo end immediately
    try varint.writeVarUInt(&w, 1);
    try varint.writeVarUInt(&w, 1);
    try wire.writeStringBinary(&w, "x");
    try wire.writeStringBinary(&w, "Sparse(UInt8)");
    try w.writeByte(1); // has_custom_serialization = 1 → reject

    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.CustomSerializationUnsupported, readBlock(&r, testing.allocator, protocol.CLIENT_REVISION));
}
