//! ClickHouse native-protocol constants.
//!
//! This module is pure data: revision numbers, packet IDs, compression
//! method bytes, and small enums. No I/O, no allocation, no Io dependency.
//! Anything that *speaks* the protocol lives in `packet.zig` (low-level)
//! and `connection.zig` (high-level handshake/query flow).

const std = @import("std");

// --- DBMS revision -----------------------------------------------------------
//
// The "TCP protocol version" the client claims to speak. The server compares
// against its own revision and downgrades behaviour on the wire to whichever
// is lower. New revisions add fields to existing packets; older revisions
// simply skip those fields.
//
// We claim a recent stable revision. If the server is older, the negotiated
// effective revision will be the server's. If the server is newer, the
// server will not send fields above our revision.
//
// Bumping this value requires implementing the additional packet fields
// introduced between the old and new revisions.

/// Pinned to 54_466 for v0.16.0-alpha — sits at a stable plateau before
/// chunked-packets (54_470), parallel-replicas (54_471), and addendum-required
/// (54_458 — but addendum complexity grows past 54_470). Bumping requires
/// implementing the additional packet fields introduced between revisions.
/// Verified against ClickHouse/src/Core/ProtocolDefines.h master.
pub const CLIENT_REVISION: u64 = 54_466;

/// Constant value sent in addendum's parallel-replicas varint when the
/// gate is active. Current upstream value is 7 as of CH 26.x — verify
/// against ProtocolDefines.h at bump time.
pub const DBMS_PARALLEL_REPLICAS_PROTOCOL_VERSION: u64 = 7;

/// Revisions at which specific fields/features were added on the server side.
/// Used by encoders/decoders to gate optional fields.
/// Values verified against ClickHouse/src/Core/ProtocolDefines.h master.
pub const Revision = struct {
    pub const WITH_TEMPORARY_TABLES: u64 = 50_264;
    pub const WITH_TOTAL_ROWS_IN_PROGRESS: u64 = 51_554;
    pub const WITH_BLOCK_INFO: u64 = 51_903;
    pub const WITH_CLIENT_INFO: u64 = 54_032;
    pub const WITH_SERVER_TIMEZONE: u64 = 54_058;
    pub const WITH_QUOTA_KEY_IN_CLIENT_INFO: u64 = 54_060;
    pub const WITH_SERVER_DISPLAY_NAME: u64 = 54_372;
    pub const WITH_VERSION_PATCH: u64 = 54_401;
    pub const WITH_SERVER_LOGS: u64 = 54_406;
    pub const WITH_CLIENT_WRITE_INFO: u64 = 54_420;
    pub const WITH_SETTINGS_SERIALIZED_AS_STRINGS: u64 = 54_429;
    pub const WITH_INTERSERVER_SECRET: u64 = 54_441;
    pub const WITH_OPENTELEMETRY: u64 = 54_442;
    pub const WITH_DISTRIBUTED_DEPTH: u64 = 54_448;
    pub const WITH_QUERY_STAGE: u64 = 54_453;
    pub const WITH_INITIAL_QUERY_START_TIME: u64 = 54_449;
    pub const WITH_ADDENDUM: u64 = 54_458;
    pub const WITH_QUOTA_KEY: u64 = 54_458;
    pub const WITH_PARAMETERS: u64 = 54_459;
    pub const WITH_SERVER_QUERY_TIME_IN_PROGRESS: u64 = 54_460;
    pub const WITH_PASSWORD_COMPLEXITY_RULES: u64 = 54_461;
    pub const WITH_INTERSERVER_SECRET_V2: u64 = 54_462;
    pub const WITH_CHUNKED_PACKETS: u64 = 54_470;
    pub const WITH_VERSIONED_PARALLEL_REPLICAS_PROTOCOL: u64 = 54_471;
    pub const WITH_INTERSERVER_EXTERNALLY_GRANTED_ROLES: u64 = 54_472;
    pub const WITH_SERVER_SETTINGS: u64 = 54_474;
    pub const WITH_QUERY_PLAN_SERIALIZATION: u64 = 54_477;
    pub const WITH_VERSIONED_CLUSTER_FUNCTION_PROTOCOL: u64 = 54_479;
};

/// Packet types sent by the client to the server.
pub const ClientPacket = enum(u64) {
    /// Initial handshake; sent first, exactly once per connection.
    Hello = 0,
    /// A query to execute (with settings, query_id, client_info).
    Query = 1,
    /// A block of data (used for INSERT and external table data).
    Data = 2,
    /// Cancel the in-flight query.
    Cancel = 3,
    /// Heartbeat / liveness check.
    Ping = 4,
    /// Request schema for a table (used for INSERT preflight).
    TablesStatusRequest = 5,
    /// Sent at the end of a chunked SCALAR write.
    KeepAlive = 6,
    /// Block of scalar values for parameterised queries.
    Scalar = 7,
    /// Ignore-Part for distributed queries.
    IgnoredPartUUIDs = 8,
    /// Read-only request to refresh part/UUIDs.
    ReadTaskResponse = 9,
    /// Resp to MergeTreeReadTaskRequest.
    MergeTreeReadTaskResponse = 10,
    /// Reload all sources of dictionaries (XDBC bridges, etc.).
    SSHChallengeRequest = 11,
    /// Response to server's SSH challenge.
    SSHChallengeResponse = 12,
};

/// Packet types received from the server.
pub const ServerPacket = enum(u64) {
    /// Initial handshake response.
    Hello = 0,
    /// A block of result data.
    Data = 1,
    /// Server-side error (will be followed by code, message, stack).
    Exception = 2,
    /// Progress info for the in-flight query.
    Progress = 3,
    /// Heartbeat reply.
    Pong = 4,
    /// Query has finished, no more data.
    EndOfStream = 5,
    /// Profile info (rows read, bytes processed).
    ProfileInfo = 6,
    /// Totals row block (for queries WITH TOTALS).
    Totals = 7,
    /// Extremes block (for queries WITH EXTREMES).
    Extremes = 8,
    /// Reply to TablesStatusRequest.
    TablesStatusResponse = 9,
    /// Server-side log entries (when send_logs_level is set).
    Log = 10,
    /// Table columns metadata (response to DESCRIBE).
    TableColumns = 11,
    /// Part UUIDs for distributed query coordination.
    PartUUIDs = 12,
    /// Server requests next chunk of a distributed read task.
    ReadTaskRequest = 13,
    /// Aggregated profile events (one per stage).
    ProfileEvents = 14,
    /// Server requests a MergeTree read task (newer protocol).
    MergeTreeReadTaskRequest = 15,
    /// Server requests answer to an SSH challenge.
    SSHChallenge = 16,
};

/// Compression method bytes used in the Data block header on the wire.
/// These are the bytes the server expects to identify the compression used.
pub const CompressionMethodByte = enum(u8) {
    None = 0x02,
    LZ4 = 0x82,
    ZSTD = 0x90,
};

/// Whether the client opts into compression for Data blocks.
/// Sent during the Hello handshake.
pub const CompressionEnabled = enum(u8) {
    Disable = 0,
    Enable = 1,
};

/// Whether the client opts into encrypted connection.
pub const SecureEnabled = enum(u8) {
    Disable = 0,
    Enable = 1,
};

/// QueryProcessingStage: how far the server should run the query before
/// returning data. Most clients use Complete (run to completion).
pub const QueryProcessingStage = enum(u64) {
    FetchColumns = 0,
    WithMergeableState = 1,
    Complete = 2,
    WithMergeableStateAfterAggregation = 3,
    WithMergeableStateAfterAggregationAndLimit = 4,
};

/// Default client identification strings.
pub const ClientName = "ClickHouse clickzig";
pub const ClientVersionMajor: u64 = 0;
pub const ClientVersionMinor: u64 = 16;
pub const ClientVersionPatch: u64 = 0;

// --- tests ---

test "CLIENT_REVISION is sane" {
    try std.testing.expect(CLIENT_REVISION >= 54_400);
    try std.testing.expect(CLIENT_REVISION <= 99_999);
}

test "ClientPacket enum tags are stable wire bytes" {
    try std.testing.expectEqual(@as(u64, 0), @intFromEnum(ClientPacket.Hello));
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(ClientPacket.Query));
    try std.testing.expectEqual(@as(u64, 4), @intFromEnum(ClientPacket.Ping));
}

test "ServerPacket enum tags are stable wire bytes" {
    try std.testing.expectEqual(@as(u64, 0), @intFromEnum(ServerPacket.Hello));
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(ServerPacket.Data));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(ServerPacket.Exception));
    try std.testing.expectEqual(@as(u64, 5), @intFromEnum(ServerPacket.EndOfStream));
}

test "CompressionMethodByte values match wire bytes" {
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(CompressionMethodByte.None));
    try std.testing.expectEqual(@as(u8, 0x82), @intFromEnum(CompressionMethodByte.LZ4));
    try std.testing.expectEqual(@as(u8, 0x90), @intFromEnum(CompressionMethodByte.ZSTD));
}

test "client identification strings are non-empty" {
    try std.testing.expect(ClientName.len > 0);
    try std.testing.expectEqualStrings("ClickHouse clickzig", ClientName);
}
