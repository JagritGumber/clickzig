//! ClickHouse compression frame format.
//!
//! STATUS (v0.16.0): The standalone codec works (CityHash 1.0.2 +
//! LZ4 + frame round-trip tests pass). Block-I/O integration is
//! WIP — wiring the frame into the Query → empty-Data-terminator
//! → ResultStream path causes the server to time out waiting for
//! bytes that don't arrive in the expected shape. Suspect the
//! Query packet's own framing (or my LZ4 literal-encoder output)
//! rather than the codec itself. Use Config.compression = .Disable
//! (the default) until this lands.
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
//!   - ZSTD write: not supported (no encoder in 0.16 stdlib); the
//!     Hello negotiation only advertises LZ4, so we never need to
//!     emit a ZSTD frame. Reading is supported for forwards-compat
//!     against servers that ignore the negotiated method.

const std = @import("std");
const cityhash = @import("cityhash.zig");
const lz4 = @import("lz4.zig");
const protocol = @import("protocol.zig");

pub const Method = enum(u8) {
    none = 0x02,
    lz4 = 0x82,
    zstd = 0x90,
};

pub const Error = error{
    UnsupportedCompressionMethod,
    ChecksumMismatch,
    MalformedCompressionHeader,
    OutOfMemory,
} || lz4.Error || std.Io.Writer.Error;

const HEADER_TAIL_BYTES: usize = 9; // method(1) + compressed_size(4) + decompressed_size(4)

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
    const method: Method = std.enums.fromInt(Method, method_byte) orelse return error.UnsupportedCompressionMethod;
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
            var zwin_buf: [std.compress.zstd.default_window_len]u8 = undefined;
            var dec: std.compress.zstd.Decompress = .init(&zin, &zwin_buf, .{});
            var dout: std.Io.Writer = .fixed(decompressed);
            _ = dec.reader.streamRemaining(&dout) catch return error.MalformedCompressionHeader;
            if (dout.buffered().len != decompressed_size) return error.MalformedCompressionHeader;
        },
        .none => @memcpy(decompressed, payload),
    }
    allocator.free(payload);
    return decompressed;
}

/// Write `data` as an LZ4 compression frame to `writer`. Uses the
/// literal-only encoder (no compression). Server accepts and decodes
/// it identically to a "real" LZ4-compressed frame.
pub fn writeFrameLz4(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    data: []const u8,
) Error!void {
    const enc_size = lz4.worstCaseLiteralEncodedSize(data.len);
    const enc = try allocator.alloc(u8, enc_size);
    defer allocator.free(enc);
    const enc_len = try lz4.encodeLiteralBlock(data, enc);

    // Build the hash buffer = method + sizes + payload.
    const compressed_size: u32 = @intCast(HEADER_TAIL_BYTES + enc_len);
    const decompressed_size: u32 = @intCast(data.len);
    var hash_buf = try allocator.alloc(u8, HEADER_TAIL_BYTES + enc_len);
    defer allocator.free(hash_buf);
    hash_buf[0] = @intFromEnum(Method.lz4);
    std.mem.writeInt(u32, hash_buf[1..5], compressed_size, .little);
    std.mem.writeInt(u32, hash_buf[5..9], decompressed_size, .little);
    @memcpy(hash_buf[9..], enc[0..enc_len]);
    const sum = cityhash.cityhash128(hash_buf);

    try writer.writeInt(u64, sum.low, .little);
    try writer.writeInt(u64, sum.high, .little);
    try writer.writeAll(hash_buf);
}

const testing = std.testing;

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
