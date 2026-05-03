//! Wire-level primitives for the ClickHouse native protocol.
//!
//! Composes varint length-prefixes with std.Io reader/writer to produce
//! the "string binary" and "packet id" shapes the protocol uses
//! everywhere. Pure functions: no allocation except where explicitly
//! requested (`readStringOwned`).
//!
//! Two flavours of string read:
//!   - `readStringOwned`    — allocates; caller frees. Used in handshake
//!     and any path where the string must outlive the next reader op.
//!   - `readStringBorrowed` — returns a slice into the reader's internal
//!     buffer. Slice is invalidated by the next reader operation that
//!     refills (take/peek/fill/...). Used in hot paths (block decoding)
//!     where the bytes are consumed before the next reader call AND the
//!     reader buffer is sized to fit the largest string in play.
//!
//! The `max_len` argument is REQUIRED on every read and is intentionally
//! not defaulted — choosing the right cap is a per-call concern (4 KiB
//! for handshake fields, 1 MiB for ordinary values, 64 MiB for query
//! payloads). Returning `error.StringTooLong` early prevents a hostile
//! peer from forcing an OOM via a giant length-prefix.

const std = @import("std");
const varint = @import("varint.zig");
const protocol = @import("protocol.zig");

/// Matches upstream ClickHouse `MAX_HELLO_STRING_SIZE`. Used for short
/// metadata fields (timezone, display_name, version strings).
pub const MAX_HELLO_STRING: usize = 4096;

/// Default cap for general-purpose string reads (1 MiB).
pub const MAX_DEFAULT_STRING: usize = 1 << 20;

/// Cap for query-payload strings (64 MiB). Matches upstream practical
/// upper bound on a single query text.
pub const MAX_QUERY_STRING: usize = 1 << 26;

pub const Error = error{
    /// Decoded length-prefix exceeded the caller-supplied `max_len`.
    StringTooLong,
    /// Server packet ID was outside the known `protocol.ServerPacket` range.
    UnknownServerPacket,
};

/// Write a length-prefixed binary string: `varint(len) ++ bytes`.
pub fn writeStringBinary(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try varint.writeVarUInt(writer, @intCast(s.len));
    if (s.len > 0) try writer.writeAll(s);
}

/// Read a length-prefixed binary string into newly allocated memory.
/// Caller owns the returned slice and must free it with `allocator`.
/// Returns `error.StringTooLong` if the length-prefix exceeds `max_len`.
pub fn readStringOwned(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    max_len: usize,
) (std.Io.Reader.ReadAllocError || varint.Error || Error)![]u8 {
    const len = try varint.readVarUInt(reader, u64);
    if (len > max_len) return error.StringTooLong;
    if (len == 0) return try allocator.alloc(u8, 0);
    return try reader.readAlloc(allocator, @intCast(len));
}

/// Read a length-prefixed binary string as a slice into the reader's
/// internal buffer. Zero allocation. The returned slice is INVALIDATED
/// by the next reader operation that may refill the buffer (take/peek/
/// fill/readAlloc/...). Caller must consume or copy before the next op.
///
/// Asserts the reader's buffer capacity is at least `len` bytes; if the
/// length-prefix exceeds `max_len` returns `error.StringTooLong` first
/// (so a hostile peer cannot trigger the assert via a bogus length).
pub fn readStringBorrowed(
    reader: *std.Io.Reader,
    max_len: usize,
) (std.Io.Reader.Error || varint.Error || Error)![]const u8 {
    const len = try varint.readVarUInt(reader, u64);
    if (len > max_len) return error.StringTooLong;
    if (len == 0) return &[_]u8{};
    return try reader.take(@intCast(len));
}

/// Write a client-side packet ID as a varint. Mirrors upstream
/// `Connection::sendData` etc. which write the enum value as varint.
pub fn writeClientPacketId(
    writer: *std.Io.Writer,
    p: protocol.ClientPacket,
) std.Io.Writer.Error!void {
    try varint.writeVarUInt(writer, @intFromEnum(p));
}

/// Read a server-side packet ID as a varint and convert to enum.
/// Returns `error.UnknownServerPacket` if the value is outside the
/// known range. The raw integer is recoverable by widening this to
/// a diagnostic struct in a future iteration; today the byte is dropped.
pub fn readServerPacketId(
    reader: *std.Io.Reader,
) (std.Io.Reader.Error || varint.Error || Error)!protocol.ServerPacket {
    const raw = try varint.readVarUInt(reader, u64);
    return std.enums.fromInt(protocol.ServerPacket, raw) orelse error.UnknownServerPacket;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeStringBinary + readStringOwned round-trip empty" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "");
    const written = w.buffered();
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringOwned(&r, testing.allocator, MAX_DEFAULT_STRING);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "writeStringBinary + readStringOwned round-trip ASCII" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "ClickHouse clickzig");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringOwned(&r, testing.allocator, MAX_DEFAULT_STRING);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ClickHouse clickzig", got);
}

test "writeStringBinary + readStringOwned round-trip multibyte UTF-8" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const s = "héllo \xE2\x9C\x93 世界";
    try writeStringBinary(&w, s);
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringOwned(&r, testing.allocator, MAX_DEFAULT_STRING);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(s, got);
}

test "readStringOwned rejects length above max_len" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "0123456789");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    try testing.expectError(error.StringTooLong, readStringOwned(&r, testing.allocator, 5));
}

test "readStringOwned accepts length at exact max_len boundary" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "0123456789");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringOwned(&r, testing.allocator, 10);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("0123456789", got);
}

test "readStringBorrowed returns slice into fixed buffer" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "borrowed");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringBorrowed(&r, MAX_DEFAULT_STRING);
    try testing.expectEqualStrings("borrowed", got);
}

test "readStringBorrowed empty string yields empty slice" {
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const got = try readStringBorrowed(&r, MAX_DEFAULT_STRING);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "readStringBorrowed rejects length above max_len before read" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStringBinary(&w, "0123456789");
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    try testing.expectError(error.StringTooLong, readStringBorrowed(&r, 5));
}

test "writeClientPacketId + readServerPacketId map by integer" {
    // Hello -> 0 on both client and server side.
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientPacketId(&w, .Hello);
    const written = w.buffered();
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);

    var r: std.Io.Reader = .fixed(written);
    const got = try readServerPacketId(&r);
    try testing.expectEqual(protocol.ServerPacket.Hello, got);
}

test "readServerPacketId rejects unknown id" {
    // 250 is well outside the ServerPacket enum range.
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try varint.writeVarUInt(&w, 250);
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    try testing.expectError(error.UnknownServerPacket, readServerPacketId(&r));
}
