//! ClickHouse Hello (handshake) packet writer + reader.
//!
//! Two halves:
//!   - `writeClientHello`  — emits the client→server Hello bytes.
//!   - `readHelloResult`   — reads the next packet, expecting either a
//!                           ServerHello (success) or an Exception
//!                           (server rejected us).
//!
//! The reader's revision-gated conditional fields follow upstream
//! `ClickHouse/src/Client/Connection.cpp::receiveHello` EXACTLY. The
//! field order is NOT monotonic by revision number — it follows the
//! field declaration order in the upstream source — so the gate
//! sequence here is load-bearing for wire compatibility. Re-verified
//! 2026-04 against upstream master.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");
const exception = @import("exception.zig");
const cherror = @import("cherror.zig");

/// Cap on small-string fields in the ServerHello (timezone, display
/// name, etc.). Matches upstream `MAX_HELLO_STRING_SIZE`.
const HELLO_STRING_MAX = wire.MAX_HELLO_STRING;

/// Hard cap on counts-of-things the server can send in ServerHello
/// (password complexity rules, server settings). Real servers send
/// O(10); cap at 4096 to bound memory under a hostile peer.
const SETTINGS_COUNT_MAX: u64 = 4096;
const PASSWORD_RULES_MAX: u64 = 256;

pub const ServerInfo = struct {
    name: []const u8,
    major_version: u64,
    minor_version: u64,
    revision: u64,
    parallel_replicas_version: ?u64,
    timezone: ?[]const u8,
    display_name: ?[]const u8,
    /// Always populated. Upstream Connection.cpp mirrors `version_patch =
    /// server_revision` for pre-54_401 servers that don't send a patch
    /// varint, so the field is never absent in practice.
    version_patch: u64,
    /// Server-side chunked-send capability (server→client direction).
    /// `null` when the gate is inactive at the negotiated revision.
    chunked_send_srv: ?[]const u8,
    /// Server-side chunked-recv capability (client→server direction).
    chunked_recv_srv: ?[]const u8,
    nonce: ?u64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: ServerInfo) void {
        self.allocator.free(self.name);
        if (self.timezone) |tz| self.allocator.free(tz);
        if (self.display_name) |dn| self.allocator.free(dn);
        if (self.chunked_send_srv) |s| self.allocator.free(s);
        if (self.chunked_recv_srv) |s| self.allocator.free(s);
    }

    /// Effective revision for downstream packet code = min(client, server).
    pub fn negotiated(self: ServerInfo, client_rev: u64) u64 {
        return @min(client_rev, self.revision);
    }
};

/// Internal to hello.zig — public surface returns `error.ServerExceptionDuringHello`
/// instead. Kept as a union so the reader can return rich info up to
/// the client without losing the parsed Exception.
pub const HelloResult = union(enum) {
    ok: ServerInfo,
    server_exception: cherror.ServerError,
};

/// Emit the client Hello packet. Bytes match upstream Connection::sendHello.
/// `client_name` identifies the application in the server's `system.query_log`
/// and `system.processes` views — pass null to use the default
/// `protocol.ClientName`. Quant shops correlating prod traffic by tenant
/// should always set this.
pub fn writeClientHello(
    writer: *std.Io.Writer,
    database: []const u8,
    username: []const u8,
    password: []const u8,
    client_name: ?[]const u8,
) std.Io.Writer.Error!void {
    try wire.writeClientPacketId(writer, .Hello);
    try wire.writeStringBinary(writer, client_name orelse protocol.ClientName);
    try varint.writeVarUInt(writer, protocol.ClientVersionMajor);
    try varint.writeVarUInt(writer, protocol.ClientVersionMinor);
    try varint.writeVarUInt(writer, protocol.CLIENT_REVISION);
    try wire.writeStringBinary(writer, database);
    try wire.writeStringBinary(writer, username);
    try wire.writeStringBinary(writer, password);
}

/// Read the server's first packet after a Hello. Either parses a
/// ServerHello into `ServerInfo` or parses an Exception into a
/// `ServerError`. Any other packet id surfaces as `error.UnexpectedPacket`.
pub fn readHelloResult(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !HelloResult {
    const packet = try wire.readServerPacketId(reader);
    switch (packet) {
        .Exception => {
            const err = try exception.readException(reader, allocator);
            return .{ .server_exception = err };
        },
        .Hello => {},
        else => return error.UnexpectedPacket,
    }

    // --- mandatory ServerHello fields ---
    const name = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
    errdefer allocator.free(name);
    const major = try varint.readVarUInt(reader, u64);
    const minor = try varint.readVarUInt(reader, u64);
    const reported_rev = try varint.readVarUInt(reader, u64);

    // The server reports its OWN revision in this field, but emits
    // conditional fields gated on min(its rev, OUR claimed rev). We
    // must mirror the same negotiation when deciding what to read,
    // otherwise we over-read against any server with rev > CLIENT_REVISION.
    const server_rev = @min(reported_rev, protocol.CLIENT_REVISION);

    // Conditional reads — order matches upstream Connection.cpp::receiveHello
    // declaration order, NOT revision-numeric order. Reordering will desync.

    // 54_471: parallel-replicas protocol version. MUST be read FIRST after
    // server_revision (before timezone). Upstream stores it on
    // server_parallel_replicas_protocol_version.
    var parallel_replicas: ?u64 = null;
    if (server_rev >= protocol.Revision.WITH_VERSIONED_PARALLEL_REPLICAS_PROTOCOL) {
        parallel_replicas = try varint.readVarUInt(reader, u64);
    }

    // 54_058: server timezone (e.g. "UTC", "Europe/Moscow").
    var timezone: ?[]const u8 = null;
    if (server_rev >= protocol.Revision.WITH_SERVER_TIMEZONE) {
        timezone = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
    }
    errdefer if (timezone) |tz| allocator.free(tz);

    // 54_372: human-readable server display name.
    var display_name: ?[]const u8 = null;
    if (server_rev >= protocol.Revision.WITH_SERVER_DISPLAY_NAME) {
        display_name = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
    }
    errdefer if (display_name) |dn| allocator.free(dn);

    // 54_401: version_patch. Pre-54_401 servers don't send it; upstream
    // mirrors `version_patch = server_revision` in that case.
    const version_patch: u64 = if (server_rev >= protocol.Revision.WITH_VERSION_PATCH)
        try varint.readVarUInt(reader, u64)
    else
        server_rev;

    // 54_470: chunked-packets capability strings (server→client direction
    // first, then client→server). At pinned CLIENT_REVISION = 54_466 this
    // gate is dormant. Single outer-scope errdefer chain — the previous
    // shape registered a nested errdefer inside the `if` AND an outer
    // guard, which would double-free chunked_send_srv if chunked_recv_srv
    // failed to allocate.
    var chunked_send_srv: ?[]const u8 = null;
    errdefer if (chunked_send_srv) |s| allocator.free(s);
    var chunked_recv_srv: ?[]const u8 = null;
    errdefer if (chunked_recv_srv) |s| allocator.free(s);
    if (server_rev >= protocol.Revision.WITH_CHUNKED_PACKETS) {
        chunked_send_srv = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
        chunked_recv_srv = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
    }

    // 54_461: password complexity rules. Read+discard for v0.16.0-alpha.
    if (server_rev >= protocol.Revision.WITH_PASSWORD_COMPLEXITY_RULES) {
        const count = try varint.readVarUInt(reader, u64);
        if (count > PASSWORD_RULES_MAX) return error.UnexpectedPacket;
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const pat = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
            allocator.free(pat);
            const msg = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
            allocator.free(msg);
        }
    }

    // 54_462: 8-byte interserver-secret-v2 nonce.
    var nonce: ?u64 = null;
    if (server_rev >= protocol.Revision.WITH_INTERSERVER_SECRET_V2) {
        nonce = try reader.takeInt(u64, .little);
    }

    // 54_474: server settings, sentinel-terminated (NOT count-prefixed).
    // Format: { string(name), varint(flags), string(value) }* string("")
    // Mirrors upstream BaseSettings::read in src/Core/BaseSettings.h.
    // Iteration is bounded by SETTINGS_COUNT_MAX so a hostile peer can't
    // loop forever by never sending the empty-name sentinel.
    if (server_rev >= protocol.Revision.WITH_SERVER_SETTINGS) {
        var iters: u64 = 0;
        while (iters < SETTINGS_COUNT_MAX) : (iters += 1) {
            const setting_name = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
            if (setting_name.len == 0) {
                allocator.free(setting_name);
                break;
            }
            allocator.free(setting_name);
            _ = try varint.readVarUInt(reader, u64); // flags
            const setting_val = try wire.readStringOwned(reader, allocator, HELLO_STRING_MAX);
            allocator.free(setting_val);
        } else return error.UnexpectedPacket;
    }

    // 54_477: query plan serialization version. Read+discard.
    if (server_rev >= protocol.Revision.WITH_QUERY_PLAN_SERIALIZATION) {
        _ = try varint.readVarUInt(reader, u64);
    }

    // 54_479: cluster function protocol version. Read+discard.
    if (server_rev >= protocol.Revision.WITH_VERSIONED_CLUSTER_FUNCTION_PROTOCOL) {
        _ = try varint.readVarUInt(reader, u64);
    }

    return .{ .ok = .{
        .name = name,
        .major_version = major,
        .minor_version = minor,
        .revision = reported_rev,
        .parallel_replicas_version = parallel_replicas,
        .timezone = timezone,
        .display_name = display_name,
        .version_patch = version_patch,
        .chunked_send_srv = chunked_send_srv,
        .chunked_recv_srv = chunked_recv_srv,
        .nonce = nonce,
        .allocator = allocator,
    } };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "writeClientHello byte shape" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientHello(&w, "default", "default", "", null);
    const written = w.buffered();

    // First byte: packet id Hello = 0
    try testing.expectEqual(@as(u8, 0), written[0]);
    // Then ClientName length-prefixed (19 chars "ClickHouse clickzig")
    try testing.expectEqual(@as(u8, 19), written[1]);
    try testing.expectEqualStrings("ClickHouse clickzig", written[2..21]);
    // Major (0), minor (16), revision (54_466)
    try testing.expectEqual(@as(u8, 0), written[21]); // varint 0
    try testing.expectEqual(@as(u8, 16), written[22]); // varint 16
    // 54466 varint LSB-first 7-bit groups:
    //   54466 = 425 * 128 + 66  → byte0 = 66 | 0x80 = 0xC2
    //     425 =   3 * 128 + 41  → byte1 = 41 | 0x80 = 0xA9
    //       3 =   0 * 128 +  3  → byte2 = 0x03
    try testing.expectEqual(@as(u8, 0xC2), written[23]);
    try testing.expectEqual(@as(u8, 0xA9), written[24]);
    try testing.expectEqual(@as(u8, 0x03), written[25]);
    // Then "default", "default", "" length-prefixed.
    try testing.expectEqual(@as(u8, 7), written[26]); // db len
    try testing.expectEqualStrings("default", written[27..34]);
    try testing.expectEqual(@as(u8, 7), written[34]); // user len
    try testing.expectEqualStrings("default", written[35..42]);
    try testing.expectEqual(@as(u8, 0), written[42]); // password len = 0
}

test "writeClientHello uses client_name override when provided" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeClientHello(&w, "default", "u", "p", "trading-engine/v3");
    const written = w.buffered();
    // packet id (1 byte) + name length-prefix (1 byte) + name (17 bytes)
    try testing.expectEqual(@as(u8, 0), written[0]);
    try testing.expectEqual(@as(u8, 17), written[1]);
    try testing.expectEqualStrings("trading-engine/v3", written[2..19]);
}

test "readHelloResult parses ServerHello at pinned client revision" {
    const ally = testing.allocator;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Synthesize a ServerHello at revision 54_466 (matches our client pin).
    // At 54_466 the active gates are: timezone, display_name, version_patch,
    // password_complexity_rules (54_461), and nonce (54_462).
    try wire.writeClientPacketId(&w, .Hello); // shares 0 byte with Hello
    try wire.writeStringBinary(&w, "ClickHouse");
    try varint.writeVarUInt(&w, 26); // major
    try varint.writeVarUInt(&w, 3); // minor
    try varint.writeVarUInt(&w, 54_466); // server rev
    try wire.writeStringBinary(&w, "UTC"); // timezone
    try wire.writeStringBinary(&w, "test-display"); // display name
    try varint.writeVarUInt(&w, 9); // version_patch
    try varint.writeVarUInt(&w, 0); // password complexity rules count
    try w.writeInt(u64, 0xDEADBEEF, .little); // nonce

    var r: std.Io.Reader = .fixed(w.buffered());
    const result = try readHelloResult(&r, ally);
    switch (result) {
        .server_exception => |e| {
            e.deinit();
            return error.UnexpectedPacket;
        },
        .ok => |info| {
            defer info.deinit();
            try testing.expectEqualStrings("ClickHouse", info.name);
            try testing.expectEqual(@as(u64, 26), info.major_version);
            try testing.expectEqual(@as(u64, 3), info.minor_version);
            try testing.expectEqual(@as(u64, 54_466), info.revision);
            try testing.expectEqualStrings("UTC", info.timezone.?);
            try testing.expectEqualStrings("test-display", info.display_name.?);
            try testing.expectEqual(@as(u64, 9), info.version_patch);
            try testing.expectEqual(@as(u64, 0xDEADBEEF), info.nonce.?);
            try testing.expectEqual(@as(?u64, null), info.parallel_replicas_version);
            try testing.expectEqual(@as(?[]const u8, null), info.chunked_send_srv);
        },
    }
}

test "readHelloResult routes Exception packet to server_exception" {
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Exception packet body: code, name, message, stack, has_nested
    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Exception));
    try w.writeInt(i32, 194, .little);
    try wire.writeStringBinary(&w, "DB::Exception");
    try wire.writeStringBinary(&w, "Required password");
    try wire.writeStringBinary(&w, "");
    try w.writeByte(0);

    var r: std.Io.Reader = .fixed(w.buffered());
    const result = try readHelloResult(&r, ally);
    switch (result) {
        .ok => |info| {
            info.deinit();
            return error.UnexpectedPacket;
        },
        .server_exception => |e| {
            defer e.deinit();
            try testing.expectEqual(@as(u32, 194), e.code);
            try testing.expectEqualStrings("Required password", e.message);
        },
    }
}

test "readHelloResult against pre-WITH_PASSWORD_COMPLEXITY_RULES server doesn't over-read" {
    // Regression lock: a server at revision 54_429 sits BEFORE
    // WITH_PASSWORD_COMPLEXITY_RULES (54_461), WITH_INTERSERVER_SECRET_V2
    // (54_462), WITH_CHUNKED_PACKETS (54_470), and the parallel-replicas
    // / server-settings / query-plan / cluster gates. Active gates at
    // 54_429: WITH_SERVER_TIMEZONE, WITH_SERVER_DISPLAY_NAME,
    // WITH_VERSION_PATCH only. If any conditional read fires past those
    // (e.g. someone reorders the if-chain, or drops a gate check), we'll
    // try to consume bytes that aren't there and fail with EndOfStream.
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try wire.writeClientPacketId(&w, .Hello);
    try wire.writeStringBinary(&w, "ClickHouse");
    try varint.writeVarUInt(&w, 22);
    try varint.writeVarUInt(&w, 8);
    try varint.writeVarUInt(&w, 54_429);
    try wire.writeStringBinary(&w, "Europe/Moscow");
    try wire.writeStringBinary(&w, "old-server");
    try varint.writeVarUInt(&w, 4);
    // No password rules, no nonce, no chunked, no settings, no plan,
    // no cluster — this is the entire ServerHello at 54_429.

    const written = w.buffered();
    var r: std.Io.Reader = .fixed(written);
    const result = try readHelloResult(&r, ally);
    switch (result) {
        .server_exception => |e| {
            e.deinit();
            return error.UnexpectedPacket;
        },
        .ok => |info| {
            defer info.deinit();
            try testing.expectEqual(@as(u64, 54_429), info.revision);
            try testing.expectEqualStrings("Europe/Moscow", info.timezone.?);
            try testing.expectEqualStrings("old-server", info.display_name.?);
            try testing.expectEqual(@as(u64, 4), info.version_patch);
            try testing.expectEqual(@as(?u64, null), info.nonce);
            try testing.expectEqual(@as(?u64, null), info.parallel_replicas_version);
            try testing.expectEqual(@as(?[]const u8, null), info.chunked_send_srv);
            try testing.expectEqual(@as(?[]const u8, null), info.chunked_recv_srv);
        },
    }
    // The reader must have consumed exactly the bytes we wrote — no over-read.
    try testing.expectEqual(@as(usize, 0), r.bufferedLen());
}

test "ServerInfo.negotiated picks min of client and server" {
    var info: ServerInfo = .{
        .name = "",
        .major_version = 0,
        .minor_version = 0,
        .revision = 54_500,
        .parallel_replicas_version = null,
        .timezone = null,
        .display_name = null,
        .version_patch = 0,
        .chunked_send_srv = null,
        .chunked_recv_srv = null,
        .nonce = null,
        .allocator = testing.allocator,
    };
    try testing.expectEqual(@as(u64, 54_466), info.negotiated(54_466));
    info.revision = 54_400;
    try testing.expectEqual(@as(u64, 54_400), info.negotiated(54_466));
}
