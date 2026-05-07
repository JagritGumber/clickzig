//! Server-response drain after a Query packet.
//!
//! `ResultStream.next()` reads one server packet at a time until it
//! sees `EndOfStream` (or `Exception`, which terminates as well).
//! Callers iterate:
//!
//!     var stream = try client.query("SELECT 1", null, .{});
//!     defer stream.deinit();
//!     while (try stream.next()) |packet| {
//!         switch (packet) {
//!             .data => |block| { defer block.deinit(); ... },
//!             .progress => |p| { ... },
//!             .end_of_stream => break,
//!             .exception => |exc| { defer exc.deinit(); ... },
//!             else => {},
//!         }
//!     }
//!
//! State machine: the parent Client is `.busy` while the stream is
//! live; the stream sets it back to `.ready` (or `.broken` on error)
//! when it sees the terminator packet or an Exception. Calling
//! `next()` after that returns `null`.
//!
//! This file exceeds 100 lines because the packet-type dispatch is
//! the central response loop and splitting it into per-packet helpers
//! would just add indirection without clarity.

const std = @import("std");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");
const varint = @import("varint.zig");
const exception = @import("exception.zig");
const block_mod = @import("block.zig");
const cherror = @import("cherror.zig");
const compression_mod = @import("compression.zig");
const transport_mod = @import("transport.zig");

pub const Progress = struct {
    read_rows: u64 = 0,
    read_bytes: u64 = 0,
    total_rows_to_read: u64 = 0,
    total_bytes_to_read: u64 = 0,
    written_rows: u64 = 0,
    written_bytes: u64 = 0,
    elapsed_ns: u64 = 0,
};

pub const ProfileInfo = struct {
    rows: u64,
    blocks: u64,
    bytes: u64,
    applied_limit: bool,
    rows_before_limit: u64,
    calculated_rows_before_limit: bool,
};

pub const TableColumns = struct {
    /// Owned. Free with the caller's allocator.
    table_name: []const u8,
    columns_metadata: []const u8,

    pub fn deinit(self: TableColumns, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        allocator.free(self.columns_metadata);
    }
};

pub const Packet = union(enum) {
    data: block_mod.Block,
    progress: Progress,
    profile_info: ProfileInfo,
    profile_events: block_mod.Block,
    log: block_mod.Block,
    totals: block_mod.Block,
    extremes: block_mod.Block,
    table_columns: TableColumns,
    exception: cherror.ServerError,
    end_of_stream,

    pub fn deinit(self: Packet, allocator: std.mem.Allocator) void {
        switch (self) {
            .data, .profile_events, .log, .totals, .extremes => |b| b.deinit(),
            .table_columns => |t| t.deinit(allocator),
            .exception => |e| e.deinit(),
            else => {},
        }
    }
};

pub const Error = error{
    UnexpectedPacket,
    ProtocolError,
    ReadTimeout,
};

pub const ResultStream = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    server_revision: u64,
    /// When .Enable, every Data-flavored packet body is wrapped in a
    /// compression frame. Set by Client.query when the per-query
    /// compression flag is on. Synthetic-byte tests leave it Disable.
    compression: protocol.CompressionEnabled = .Disable,
    transport: ?transport_mod.Transport = null,
    /// Hooks back into the parent Client so we can flip state back to
    /// .ready / .broken when the stream terminates. Held by value so
    /// no dangling-pointer hazard from a stack-local view; the inner
    /// pointers (state, is_broken) reference the long-lived Client.
    /// Optional so synthetic-byte tests can drive a stream standalone.
    client_state: ?ClientStateView = null,
    finished: bool = false,

    pub const ClientStateView = struct {
        state: *anyopaque,
        is_broken: *bool,
        set_ready: *const fn (state: *anyopaque) void,
        set_broken: *const fn (state: *anyopaque) void,
    };

    pub fn next(self: *ResultStream) !?Packet {
        if (self.finished) return null;
        const packet_id = wire.readServerPacketId(self.reader) catch |e| {
            self.markBroken();
            return self.mapReadError(e);
        };
        // Per upstream Connection::receivePacket: Data / Totals / Extremes
        // always ride through `maybe_compressed_in` when general
        // compression is on. Log and ProfileEvents are revision-gated:
        // `initBlockLogsInput` / `initBlockProfileEventsInput` wrap raw
        // `*in` BELOW WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS (54_481)
        // and `maybe_compressed_in` AT or above it. At our pinned
        // CLIENT_REVISION = 54_466 the gate is dormant and these packets
        // are always uncompressed; encoding the gate now keeps a future
        // revision bump from silently hanging on the first Log packet.
        const compressed_body = self.compression == .Enable;
        const compressed_log_or_pe = self.compression == .Enable
            and self.server_revision >= protocol.Revision.WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS;
        switch (packet_id) {
            .Data => return .{ .data = try self.readBlockAndCheck(compressed_body) },
            .Totals => return .{ .totals = try self.readBlockAndCheck(compressed_body) },
            .Extremes => return .{ .extremes = try self.readBlockAndCheck(compressed_body) },
            .Log => return .{ .log = try self.readBlockAndCheck(compressed_log_or_pe) },
            .ProfileEvents => return .{ .profile_events = try self.readBlockAndCheck(compressed_log_or_pe) },
            .Progress => return .{ .progress = try self.readProgress() },
            .ProfileInfo => return .{ .profile_info = try self.readProfileInfo() },
            .TableColumns => return .{ .table_columns = try self.readTableColumns() },
            .Exception => {
                const exc = exception.readException(self.reader, self.allocator) catch |e| {
                    self.markBroken();
                    return self.mapReadError(e);
                };
                self.markFinishedReady();
                return .{ .exception = exc };
            },
            .EndOfStream => {
                self.markFinishedReady();
                return .end_of_stream;
            },
            else => {
                self.markBroken();
                return error.UnexpectedPacket;
            },
        }
    }

    fn readBlockAndCheck(self: *ResultStream, compressed_body: bool) !block_mod.Block {
        const mode: protocol.CompressionEnabled = if (compressed_body) .Enable else .Disable;
        // `table_name` rides UNCOMPRESSED on the wire (mirrors upstream
        // Connection::sendData); read it here from the outer reader and
        // hand ownership to `block.readMaybeCompressed`.
        const table_name = wire.readStringOwned(self.reader, self.allocator, wire.MAX_DEFAULT_STRING) catch |e| {
            self.markBroken();
            return self.mapReadError(e);
        };
        return block_mod.readMaybeCompressed(self.reader, self.allocator, self.server_revision, table_name, mode) catch |e| {
            self.markBroken();
            return self.mapReadError(e);
        };
    }

    fn mapReadError(self: *ResultStream, e: anyerror) anyerror {
        if (e == error.Timeout) return error.ReadTimeout;
        if (e == error.ReadFailed) {
            if (self.transport) |t| {
                if (t.lastReadError()) |err| {
                    if (err == error.Timeout) return error.ReadTimeout;
                }
            }
        }
        return e;
    }

    fn readProgress(self: *ResultStream) !Progress {
        return readProgressBody(self.reader, self.server_revision);
    }
    fn readProfileInfo(self: *ResultStream) !ProfileInfo {
        return readProfileInfoBody(self.reader);
    }
    fn readTableColumns(self: *ResultStream) !TableColumns {
        return readTableColumnsBody(self.reader, self.allocator);
    }

    pub fn readProgressBody(reader: *std.Io.Reader, server_revision: u64) !Progress {
        var p: Progress = .{};
        p.read_rows = try varint.readVarUInt(reader, u64);
        p.read_bytes = try varint.readVarUInt(reader, u64);
        p.total_rows_to_read = try varint.readVarUInt(reader, u64);
        if (server_revision >= protocol.Revision.WITH_TOTAL_ROWS_IN_PROGRESS) {
            p.total_bytes_to_read = try varint.readVarUInt(reader, u64);
        }
        if (server_revision >= protocol.Revision.WITH_CLIENT_WRITE_INFO) {
            p.written_rows = try varint.readVarUInt(reader, u64);
            p.written_bytes = try varint.readVarUInt(reader, u64);
        }
        if (server_revision >= protocol.Revision.WITH_SERVER_QUERY_TIME_IN_PROGRESS) {
            p.elapsed_ns = try varint.readVarUInt(reader, u64);
        }
        return p;
    }

    pub fn readProfileInfoBody(reader: *std.Io.Reader) !ProfileInfo {
        const rows = try varint.readVarUInt(reader, u64);
        const blocks = try varint.readVarUInt(reader, u64);
        const bytes = try varint.readVarUInt(reader, u64);
        const applied = (try reader.takeByte()) != 0;
        const rows_bl = try varint.readVarUInt(reader, u64);
        const calc = (try reader.takeByte()) != 0;
        return .{
            .rows = rows,
            .blocks = blocks,
            .bytes = bytes,
            .applied_limit = applied,
            .rows_before_limit = rows_bl,
            .calculated_rows_before_limit = calc,
        };
    }

    pub fn readTableColumnsBody(reader: *std.Io.Reader, allocator: std.mem.Allocator) !TableColumns {
        const table_name = try wire.readStringOwned(reader, allocator, wire.MAX_DEFAULT_STRING);
        errdefer allocator.free(table_name);
        const cols_meta = try wire.readStringOwned(reader, allocator, wire.MAX_QUERY_STRING);
        return .{ .table_name = table_name, .columns_metadata = cols_meta };
    }

    fn markFinishedReady(self: *ResultStream) void {
        self.finished = true;
        if (self.client_state) |csv| csv.set_ready(csv.state);
    }

    fn markBroken(self: *ResultStream) void {
        self.finished = true;
        if (self.client_state) |csv| {
            csv.is_broken.* = true;
            csv.set_broken(csv.state);
        }
    }
};

const testing = std.testing;

test "ResultStream surfaces a Data block then EndOfStream" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Data packet: ServerPacket.Data = 1, then a 1-col 1-row UInt8 block.
    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Data));
    try wire.writeStringBinary(&w, "");
    try varint.writeVarUInt(&w, 1);
    try w.writeByte(0);
    try varint.writeVarUInt(&w, 2);
    try w.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&w, 0);
    try varint.writeVarUInt(&w, 1);
    try varint.writeVarUInt(&w, 1);
    try wire.writeStringBinary(&w, "x");
    try wire.writeStringBinary(&w, "UInt8");
    try w.writeByte(0);
    try w.writeByte(7);
    // EndOfStream packet: id 5, no body
    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.EndOfStream));

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = testing.allocator,
        .server_revision = protocol.CLIENT_REVISION,
    };

    const first = (try stream.next()).?;
    try testing.expect(first == .data);
    defer first.data.deinit();
    try testing.expectEqual(@as(u8, 7), first.data.columns[0].column.UInt8[0]);

    const second = (try stream.next()).?;
    try testing.expect(second == .end_of_stream);

    const third = try stream.next();
    try testing.expectEqual(@as(?Packet, null), third);
}

test "ResultStream routes Exception terminator" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Exception));
    try w.writeInt(i32, 60, .little);
    try wire.writeStringBinary(&w, "DB::Exception");
    try wire.writeStringBinary(&w, "Table not found");
    try wire.writeStringBinary(&w, "");
    try w.writeByte(0);

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = testing.allocator,
        .server_revision = protocol.CLIENT_REVISION,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .exception);
    defer p.exception.deinit();
    try testing.expectEqual(@as(u32, 60), p.exception.code);
    try testing.expectEqual(@as(?Packet, null), try stream.next());
}

test "ResultStream with compression on reads table_name BEFORE the frame" {
    // Regression lock: when compression is enabled, the Data packet's
    // table_name rides UNCOMPRESSED before the LZ4 frame on the wire
    // (mirroring upstream Connection::sendData where `name` goes to raw
    // out and only the block body goes through maybe_compressed_out).
    // If readBlockAndCheck regresses to consuming table_name from inside
    // the decompressed bytes, this test fails — and the compression smoke
    // hangs the server for 5 minutes because compressed_size becomes a
    // garbage u32 read from random offsets.
    const ally = testing.allocator;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Server packet shape: packet_id Data + table_name "" + frame{ body }
    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Data));
    try wire.writeStringBinary(&w, ""); // uncompressed table_name
    // Build the body that goes inside the frame: BlockInfo + 0 cols + 0 rows.
    var body_buf: [32]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    try varint.writeVarUInt(&bw, 1);
    try bw.writeByte(0);
    try varint.writeVarUInt(&bw, 2);
    try bw.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try compression_mod.writeFrameLz4(&w, ally, bw.buffered());

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = ally,
        .server_revision = protocol.CLIENT_REVISION,
        .compression = .Enable,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .data);
    defer p.data.deinit();
    try testing.expectEqualStrings("", p.data.table_name);
    try testing.expectEqual(@as(u64, 0), p.data.num_rows);
    try testing.expectEqual(@as(usize, 0), p.data.columns.len);
}

test "ResultStream compressed Data round-trips a 1-col 1-row block + asserts exact frame consumption" {
    // Locks the `fr.buffered().len == 0` invariant: the frame must be
    // consumed exactly by readBlockBody. A column-decoder sizing bug
    // (e.g. reading too few bytes for a UInt8 column) would leave
    // residue and surface as ProtocolError rather than silently
    // misalign the next packet's read.
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Data));
    try wire.writeStringBinary(&w, "");
    var body_buf: [64]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    // BlockInfo
    try varint.writeVarUInt(&bw, 1);
    try bw.writeByte(0);
    try varint.writeVarUInt(&bw, 2);
    try bw.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&bw, 0);
    // 1 col, 1 row
    try varint.writeVarUInt(&bw, 1);
    try varint.writeVarUInt(&bw, 1);
    try wire.writeStringBinary(&bw, "x");
    try wire.writeStringBinary(&bw, "UInt8");
    try bw.writeByte(0); // has_custom_serialization = 0
    try bw.writeByte(42); // value
    try compression_mod.writeFrameLz4(&w, ally, bw.buffered());

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = ally,
        .server_revision = protocol.CLIENT_REVISION,
        .compression = .Enable,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .data);
    defer p.data.deinit();
    try testing.expectEqual(@as(u64, 1), p.data.num_rows);
    try testing.expectEqual(@as(usize, 1), p.data.columns.len);
    try testing.expectEqual(@as(u8, 42), p.data.columns[0].column.UInt8[0]);
}

test "ResultStream with compression on reads ProfileEvents UNCOMPRESSED below the gate" {
    // Regression lock: at server_revision < WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS
    // (54_481), ProfileEvents (and Log) are sent without a compression
    // frame even when general compression is on. Upstream
    // initBlockProfileEventsInput / initBlockLogsInput wrap the raw
    // stream below this gate. Treating the body as compressed hangs the
    // connection on the first Profile/Log packet because we look for a
    // frame header where there isn't one.
    const ally = testing.allocator;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.ProfileEvents));
    // Uncompressed block body: table_name "" + BlockInfo + 0 cols + 0 rows
    try wire.writeStringBinary(&w, "");
    try varint.writeVarUInt(&w, 1);
    try w.writeByte(0);
    try varint.writeVarUInt(&w, 2);
    try w.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&w, 0);
    try varint.writeVarUInt(&w, 0);
    try varint.writeVarUInt(&w, 0);

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = ally,
        .server_revision = protocol.CLIENT_REVISION,
        .compression = .Enable,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .profile_events);
    defer p.profile_events.deinit();
    try testing.expect(p.profile_events.isEmpty());
}

test "ResultStream at revision >= 54_481 reads ProfileEvents COMPRESSED via the gate" {
    // Forward-compat lock: when the negotiated revision is at or above
    // WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS (54_481), the server
    // wraps Log/ProfileEvents block bodies in a compression frame just
    // like Data/Totals/Extremes. The gate in ResultStream.next must
    // trigger the compressed read path. Today this is dead code at
    // pinned CLIENT_REVISION = 54_466, but a future bump must not
    // silently regress it — this test is the only thing that catches
    // a wrong-direction gate flip.
    const ally = testing.allocator;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.ProfileEvents));
    try wire.writeStringBinary(&w, ""); // uncompressed table_name
    // Body: BlockInfo + 0 cols + 0 rows, written into the frame.
    var body_buf: [32]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    try varint.writeVarUInt(&bw, 1);
    try bw.writeByte(0);
    try varint.writeVarUInt(&bw, 2);
    try bw.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try compression_mod.writeFrameLz4(&w, ally, bw.buffered());

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = ally,
        .server_revision = protocol.Revision.WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS,
        .compression = .Enable,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .profile_events);
    defer p.profile_events.deinit();
    try testing.expect(p.profile_events.isEmpty());
}

test "ResultStream at revision >= 54_481 reads Log COMPRESSED via the gate" {
    const ally = testing.allocator;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try varint.writeVarUInt(&w, @intFromEnum(protocol.ServerPacket.Log));
    try wire.writeStringBinary(&w, "");
    var body_buf: [32]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    try varint.writeVarUInt(&bw, 1);
    try bw.writeByte(0);
    try varint.writeVarUInt(&bw, 2);
    try bw.writeInt(i32, -1, .little);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try varint.writeVarUInt(&bw, 0);
    try compression_mod.writeFrameLz4(&w, ally, bw.buffered());

    var r: std.Io.Reader = .fixed(w.buffered());
    var stream: ResultStream = .{
        .reader = &r,
        .allocator = ally,
        .server_revision = protocol.Revision.WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS,
        .compression = .Enable,
    };
    const p = (try stream.next()).?;
    try testing.expect(p == .log);
    defer p.log.deinit();
    try testing.expect(p.log.isEmpty());
}
