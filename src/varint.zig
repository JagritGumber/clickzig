//! LEB128 varint encoding/decoding for the ClickHouse native protocol.
//!
//! ClickHouse uses unsigned little-endian base-128 (LEB128) varints
//! everywhere a length-prefix or packet ID needs to be transmitted.
//! Format:
//!   - Each byte carries 7 data bits in the low position
//!   - The high bit (0x80) is the continuation flag
//!   - Bytes are emitted least-significant first
//!   - A u64 occupies at most 10 bytes
//!
//! Reference: ClickHouse/src/IO/VarInt.h
//!
//! This module is pure: no Io dependency beyond the Reader/Writer
//! interface, no allocations.

const std = @import("std");

/// Maximum number of bytes a varint encoding of any u64 can occupy.
/// 64 bits / 7 bits-per-byte = 9.14, rounded up = 10.
pub const MAX_BYTES: usize = 10;

pub const Error = error{
    /// More than MAX_BYTES read without seeing a terminator (high bit clear).
    /// Indicates a corrupted stream or hostile peer.
    OverlongVarint,
    /// Decoded value exceeds the maximum representable in the requested type T.
    VarintOverflow,
};

/// Write a u64 as LEB128 varint. Emits 1-10 bytes.
pub fn writeVarUInt(writer: *std.Io.Writer, val: u64) std.Io.Writer.Error!void {
    var v = val;
    while (v >= 0x80) {
        try writer.writeByte(@as(u8, @intCast(v & 0x7F)) | 0x80);
        v >>= 7;
    }
    try writer.writeByte(@as(u8, @intCast(v)));
}

/// Read a LEB128 varint from `reader` and return as type T.
/// Returns `error.OverlongVarint` if more than MAX_BYTES bytes
/// are read without a terminator. Returns `error.VarintOverflow`
/// if the decoded u64 cannot fit in T.
pub fn readVarUInt(reader: *std.Io.Reader, comptime T: type) !T {
    const ti = @typeInfo(T);
    if (ti != .int or ti.int.signedness != .unsigned) {
        @compileError("readVarUInt requires an unsigned integer type");
    }

    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < MAX_BYTES) : (i += 1) {
        const byte = try reader.takeByte();
        // On the 10th byte (i == 9), only bit 0 of the data bits can fit
        // into u64 (shift = 63). Any high data bit set on byte 10 means
        // the encoded value exceeds u64. Reject as VarintOverflow rather
        // than silently dropping bits.
        if (i == MAX_BYTES - 1 and (byte & 0x7E) != 0) return error.VarintOverflow;
        result |= @as(u64, byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            if (result > std.math.maxInt(T)) return error.VarintOverflow;
            return @intCast(result);
        }
        // Only increment shift if another iteration is possible — at i ==
        // MAX_BYTES - 1 the loop will exit on the next condition check
        // and we don't want to overflow u6 (max 63).
        if (i + 1 < MAX_BYTES) shift += 7;
    }
    return error.OverlongVarint;
}

/// Fast-path varint read from a byte slice. Used in hot loops where
/// the caller has already buffered enough bytes (block/row decoder).
/// Returns the decoded value and the number of bytes consumed.
/// Caller should ensure `buf.len >= MAX_BYTES` ideally; otherwise
/// returns `error.EndOfBuffer` if the varint extends past `buf`.
pub inline fn readVarUIntFromSlice(buf: []const u8) !struct { val: u64, len: u8 } {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: u8 = 0;
    while (i < MAX_BYTES) : (i += 1) {
        if (i >= buf.len) return error.EndOfBuffer;
        const byte = buf[i];
        // See readVarUInt: byte 10 may only contain bit 0 of data bits.
        if (i == MAX_BYTES - 1 and (byte & 0x7E) != 0) return error.VarintOverflow;
        result |= @as(u64, byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            return .{ .val = result, .len = i + 1 };
        }
        if (i + 1 < MAX_BYTES) shift += 7;
    }
    return error.OverlongVarint;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Helper: write a value and read it back via the slice fast path.
fn roundTripSlice(val: u64) !void {
    var buf: [MAX_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeVarUInt(&w, val);
    const written = w.buffered();
    const got = try readVarUIntFromSlice(written);
    try testing.expectEqual(val, got.val);
    try testing.expectEqual(@as(u8, @intCast(written.len)), got.len);
}

test "writeVarUInt + readVarUIntFromSlice round-trip" {
    try roundTripSlice(0);
    try roundTripSlice(1);
    try roundTripSlice(127);
    try roundTripSlice(128);
    try roundTripSlice(300);
    try roundTripSlice(16383);
    try roundTripSlice(16384);
    try roundTripSlice(std.math.maxInt(u32));
    try roundTripSlice(std.math.maxInt(u64));
}

test "writeVarUInt of 300 produces 0xAC 0x02" {
    var buf: [MAX_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeVarUInt(&w, 300);
    const written = w.buffered();
    try testing.expectEqual(@as(usize, 2), written.len);
    try testing.expectEqual(@as(u8, 0xAC), written[0]);
    try testing.expectEqual(@as(u8, 0x02), written[1]);
}

test "writeVarUInt of 0 produces single 0x00 byte" {
    var buf: [MAX_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeVarUInt(&w, 0);
    const written = w.buffered();
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);
}

test "readVarUIntFromSlice rejects overlong varint" {
    const overlong = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 };
    const result = readVarUIntFromSlice(&overlong);
    try testing.expectError(error.OverlongVarint, result);
}

test "readVarUInt overflow into u32 when value > 2^32" {
    // Encode u64(2^33) = 8589934592 as varint
    var buf: [MAX_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeVarUInt(&w, @as(u64, 1) << 33);
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const result = readVarUInt(&r, u32);
    try testing.expectError(error.VarintOverflow, result);
}

test "readVarUInt accepts value at exactly maxInt(u32)" {
    var buf: [MAX_BYTES]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeVarUInt(&w, std.math.maxInt(u32));
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const v = try readVarUInt(&r, u32);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), v);
}

test "readVarUIntFromSlice on truncated input returns EndOfBuffer" {
    const truncated = [_]u8{0x80}; // continuation bit set, no follow-up
    const result = readVarUIntFromSlice(&truncated);
    try testing.expectError(error.EndOfBuffer, result);
}

test "byte 10 with high data bits is rejected as VarintOverflow" {
    // Nine 0x80 continuations followed by 0x02 (bit 1 set on byte 10).
    // Bit 1 at shift 63 would set bit 64, outside u64 — must reject.
    const overflow_bits = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 };
    try testing.expectError(error.VarintOverflow, readVarUIntFromSlice(&overflow_bits));

    var r: std.Io.Reader = .fixed(&overflow_bits);
    try testing.expectError(error.VarintOverflow, readVarUInt(&r, u64));
}

test "byte 10 with only bit 0 set decodes to 2^63" {
    // Nine 0x80 continuations followed by 0x01 (bit 0 set on byte 10).
    // Result: 1 << 63 (highest representable u64 power of 2 in this scheme).
    const valid = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    const got = try readVarUIntFromSlice(&valid);
    try testing.expectEqual(@as(u64, 1) << 63, got.val);
    try testing.expectEqual(@as(u8, 10), got.len);
}
