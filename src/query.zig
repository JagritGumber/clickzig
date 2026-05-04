//! Query packet writer.
//!
//! ClickHouse expects the client to follow a Query packet with at least
//! one Data packet — for a SELECT, that's an empty block signalling
//! "no external table data, no INSERT rows." This module writes both.
//!
//! Wire shape per upstream Connection::sendQuery (verified at master):
//!   1. varint(ClientPacket.Query)
//!   2. string(query_id)                                 — empty for auto-generate
//!   3. ClientInfo (gated WITH_CLIENT_INFO 54_032)
//!   4. Settings  (gated WITH_SETTINGS_SERIALIZED_AS_STRINGS 54_429)
//!   5. string(interserver_secret)                       — gated WITH_INTERSERVER_SECRET 54_441 (we send empty)
//!   6. varint(QueryProcessingStage)                     — usually .Complete
//!   7. varint(compression flag)                         — 0 or 1
//!   8. string(query)
//!   9. Settings (parameters)                            — gated WITH_PARAMETERS 54_459
//!  10. Empty Data block: varint(ClientPacket.Data) + string("") + BlockInfo + 0 cols + 0 rows
//!
//! The empty terminator block is the cue that the client is done sending
//! Query bytes and expects the server to start streaming results.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");
const client_info_mod = @import("client_info.zig");
const settings_mod = @import("settings.zig");

pub const QueryOptions = struct {
    /// User-supplied query id, or empty to let the server auto-generate.
    query_id: []const u8 = "",
    /// How far to run the query before returning. Almost always .Complete.
    stage: protocol.QueryProcessingStage = .Complete,
    /// Compression on the wire. Must agree with what was negotiated in
    /// the Hello packet (we currently always send Disable; LZ4/ZSTD
    /// land later in v0.16.0 once the codec is in).
    compression: protocol.CompressionEnabled = .Disable,
    /// Per-query settings overrides. Null = no overrides.
    settings: ?*const settings_mod.Map = null,
    /// Substituted query parameters (Connection.cpp gates at 54_459).
    /// Null = no parameters.
    parameters: ?*const settings_mod.Map = null,
};

pub fn writeClientQuery(
    writer: *std.Io.Writer,
    query: []const u8,
    info: client_info_mod.ClientInfo,
    server_revision: u64,
    opts: QueryOptions,
) std.Io.Writer.Error!void {
    try wire.writeClientPacketId(writer, .Query);
    try wire.writeStringBinary(writer, opts.query_id);

    if (server_revision >= protocol.Revision.WITH_CLIENT_INFO) {
        try client_info_mod.writeClientInfo(writer, info, server_revision);
    }

    // Settings — STRINGS_WITH_FLAGS format is the only one we support
    // (gate fires at 54_429, well below pinned 54_466).
    try settings_mod.writeSettings(writer, opts.settings);

    // Interserver secret hash. We're always a regular client, never an
    // interserver replica, so emit empty string at the gate.
    if (server_revision >= protocol.Revision.WITH_INTERSERVER_SECRET) {
        try wire.writeStringBinary(writer, "");
    }

    try varint.writeVarUInt(writer, @intFromEnum(opts.stage));
    try varint.writeVarUInt(writer, @intFromEnum(opts.compression));
    try wire.writeStringBinary(writer, query);

    // Query parameters — gated. Empty map encodes to a single sentinel byte.
    if (server_revision >= protocol.Revision.WITH_PARAMETERS) {
        try settings_mod.writeSettings(writer, opts.parameters);
    }
}

/// Write the empty Data block that terminates a Query (signals "no
/// external/INSERT data follows; server, please respond"). Block layout:
///   varint(ClientPacket.Data)
///   string(table_name = "")
///   BlockInfo: varint(field 1=is_overflows) u8(0) varint(field 2=bucket_num) i32(-1) varint(0=end)
///   varint(0 columns)
///   varint(0 rows)
pub fn writeEmptyDataTerminator(
    writer: *std.Io.Writer,
    server_revision: u64,
) std.Io.Writer.Error!void {
    try wire.writeClientPacketId(writer, .Data);
    try wire.writeStringBinary(writer, ""); // table_name
    if (server_revision >= protocol.Revision.WITH_BLOCK_INFO) {
        // BlockInfo: field 1 (is_overflows = false), field 2 (bucket_num = -1), then field 0 (end).
        try varint.writeVarUInt(writer, 1);
        try writer.writeByte(0); // is_overflows = false
        try varint.writeVarUInt(writer, 2);
        try writer.writeInt(i32, -1, .little); // bucket_num
        try varint.writeVarUInt(writer, 0); // end of fields
    }
    try varint.writeVarUInt(writer, 0); // num_columns
    try varint.writeVarUInt(writer, 0); // num_rows
}

const testing = std.testing;

test "writeClientQuery emits Query packet ID first" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientQuery(&w, "SELECT 1", .{}, protocol.CLIENT_REVISION, .{});
    try testing.expectEqual(@as(u8, @intFromEnum(protocol.ClientPacket.Query)), w.buffered()[0]);
}

test "writeEmptyDataTerminator at pinned revision emits the BlockInfo prelude" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEmptyDataTerminator(&w, protocol.CLIENT_REVISION);
    const out = w.buffered();
    // Data packet id (2), then empty table name (1 byte = 0)
    try testing.expectEqual(@as(u8, @intFromEnum(protocol.ClientPacket.Data)), out[0]);
    try testing.expectEqual(@as(u8, 0), out[1]);
    // BlockInfo: 1, 0, 2, then i32 LE -1, then 0 (end)
    try testing.expectEqual(@as(u8, 1), out[2]);
    try testing.expectEqual(@as(u8, 0), out[3]);
    try testing.expectEqual(@as(u8, 2), out[4]);
    // i32 LE -1 = FF FF FF FF
    try testing.expectEqual(@as(u8, 0xFF), out[5]);
    try testing.expectEqual(@as(u8, 0xFF), out[6]);
    try testing.expectEqual(@as(u8, 0xFF), out[7]);
    try testing.expectEqual(@as(u8, 0xFF), out[8]);
    try testing.expectEqual(@as(u8, 0), out[9]); // BlockInfo end
    try testing.expectEqual(@as(u8, 0), out[10]); // 0 columns
    try testing.expectEqual(@as(u8, 0), out[11]); // 0 rows
}
