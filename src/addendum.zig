//! ClickHouse client Addendum packet writer.
//!
//! After the Hello exchange the client sends an Addendum carrying
//! revision-gated capability fields (quota_key, chunked-transport
//! preferences, parallel-replicas protocol version). Mirrors upstream
//! `Connection.cpp::sendAddendum`.
//!
//! There is NO matching `readServerAddendum`. The server's side of these
//! capabilities (chunked send/recv strings) ride inside ServerHello and
//! are already populated on `ServerInfo` by `hello.readHelloResult`.
//!
//! At pinned `CLIENT_REVISION = 54_466` only the (empty) quota_key is
//! emitted; chunked + parallel-replicas gates are dormant until we bump
//! past 54_470 / 54_471 respectively.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");

pub const ClientAddendum = struct {
    /// Per-query/connection quota tag. Most callers pass empty string;
    /// only meaningful when the server has a `quota` configured for the
    /// user. Sent at server_revision >= WITH_QUOTA_KEY (54_458).
    quota_key: []const u8 = "",

    /// Client-preferred mode for client→server data transport.
    /// Valid values per upstream: "chunked", "notchunked",
    /// "chunked_optional", "notchunked_optional". Default
    /// "notchunked_optional" advertises both — server picks.
    proto_send_chunked: []const u8 = "notchunked_optional",

    /// Same, for server→client direction.
    proto_recv_chunked: []const u8 = "notchunked_optional",
};

/// Write the client Addendum. No-op for servers below WITH_ADDENDUM
/// (54_458) — older servers do not expect any addendum bytes after Hello.
/// Field gates match upstream Connection.cpp::sendAddendum exactly.
pub fn writeClientAddendum(
    writer: *std.Io.Writer,
    addendum: ClientAddendum,
    server_revision: u64,
) std.Io.Writer.Error!void {
    if (server_revision < protocol.Revision.WITH_ADDENDUM) return;

    // 54_458: quota_key (string)
    try wire.writeStringBinary(writer, addendum.quota_key);

    // 54_470: chunked transport capability strings (send first, recv second)
    if (server_revision >= protocol.Revision.WITH_CHUNKED_PACKETS) {
        try wire.writeStringBinary(writer, addendum.proto_send_chunked);
        try wire.writeStringBinary(writer, addendum.proto_recv_chunked);
    }

    // 54_471: client's parallel-replicas protocol version (varint).
    if (server_revision >= protocol.Revision.WITH_VERSIONED_PARALLEL_REPLICAS_PROTOCOL) {
        try varint.writeVarUInt(writer, protocol.DBMS_PARALLEL_REPLICAS_PROTOCOL_VERSION);
    }
}

/// True if the server's reported send-side chunking choice means
/// server→client data is being framed in chunks.
pub fn isChunkedSendEngaged(server_send_chunked_srv: []const u8) bool {
    return std.mem.eql(u8, server_send_chunked_srv, "chunked")
        or std.mem.eql(u8, server_send_chunked_srv, "chunked_optional");
}

/// Same, for client→server direction.
pub fn isChunkedRecvEngaged(server_recv_chunked_srv: []const u8) bool {
    return std.mem.eql(u8, server_recv_chunked_srv, "chunked")
        or std.mem.eql(u8, server_recv_chunked_srv, "chunked_optional");
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeClientAddendum is no-op below WITH_ADDENDUM" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientAddendum(&w, .{}, 54_457);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "writeClientAddendum at pinned revision 54_466 writes only quota_key" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientAddendum(&w, .{ .quota_key = "" }, 54_466);
    const written = w.buffered();
    // Empty string = single varint(0) byte
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);
}

test "writeClientAddendum at WITH_CHUNKED_PACKETS adds two strings" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientAddendum(&w, .{}, 54_470);
    const written = w.buffered();
    // quota_key "" (1 byte: 0)
    // proto_send_chunked "notchunked_optional" (1 byte len + 19 chars)
    // proto_recv_chunked "notchunked_optional" (1 byte len + 19 chars)
    try testing.expectEqual(@as(usize, 1 + 20 + 20), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);
    try testing.expectEqual(@as(u8, 19), written[1]);
    try testing.expectEqualStrings("notchunked_optional", written[2..21]);
    try testing.expectEqual(@as(u8, 19), written[21]);
    try testing.expectEqualStrings("notchunked_optional", written[22..41]);
}

test "writeClientAddendum at WITH_VERSIONED_PARALLEL_REPLICAS appends parallel-replicas varint" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientAddendum(&w, .{}, 54_471);
    const written = w.buffered();

    // Encode the expected suffix from the constant rather than asserting
    // a hardcoded byte value — bumping DBMS_PARALLEL_REPLICAS_PROTOCOL_VERSION
    // past 127 would silently break a `written[written.len - 1] == 7` check.
    var expected_suffix: [varint.MAX_BYTES]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&expected_suffix);
    try varint.writeVarUInt(&ew, protocol.DBMS_PARALLEL_REPLICAS_PROTOCOL_VERSION);
    const suffix = ew.buffered();

    // Layout: quota_key(1) + chunked_send(20) + chunked_recv(20) + varint
    const prefix_len: usize = 1 + 20 + 20;
    try testing.expectEqual(prefix_len + suffix.len, written.len);
    try testing.expectEqualSlices(u8, suffix, written[prefix_len..]);
}

test "isChunkedSendEngaged matches upstream-valid strings" {
    try testing.expect(isChunkedSendEngaged("chunked"));
    try testing.expect(isChunkedSendEngaged("chunked_optional"));
    try testing.expect(!isChunkedSendEngaged("notchunked"));
    try testing.expect(!isChunkedSendEngaged("notchunked_optional"));
    try testing.expect(!isChunkedSendEngaged(""));
}

test "isChunkedRecvEngaged reads its own argument (regression)" {
    // Earlier draft had a copy-paste bug where this checked the send field.
    try testing.expect(isChunkedRecvEngaged("chunked"));
    try testing.expect(!isChunkedRecvEngaged("notchunked"));
}
