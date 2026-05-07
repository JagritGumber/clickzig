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
const parameters_mod = @import("parameters.zig");
const block_mod = @import("block.zig");
const compression_mod = @import("compression.zig");

pub const Parameters = parameters_mod.Parameters;
pub const ParameterMap = parameters_mod.ParameterMap;

pub const ExternalTable = struct {
    name: []const u8,
    num_rows: u64,
    columns: []const block_mod.InsertColumn,
};

pub const QueryOptions = struct {
    /// User-supplied query id, or empty to let the server auto-generate.
    query_id: []const u8 = "",
    /// How far to run the query before returning. Almost always .Complete.
    stage: protocol.QueryProcessingStage = .Complete,
    /// Compression on the wire. Defaults to Disable; setting Enable
    /// wraps Data block bodies in ClickHouse compression frames.
    compression: protocol.CompressionEnabled = .Disable,
    /// Compression frame method used when `compression == .Enable`.
    compression_method: compression_mod.WriteMethod = .lz4,
    /// Per-query settings overrides. Null = no overrides.
    settings: ?*const settings_mod.Map = null,
    /// Native ClickHouse `{name:Type}` query parameters, emitted in
    /// the WITH_PARAMETERS section. Null = no parameters.
    parameters: ?*const parameters_mod.Parameters = null,
    /// Named Native blocks sent after the Query packet and before the
    /// empty Data terminator. Query text can read them as external
    /// tables by `name`.
    external_tables: []const ExternalTable = &.{},
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
        try parameters_mod.writeParameters(writer, opts.parameters);
    }
}

/// Write the empty Data block that terminates a Query. When compression
/// is on, only the block BODY (BlockInfo + counts) is wrapped in a
/// frame; the packet_id + table_name stay uncompressed since they're
/// the Data packet header, not part of the Block.
pub fn writeEmptyDataTerminator(
    writer: *std.Io.Writer,
    server_revision: u64,
) std.Io.Writer.Error!void {
    try writeDataPacketHeader(writer, "");
    try writeEmptyBlockBody(writer, server_revision);
}

/// Data packet header: packet_id + table_name. Always uncompressed.
pub fn writeDataPacketHeader(
    writer: *std.Io.Writer,
    table_name: []const u8,
) std.Io.Writer.Error!void {
    try wire.writeClientPacketId(writer, .Data);
    try wire.writeStringBinary(writer, table_name);
}

/// Empty Block body (BlockInfo + 0 columns + 0 rows). When compression
/// is enabled the caller serializes this into a buffer first, then
/// wraps via compression.writeFrameLz4.
pub fn writeEmptyBlockBody(
    writer: *std.Io.Writer,
    server_revision: u64,
) std.Io.Writer.Error!void {
    if (server_revision >= protocol.Revision.WITH_BLOCK_INFO) {
        // BlockInfo: field 1 (is_overflows = false), field 2 (bucket_num = -1), then field 0 (end).
        try varint.writeVarUInt(writer, 1);
        try writer.writeByte(0);
        try varint.writeVarUInt(writer, 2);
        try writer.writeInt(i32, -1, .little);
        try varint.writeVarUInt(writer, 0);
    }
    try varint.writeVarUInt(writer, 0);
    try varint.writeVarUInt(writer, 0);
}

const testing = std.testing;

test "writeClientQuery emits Query packet ID first" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientQuery(&w, "SELECT 1", .{}, protocol.CLIENT_REVISION, .{});
    try testing.expectEqual(@as(u8, @intFromEnum(protocol.ClientPacket.Query)), w.buffered()[0]);
}

test "writeClientQuery keeps settings and parameters separate" {
    const ally = testing.allocator;
    var settings: settings_mod.Map = .empty;
    defer settings.deinit(ally);
    try settings.put(ally, "max_threads", "1");

    var params: Parameters = .{};
    defer params.deinit(ally);
    try params.putUInt(ally, "n", @as(u64, 41));

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientQuery(&w, "SELECT {n:UInt64}", .{}, protocol.CLIENT_REVISION, .{
        .settings = &settings,
        .parameters = &params,
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "max_threads") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SELECT {n:UInt64}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'41'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "param_n") == null);
}

test "writeClientQuery omits protocol parameter section below WITH_PARAMETERS gate" {
    const ally = testing.allocator;
    var params: Parameters = .{};
    defer params.deinit(ally);
    try params.putUInt(ally, "n", @as(u64, 41));

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientQuery(&w, "SELECT {n:UInt64}", .{}, protocol.Revision.WITH_PARAMETERS - 1, .{
        .parameters = &params,
    });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "SELECT {n:UInt64}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'41'") == null);
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
