const std = @import("std");

const clickzig = @import("clickzig");
const block = clickzig.block;
const cityhash = clickzig.cityhash;
const column = clickzig.column;
const compression = clickzig.compression;
const parameters = clickzig.parameters;

const testing = std.testing;
const max_default_string: usize = 1 << 20;

const CappedAllocator = struct {
    child: std.mem.Allocator,
    max_alloc: usize,
    largest_request: usize = 0,

    fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.largest_request = @max(self.largest_request, len);
        if (len > self.max_alloc) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.largest_request = @max(self.largest_request, new_len);
        if (new_len > self.max_alloc) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.largest_request = @max(self.largest_request, new_len);
        if (new_len > self.max_alloc) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn writeVarUInt(writer: *std.Io.Writer, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try writer.writeByte(@as(u8, @intCast(v & 0x7f)) | 0x80);
    }
    try writer.writeByte(@intCast(v));
}

test "audit A1 hostile String length is rejected before row allocation" {
    var wire_buf: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire_buf);
    try writeVarUInt(&writer, std.math.maxInt(u64));

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 128 };
    var reader: std.Io.Reader = .fixed(writer.buffered());

    try testing.expectError(
        error.StringValueTooLarge,
        column.readColumn(&reader, cap.allocator(), "String", 1),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A2 hostile block num_columns is rejected before columns allocation" {
    var wire_buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire_buf);
    try writeVarUInt(&writer, 1_000_000_000);
    try writeVarUInt(&writer, 0);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 128 };
    const table_name = try cap.allocator().alloc(u8, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());

    try testing.expectError(
        error.BlockTooLarge,
        block.readBlockBody(&reader, cap.allocator(), 0, table_name),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A3 hostile block num_rows is rejected before column decoding" {
    var wire_buf: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire_buf);
    try writeVarUInt(&writer, 0);
    try writeVarUInt(&writer, 1_000_000_000);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 128 };
    const table_name = try cap.allocator().alloc(u8, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());

    try testing.expectError(
        error.BlockTooLarge,
        block.readBlockBody(&reader, cap.allocator(), 0, table_name),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A4 hostile Array offsets are rejected before inner allocation" {
    var wire_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, wire_buf[0..8], std.math.maxInt(u64), .little);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed(&wire_buf);

    try testing.expectError(
        error.ColumnTooLarge,
        column.readColumn(&reader, cap.allocator(), "Array(UInt8)", 1),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A5 hostile Map offsets are rejected before key/value allocation" {
    var wire_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, wire_buf[0..8], std.math.maxInt(u64), .little);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed(&wire_buf);

    try testing.expectError(
        error.ColumnTooLarge,
        column.readColumn(&reader, cap.allocator(), "Map(String, UInt32)", 1),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A6 hostile LowCardinality dictionary size is rejected before dict allocation" {
    var wire_buf: [24]u8 = undefined;
    std.mem.writeInt(u64, wire_buf[0..8], 1, .little);
    std.mem.writeInt(u64, wire_buf[8..16], 1 << 9, .little);
    std.mem.writeInt(u64, wire_buf[16..24], std.math.maxInt(u64), .little);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed(&wire_buf);

    try testing.expectError(
        error.ColumnTooLarge,
        column.readColumn(&reader, cap.allocator(), "LowCardinality(String)", 1),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A7 hostile Nested offsets are rejected before inner allocation" {
    var wire_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, wire_buf[0..8], std.math.maxInt(u64), .little);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed(&wire_buf);

    try testing.expectError(
        error.ColumnTooLarge,
        column.readColumn(&reader, cap.allocator(), "Nested(id UInt32, label String)", 1),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit A8 hostile FixedString width times row count is rejected before allocation" {
    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed("");

    try testing.expectError(
        error.ColumnTooLarge,
        column.readColumn(&reader, cap.allocator(), "FixedString(1073741824)", 2),
    );
    try testing.expectEqual(@as(usize, 0), cap.largest_request);
}

test "audit A9 hostile Sparse count is rejected before sparse index allocation" {
    var wire_buf: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire_buf);
    try writeVarUInt(&writer, 2);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 256 };
    var reader: std.Io.Reader = .fixed(writer.buffered());

    try testing.expectError(
        error.CustomSerializationTooLarge,
        column.readCustomColumn(&reader, cap.allocator(), "Sparse(UInt8)", 1),
    );
    try testing.expectEqual(@as(usize, 0), cap.largest_request);
}

test "audit B1 hostile LZ4 decompressed_size is rejected before frame allocation" {
    var tail: [9]u8 = undefined;
    tail[0] = @intFromEnum(compression.Method.lz4);
    std.mem.writeInt(u32, tail[1..5], 9, .little);
    std.mem.writeInt(u32, tail[5..9], std.math.maxInt(u32), .little);
    const sum = cityhash.cityhash128(&tail);

    var frame: [25]u8 = undefined;
    std.mem.writeInt(u64, frame[0..8], sum.low, .little);
    std.mem.writeInt(u64, frame[8..16], sum.high, .little);
    @memcpy(frame[16..25], &tail);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 128 };
    var reader: std.Io.Reader = .fixed(&frame);

    try testing.expectError(
        error.CompressionFrameTooLarge,
        compression.readFrame(&reader, cap.allocator()),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit B2 unsupported compression method is rejected before body allocation" {
    var tail: [9]u8 = undefined;
    tail[0] = 0xff;
    std.mem.writeInt(u32, tail[1..5], 9, .little);
    std.mem.writeInt(u32, tail[5..9], 1024, .little);
    const sum = cityhash.cityhash128(&tail);

    var frame: [25]u8 = undefined;
    std.mem.writeInt(u64, frame[0..8], sum.low, .little);
    std.mem.writeInt(u64, frame[8..16], sum.high, .little);
    @memcpy(frame[16..25], &tail);

    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 128 };
    var reader: std.Io.Reader = .fixed(&frame);

    try testing.expectError(
        error.UnsupportedCompressionMethod,
        compression.readFrame(&reader, cap.allocator()),
    );
    try testing.expect(cap.largest_request <= cap.max_alloc);
}

test "audit C1 oversized query parameter value is rejected before allocation" {
    var cap: CappedAllocator = .{ .child = testing.allocator, .max_alloc = 16 };
    var params: parameters.Parameters = .{};
    defer params.deinit(cap.allocator());

    const too_big = @as([*]const u8, @ptrFromInt(0x1000))[0 .. max_default_string + 1];
    try testing.expectError(
        error.ParameterValueTooLarge,
        params.putRaw(cap.allocator(), "p", too_big),
    );
    try testing.expectEqual(@as(usize, 0), cap.largest_request);
    try testing.expectEqual(@as(u32, 0), params.map.count());
}

test "audit C2 SQL-shaped parameter names are rejected before map mutation" {
    var params: parameters.Parameters = .{};
    defer params.deinit(testing.allocator);

    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "x;DROP_TABLE", "1"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "x) OR 1=1", "1"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "../x", "1"));
    try testing.expectError(error.InvalidParameterName, params.putRaw(testing.allocator, "param-name", "1"));
    try testing.expectEqual(@as(u32, 0), params.map.count());
}
