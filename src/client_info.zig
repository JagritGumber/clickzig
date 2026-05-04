//! ClientInfo struct: identifying metadata sent with every Query packet.
//!
//! Surfaces in the server's `system.query_log` and `system.processes`
//! tables. Multi-tenant operators use these fields to attribute load by
//! service, user, and originating host.
//!
//! Wire format mirrors upstream Interpreters/ClientInfo.cpp::write,
//! gated on the negotiated revision. At the pinned CLIENT_REVISION
//! 54_466, every gate from 54_032 (WITH_CLIENT_INFO) up through
//! 54_465 fires; query-and-line-numbers (54_475) and JWT (54_476)
//! gates stay dormant.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");

pub const QueryKind = enum(u8) {
    NoQuery = 0,
    InitialQuery = 1,
    SecondaryQuery = 2,
};

pub const Interface = enum(u8) {
    TCP = 1,
    HTTP = 2,
    GRPC = 3,
    MySQL = 4,
    PostgreSQL = 5,
    Local = 6,
    BackgroundProcess = 7,
};

pub const ClientInfo = struct {
    query_kind: QueryKind = .InitialQuery,
    initial_user: []const u8 = "",
    initial_query_id: []const u8 = "",
    initial_address: []const u8 = "0.0.0.0:0",
    initial_query_start_time_microseconds: u64 = 0,
    interface: Interface = .TCP,

    // TCP-only fields (apply because we hard-set interface = TCP).
    os_user: []const u8 = "",
    client_hostname: []const u8 = "",
    client_name: []const u8 = protocol.ClientName,
    client_version_major: u64 = protocol.ClientVersionMajor,
    client_version_minor: u64 = protocol.ClientVersionMinor,
    client_tcp_protocol_version: u64 = protocol.CLIENT_REVISION,

    quota_key: []const u8 = "",
    distributed_depth: u64 = 0,
    client_version_patch: u64 = protocol.ClientVersionPatch,

    // OpenTelemetry trace flag — 0 means "no trace context", which
    // skips the trace_id/span_id/tracestate/trace_flags payload.
    opentelemetry_trace_flag: u8 = 0,

    // Parallel-replicas coordination — non-zero only for replica nodes
    // in a distributed query plan. Default 0 = standalone client.
    collaborate_with_initiator: u64 = 0,
    obsolete_count_participating_replicas: u64 = 0,
    number_of_current_replica: u64 = 0,
};

pub fn writeClientInfo(
    writer: *std.Io.Writer,
    info: ClientInfo,
    server_revision: u64,
) std.Io.Writer.Error!void {
    try writer.writeByte(@intFromEnum(info.query_kind));
    if (info.query_kind == .NoQuery) return;

    try wire.writeStringBinary(writer, info.initial_user);
    try wire.writeStringBinary(writer, info.initial_query_id);
    try wire.writeStringBinary(writer, info.initial_address);

    if (server_revision >= protocol.Revision.WITH_INITIAL_QUERY_START_TIME) {
        try writer.writeInt(u64, info.initial_query_start_time_microseconds, .little);
    }

    try writer.writeByte(@intFromEnum(info.interface));
    // Interface == TCP branch: the only interface this client emits.
    try wire.writeStringBinary(writer, info.os_user);
    try wire.writeStringBinary(writer, info.client_hostname);
    try wire.writeStringBinary(writer, info.client_name);
    try varint.writeVarUInt(writer, info.client_version_major);
    try varint.writeVarUInt(writer, info.client_version_minor);
    try varint.writeVarUInt(writer, info.client_tcp_protocol_version);

    if (server_revision >= protocol.Revision.WITH_QUOTA_KEY_IN_CLIENT_INFO) {
        try wire.writeStringBinary(writer, info.quota_key);
    }
    if (server_revision >= protocol.Revision.WITH_DISTRIBUTED_DEPTH) {
        try varint.writeVarUInt(writer, info.distributed_depth);
    }
    if (server_revision >= protocol.Revision.WITH_VERSION_PATCH) {
        try varint.writeVarUInt(writer, info.client_version_patch);
    }
    if (server_revision >= protocol.Revision.WITH_OPENTELEMETRY) {
        try writer.writeByte(info.opentelemetry_trace_flag);
        // trace_id/span_id/tracestate/trace_flags only follow when flag != 0.
    }
    if (server_revision >= protocol.Revision.WITH_PARALLEL_REPLICAS) {
        try varint.writeVarUInt(writer, info.collaborate_with_initiator);
        try varint.writeVarUInt(writer, info.obsolete_count_participating_replicas);
        try varint.writeVarUInt(writer, info.number_of_current_replica);
    }
}

const testing = std.testing;

test "writeClientInfo at pinned revision emits expected prefix" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientInfo(&w, .{}, protocol.CLIENT_REVISION);
    const out = w.buffered();
    // First byte: query_kind = InitialQuery = 1
    try testing.expectEqual(@as(u8, 1), out[0]);
    // Then initial_user (empty: 0), initial_query_id (empty: 0)
    try testing.expectEqual(@as(u8, 0), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
    // initial_address "0.0.0.0:0" (length 9)
    try testing.expectEqual(@as(u8, 9), out[3]);
    try testing.expectEqualStrings("0.0.0.0:0", out[4..13]);
}

test "writeClientInfo NoQuery short-circuits after kind byte" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientInfo(&w, .{ .query_kind = .NoQuery }, protocol.CLIENT_REVISION);
    try testing.expectEqual(@as(usize, 1), w.buffered().len);
    try testing.expectEqual(@as(u8, 0), w.buffered()[0]);
}
