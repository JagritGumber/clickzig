//! ClickHouse server Exception packet parsing.
//!
//! The Exception packet is sent any time the server reports an error,
//! whether during the Hello handshake or in response to a query. Pulled
//! into its own module because both code paths need it.
//!
//! Wire layout (verified against ClickHouse/src/IO/ReadHelpers.cpp ::
//! readException). Bytes follow IMMEDIATELY after the packet ID (which
//! the caller has already consumed):
//!   1. i32 little-endian   — error code (signed; system errors negative)
//!   2. string-binary       — name (typically "DB::Exception")
//!   3. string-binary       — message
//!   4. string-binary       — stack trace (may be empty)
//!   5. u8                  — has_nested flag (per upstream "Obsolete";
//!                            currently always 0; a non-zero value would
//!                            indicate another exception follows, which
//!                            no real server emits — we reject as
//!                            `error.NestedExceptionsUnsupported`
//!                            rather than silently misalign)
//!
//! All strings are heap-allocated from the caller's allocator; the
//! returned ServerError owns them and frees via `ServerError.deinit`.

const std = @import("std");
const wire = @import("wire.zig");
const cherror = @import("cherror.zig");

/// Maximum string length we'll accept for any single Exception field
/// (1 MiB). Server-supplied messages are normally a few KB; stack traces
/// can be larger. This cap is a defensive ceiling — a hostile or
/// misbehaving server sending a multi-GB "message" must not OOM us.
const MAX_EXCEPTION_STRING: usize = 1 << 20;

pub const Error = error{
    /// Server set has_nested=1, which upstream marks "Obsolete" and no
    /// real server emits. We reject rather than try to recurse-and-
    /// silently-misalign the stream.
    NestedExceptionsUnsupported,
};

/// Read an Exception packet body from `reader` (caller has already read
/// the packet-id varint). Returns a `cherror.ServerError` owning all
/// strings; caller must `deinit`.
pub fn readException(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) (std.Io.Reader.Error
    || std.Io.Reader.ReadAllocError
    || @import("varint.zig").Error
    || wire.Error
    || Error)!cherror.ServerError {
    const code_i32 = try reader.takeInt(i32, .little);

    const name = try wire.readStringOwned(reader, allocator, MAX_EXCEPTION_STRING);
    errdefer allocator.free(name);

    const message = try wire.readStringOwned(reader, allocator, MAX_EXCEPTION_STRING);
    errdefer allocator.free(message);

    const stack = try wire.readStringOwned(reader, allocator, MAX_EXCEPTION_STRING);
    errdefer allocator.free(stack);

    const has_nested = try reader.takeByte();
    if (has_nested != 0) return error.NestedExceptionsUnsupported;

    // Convert i32 → u32 for ServerError. Negative codes are valid
    // (system errors) but the public surface is u32 to match upstream
    // ErrorCodes.h which declares them as positive ints; preserve the
    // bit pattern via @bitCast.
    const code: u32 = @bitCast(code_i32);

    // Stack trace is optional in the API surface. Treat empty string
    // as "absent" so callers don't have to special-case len==0.
    const stack_opt: ?[]const u8 = if (stack.len == 0) blk: {
        allocator.free(stack);
        break :blk null;
    } else stack;

    return cherror.ServerError.takeOwned(allocator, code, name, message, stack_opt);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const varint = @import("varint.zig");

/// Encode an Exception body to a buffer (no packet id), for tests.
fn encodeException(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    code: i32,
    name: []const u8,
    message: []const u8,
    stack: []const u8,
    has_nested: u8,
) !void {
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, buf);
    defer buf.* = w.toArrayList();
    try w.writer.writeInt(i32, code, .little);
    try wire.writeStringBinary(&w.writer, name);
    try wire.writeStringBinary(&w.writer, message);
    try wire.writeStringBinary(&w.writer, stack);
    try w.writer.writeByte(has_nested);
}

test "readException parses normal error" {
    const ally = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ally);
    try encodeException(&buf, ally, 60, "DB::Exception", "Table 'foo' not found", "", 0);

    var r: std.Io.Reader = .fixed(buf.items);
    const err = try readException(&r, ally);
    defer err.deinit();
    try testing.expectEqual(@as(u32, 60), err.code);
    try testing.expectEqualStrings("DB::Exception", err.name);
    try testing.expectEqualStrings("Table 'foo' not found", err.message);
    try testing.expectEqual(@as(?[]const u8, null), err.stack_trace);
}

test "readException preserves stack when present" {
    const ally = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ally);
    try encodeException(&buf, ally, 194, "DB::Exception", "Authentication failed", "frame1\nframe2", 0);

    var r: std.Io.Reader = .fixed(buf.items);
    const err = try readException(&r, ally);
    defer err.deinit();
    try testing.expectEqual(@as(u32, 194), err.code);
    try testing.expectEqualStrings("frame1\nframe2", err.stack_trace.?);
}

test "readException rejects has_nested=1" {
    const ally = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ally);
    try encodeException(&buf, ally, 60, "DB::Exception", "msg", "", 1);

    var r: std.Io.Reader = .fixed(buf.items);
    try testing.expectError(error.NestedExceptionsUnsupported, readException(&r, ally));
}

test "readException accepts negative code (bit-cast preserves)" {
    const ally = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ally);
    try encodeException(&buf, ally, -1, "DB::Exception", "system", "", 0);

    var r: std.Io.Reader = .fixed(buf.items);
    const err = try readException(&r, ally);
    defer err.deinit();
    // -1 as i32 → 0xFFFFFFFF as u32 (4_294_967_295)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), err.code);
}

test "readException accepts empty name (some upstream paths emit it)" {
    // Regression lock: name being empty exercises wire.readStringOwned's
    // zero-length alloc branch and the ServerError.deinit path that frees
    // a zero-length slice. Both must remain leak-free.
    const ally = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ally);
    try encodeException(&buf, ally, 60, "", "Table not found", "", 0);

    var r: std.Io.Reader = .fixed(buf.items);
    const err = try readException(&r, ally);
    defer err.deinit();
    try testing.expectEqual(@as(u32, 60), err.code);
    try testing.expectEqual(@as(usize, 0), err.name.len);
    try testing.expectEqualStrings("Table not found", err.message);
    try testing.expectEqual(@as(?[]const u8, null), err.stack_trace);
}
