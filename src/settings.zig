//! Per-query settings serialization.
//!
//! Modern ClickHouse (>= 54_429) wires settings as a sentinel-terminated
//! sequence of (name, flags-varint, value-string) triples — the
//! "STRINGS_WITH_FLAGS" format. Settings are loose-typed: the server
//! interprets the value-string against its known setting type
//! (UInt64, Bool, String, etc.). The terminator is an empty-name
//! string.
//!
//! For the Query packet, the client always emits TWO settings sections
//! (per Connection::sendQuery): the actual query settings, then the
//! query parameters (gated WITH_PARAMETERS = 54_459). Both use this
//! format. An empty map encodes as a single empty-name string.

const std = @import("std");
const wire = @import("wire.zig");
const varint = @import("varint.zig");

pub const Map = std.StringHashMapUnmanaged([]const u8);

/// Setting flags bitmask. Upstream `IMPORTANT = 1` marks settings
/// that older servers MUST recognise. We never set important from the
/// client side (server enforces); leave it 0.
pub const Flags = packed struct(u64) {
    important: bool = false,
    custom: bool = false,
    obsolete: bool = false,
    _padding: u61 = 0,
};

/// Serialize a settings map (or null = empty). Always emits at minimum
/// the empty-name terminator byte, so the wire stream is well-formed
/// even for callers that pass no settings.
pub fn writeSettings(
    writer: *std.Io.Writer,
    map: ?*const Map,
) std.Io.Writer.Error!void {
    try writeSettingsEntries(writer, map);
    // Sentinel: empty name terminates the sequence.
    try wire.writeStringBinary(writer, "");
}

pub fn writeSettingsEntries(
    writer: *std.Io.Writer,
    map: ?*const Map,
) std.Io.Writer.Error!void {
    if (map) |m| {
        var it = m.iterator();
        while (it.next()) |entry| {
            try wire.writeStringBinary(writer, entry.key_ptr.*);
            try varint.writeVarUInt(writer, @bitCast(Flags{}));
            try wire.writeStringBinary(writer, entry.value_ptr.*);
        }
    }
}

const testing = std.testing;

test "writeSettings on null map emits only the sentinel" {
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSettings(&w, null);
    try testing.expectEqual(@as(usize, 1), w.buffered().len);
    try testing.expectEqual(@as(u8, 0), w.buffered()[0]);
}

test "writeSettings round-trips a single entry" {
    const ally = testing.allocator;
    var map: Map = .empty;
    defer map.deinit(ally);
    try map.put(ally, "max_threads", "8");

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSettings(&w, &map);
    const out = w.buffered();

    // Layout: name_len(1) + "max_threads"(11) + flags_varint(1) + value_len(1) + "8"(1) + sentinel(1)
    try testing.expectEqual(@as(usize, 16), out.len);
    try testing.expectEqual(@as(u8, 11), out[0]);
    try testing.expectEqualStrings("max_threads", out[1..12]);
    try testing.expectEqual(@as(u8, 0), out[12]); // flags varint = 0
    try testing.expectEqual(@as(u8, 1), out[13]);
    try testing.expectEqual(@as(u8, '8'), out[14]);
    try testing.expectEqual(@as(u8, 0), out[15]); // sentinel
}
