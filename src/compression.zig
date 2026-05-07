//! ClickHouse compression frame format.
//!
//! STATUS (v0.16.0): Compression is supported as an opt-in feature.
//! Query/INSERT write paths emit ClickHouse-compatible LZ4 or ZSTD
//! frames, and SELECT/INSERT response paths decode LZ4 plus ZSTD
//! frames. The built-in ZSTD writer emits valid raw-block Zstandard
//! frames, so it provides wire compatibility without claiming a
//! compression ratio.
//!
//! Wraps a Data block payload with a checksum + method + size header.
//! Wire layout (header is 25 bytes; payload follows):
//!
//!   [16 bytes] CityHash128 (low64 LE, high64 LE) of (everything below)
//!   [ 1 byte ] compression method (0x82 = LZ4, 0x90 = ZSTD)
//!   [ 4 bytes] LE compressed_size_with_header  (= 1 + 4 + 4 + payload.len = 9 + payload.len)
//!   [ 4 bytes] LE decompressed_size            (raw payload size before LZ4)
//!   [ N bytes] compressed payload (LZ4 block, or ZSTD frame)
//!
//! The CityHash128 covers everything from the method byte onward —
//! both the 9-byte header tail AND the compressed payload. Validation
//! must hash exactly those bytes, no more, no less.
//!
//! For v0.16.0:
//!   - LZ4 read: full pure-Zig decoder (lz4.decompressBlock)
//!   - LZ4 write: literal-only encoder (lz4.encodeLiteralBlock)
//!   - ZSTD read: std.compress.zstd.Decompress
//!   - ZSTD write: raw-block Zstandard frame writer

const std = @import("std");
const cityhash = @import("cityhash.zig");
const lz4 = @import("lz4.zig");
const protocol = @import("protocol.zig");

pub const Method = enum(u8) {
    none = 0x02,
    lz4 = 0x82,
    zstd = 0x90,
};

pub const WriteMethod = enum {
    lz4,
    zstd,
};

pub const Error = error{
    UnsupportedCompressionMethod,
    ChecksumMismatch,
    MalformedCompressionHeader,
    CompressionFrameTooLarge,
    OutOfMemory,
} || lz4.Error || std.Io.Writer.Error;

const HEADER_TAIL_BYTES: usize = 9; // method(1) + compressed_size(4) + decompressed_size(4)
pub const MAX_COMPRESSED_PAYLOAD_BYTES: usize = 1024 * 1024 * 1024;
pub const MAX_DECOMPRESSED_FRAME_BYTES: usize = 1024 * 1024 * 1024;
const ZSTD_MAGIC: u32 = 0xFD2FB528;
const ZSTD_MAX_RAW_BLOCK_SIZE: usize = 128 * 1024;

/// Read one compressed frame from `reader`, decompress, return the
/// raw payload bytes (caller owns).
pub fn readFrame(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) Error![]u8 {
    // 16-byte checksum
    const checksum_low = reader.takeInt(u64, .little) catch return error.MalformedCompressionHeader;
    const checksum_high = reader.takeInt(u64, .little) catch return error.MalformedCompressionHeader;

    // Header tail (covered by checksum).
    const method_byte = reader.takeByte() catch return error.MalformedCompressionHeader;
    const compressed_size = reader.takeInt(u32, .little) catch return error.MalformedCompressionHeader;
    const decompressed_size = reader.takeInt(u32, .little) catch return error.MalformedCompressionHeader;
    if (compressed_size < HEADER_TAIL_BYTES) return error.MalformedCompressionHeader;
    const payload_size: usize = compressed_size - HEADER_TAIL_BYTES;
    if (payload_size > MAX_COMPRESSED_PAYLOAD_BYTES) return error.CompressionFrameTooLarge;
    if (decompressed_size > MAX_DECOMPRESSED_FRAME_BYTES) return error.CompressionFrameTooLarge;
    const method: Method = std.enums.fromInt(Method, method_byte) orelse return error.UnsupportedCompressionMethod;

    // Read payload.
    const payload = try allocator.alloc(u8, payload_size);
    errdefer allocator.free(payload);
    reader.readSliceAll(payload) catch return error.MalformedCompressionHeader;

    // Verify checksum over (method byte + compressed_size + decompressed_size + payload).
    var hash_buf = try allocator.alloc(u8, HEADER_TAIL_BYTES + payload_size);
    defer allocator.free(hash_buf);
    hash_buf[0] = method_byte;
    std.mem.writeInt(u32, hash_buf[1..5], compressed_size, .little);
    std.mem.writeInt(u32, hash_buf[5..9], decompressed_size, .little);
    @memcpy(hash_buf[9..], payload);
    const got = cityhash.cityhash128(hash_buf);
    if (got.low != checksum_low or got.high != checksum_high) return error.ChecksumMismatch;

    // Decompress.
    const decompressed = try allocator.alloc(u8, decompressed_size);
    errdefer allocator.free(decompressed);
    switch (method) {
        .lz4 => {
            const written = try lz4.decompressBlock(payload, decompressed);
            if (written != decompressed_size) return error.MalformedCompressionHeader;
        },
        .zstd => {
            // std.compress.zstd.Decompress streams from a compressed
            // reader to a writer. We have a fixed-size payload + a
            // known output size; bridge via a fixed reader and a
            // fixed writer.
            var zin: std.Io.Reader = .fixed(payload);
            const zwin_buf = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
            defer allocator.free(zwin_buf);
            var dec: std.compress.zstd.Decompress = .init(&zin, zwin_buf, .{});
            var dout: std.Io.Writer = .fixed(decompressed);
            _ = dec.reader.streamRemaining(&dout) catch return error.MalformedCompressionHeader;
            if (dout.buffered().len != decompressed_size) return error.MalformedCompressionHeader;
        },
        .none => {
            if (payload.len != decompressed_size) return error.MalformedCompressionHeader;
            @memcpy(decompressed, payload);
        },
    }
    allocator.free(payload);
    return decompressed;
}

/// Write `data` as an LZ4 compression frame to `writer`. Uses the
/// literal-only encoder (no compression). Server accepts and decodes
/// it identically to a "real" LZ4-compressed frame.
///
/// Allocates a single buffer sized for the full hash input
/// (method + sizes + literal-encoded payload) and encodes the LZ4
/// payload directly into its tail — `enc` and `hash_buf[9..]` would be
/// byte-identical post-encode, so collapsing to one allocation halves
/// peak memory per frame.
pub fn writeFrameLz4(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    data: []const u8,
) Error!void {
    const enc_capacity = lz4.worstCaseLiteralEncodedSize(data.len);
    if (data.len > MAX_DECOMPRESSED_FRAME_BYTES) return error.CompressionFrameTooLarge;
    if (enc_capacity > std.math.maxInt(u32) - HEADER_TAIL_BYTES) return error.CompressionFrameTooLarge;
    var hash_buf = try allocator.alloc(u8, HEADER_TAIL_BYTES + enc_capacity);
    defer allocator.free(hash_buf);
    const enc_len = try lz4.encodeLiteralBlock(data, hash_buf[HEADER_TAIL_BYTES..]);

    const compressed_size: u32 = @intCast(HEADER_TAIL_BYTES + enc_len);
    const decompressed_size: u32 = @intCast(data.len);
    hash_buf[0] = @intFromEnum(Method.lz4);
    std.mem.writeInt(u32, hash_buf[1..5], compressed_size, .little);
    std.mem.writeInt(u32, hash_buf[5..9], decompressed_size, .little);
    const used = hash_buf[0 .. HEADER_TAIL_BYTES + enc_len];
    const sum = cityhash.cityhash128(used);

    try writer.writeInt(u64, sum.low, .little);
    try writer.writeInt(u64, sum.high, .little);
    try writer.writeAll(used);
}

/// Write `data` as a Zstandard frame made of raw blocks. This is a
/// standards-compliant ZSTD stream accepted by ClickHouse. It avoids a
/// third-party encoder while still allowing callers to choose ZSTD as
/// the ClickHouse compression frame method.
pub fn writeFrameZstd(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    data: []const u8,
) Error!void {
    if (data.len > MAX_DECOMPRESSED_FRAME_BYTES) return error.CompressionFrameTooLarge;
    const raw_payload = try encodeZstdRawFrame(allocator, data);
    defer allocator.free(raw_payload);
    if (raw_payload.len > std.math.maxInt(u32) - HEADER_TAIL_BYTES) return error.CompressionFrameTooLarge;

    const compressed_size: u32 = @intCast(HEADER_TAIL_BYTES + raw_payload.len);
    const decompressed_size: u32 = @intCast(data.len);
    var hash_buf = try allocator.alloc(u8, HEADER_TAIL_BYTES + raw_payload.len);
    defer allocator.free(hash_buf);
    hash_buf[0] = @intFromEnum(Method.zstd);
    std.mem.writeInt(u32, hash_buf[1..5], compressed_size, .little);
    std.mem.writeInt(u32, hash_buf[5..9], decompressed_size, .little);
    @memcpy(hash_buf[HEADER_TAIL_BYTES..], raw_payload);
    const sum = cityhash.cityhash128(hash_buf);

    try writer.writeInt(u64, sum.low, .little);
    try writer.writeInt(u64, sum.high, .little);
    try writer.writeAll(hash_buf);
}

fn encodeZstdRawFrame(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeInt(u32, ZSTD_MAGIC, .little);
    // Frame header descriptor:
    // - Frame_Content_Size_Flag = 2 -> 4-byte FCS field
    // - Single_Segment_Flag = 1 -> no window descriptor
    // - no dictionary id, no content checksum
    try out.writer.writeByte(0xA0);
    try out.writer.writeInt(u32, @intCast(data.len), .little);

    var offset: usize = 0;
    while (offset < data.len or (data.len == 0 and offset == 0)) {
        const remaining = data.len - offset;
        const chunk_len = @min(remaining, ZSTD_MAX_RAW_BLOCK_SIZE);
        const last = offset + chunk_len >= data.len;
        const header: u24 = (@as(u24, @intCast(chunk_len)) << 3) | @intFromBool(last);
        try out.writer.writeByte(@intCast(header & 0xff));
        try out.writer.writeByte(@intCast((header >> 8) & 0xff));
        try out.writer.writeByte(@intCast((header >> 16) & 0xff));
        if (chunk_len > 0) try out.writer.writeAll(data[offset .. offset + chunk_len]);
        offset += chunk_len;
        if (data.len == 0) break;
    }
    return out.toOwnedSlice();
}

/// Write `body` to `writer`, optionally framed as an LZ4 compression
/// frame. When `mode == .Disable`, passes bytes through verbatim
/// (no allocation). When `.Enable`, wraps via the requested method.
pub fn writeMaybeCompressed(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    body: []const u8,
    mode: protocol.CompressionEnabled,
    method: WriteMethod,
) Error!void {
    if (mode == .Disable) return writer.writeAll(body);
    switch (method) {
        .lz4 => try writeFrameLz4(writer, allocator, body),
        .zstd => try writeFrameZstd(writer, allocator, body),
    }
}

const testing = std.testing;

fn writeRawFrameForTest(
    writer: *std.Io.Writer,
    method: Method,
    compressed_payload: []const u8,
    decompressed_size: u32,
) !void {
    var hash_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer hash_buf.deinit();
    try hash_buf.writer.writeByte(@intFromEnum(method));
    try hash_buf.writer.writeInt(u32, @intCast(HEADER_TAIL_BYTES + compressed_payload.len), .little);
    try hash_buf.writer.writeInt(u32, decompressed_size, .little);
    try hash_buf.writer.writeAll(compressed_payload);
    const used = hash_buf.written();
    const sum = cityhash.cityhash128(used);
    try writer.writeInt(u64, sum.low, .little);
    try writer.writeInt(u64, sum.high, .little);
    try writer.writeAll(used);
}

test "writeFrameLz4 + readFrame round-trips" {
    const ally = testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const payload = "ClickHouse compression frame round-trip — checksum + LZ4 + payload";
    try writeFrameLz4(&w, ally, payload);

    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try readFrame(&r, ally);
    defer ally.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "writeFrameLz4 + readFrame round-trips an empty block body" {
    const ally = testing.allocator;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrameLz4(&w, ally, "");

    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try readFrame(&r, ally);
    defer ally.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "writeFrameZstd + readFrame round-trips" {
    const ally = testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const payload = "ClickHouse compression frame round-trip through raw ZSTD blocks";
    try writeFrameZstd(&w, ally, payload);

    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try readFrame(&r, ally);
    defer ally.free(got);
    try testing.expectEqualStrings(payload, got);
}

test "writeFrameZstd + readFrame round-trips an empty block body" {
    const ally = testing.allocator;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrameZstd(&w, ally, "");

    var r: std.Io.Reader = .fixed(w.buffered());
    const got = try readFrame(&r, ally);
    defer ally.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "readFrame rejects checksum mismatch" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFrameLz4(&w, ally, "test data");
    // Corrupt one byte in the payload region (after the 25-byte header).
    var corrupted = w.buffered();
    corrupted[30] ^= 0xFF;

    var r: std.Io.Reader = .fixed(corrupted);
    try testing.expectError(error.ChecksumMismatch, readFrame(&r, ally));
}

test "readFrame rejects unsupported method after checksum validation" {
    var tail: [9]u8 = undefined;
    tail[0] = 0xff;
    std.mem.writeInt(u32, tail[1..5], 9, .little);
    std.mem.writeInt(u32, tail[5..9], 0, .little);
    const sum = cityhash.cityhash128(&tail);

    var frame: [25]u8 = undefined;
    std.mem.writeInt(u64, frame[0..8], sum.low, .little);
    std.mem.writeInt(u64, frame[8..16], sum.high, .little);
    @memcpy(frame[16..25], &tail);

    var r: std.Io.Reader = .fixed(&frame);
    try testing.expectError(error.UnsupportedCompressionMethod, readFrame(&r, testing.allocator));
}

test "readFrame rejects none frame with mismatched payload and decompressed sizes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRawFrameForTest(&w, .none, "x", 2);

    var r: std.Io.Reader = .fixed(w.buffered());
    try testing.expectError(error.MalformedCompressionHeader, readFrame(&r, testing.allocator));
}

test "readFrame rejects decompressed size over cap before allocation" {
    var tail: [9]u8 = undefined;
    tail[0] = @intFromEnum(Method.lz4);
    std.mem.writeInt(u32, tail[1..5], 9, .little);
    std.mem.writeInt(u32, tail[5..9], @intCast(MAX_DECOMPRESSED_FRAME_BYTES + 1), .little);
    const sum = cityhash.cityhash128(&tail);

    var frame: [25]u8 = undefined;
    std.mem.writeInt(u64, frame[0..8], sum.low, .little);
    std.mem.writeInt(u64, frame[8..16], sum.high, .little);
    @memcpy(frame[16..25], &tail);

    var r: std.Io.Reader = .fixed(&frame);
    try testing.expectError(error.CompressionFrameTooLarge, readFrame(&r, testing.allocator));
}
