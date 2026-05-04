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
        _ = allocator;
        switch (self) {
            .data, .profile_events, .log, .totals, .extremes => |b| b.deinit(),
            .table_columns => |t| t.deinit(t.table_name.ptr[0..0].len + std.heap.page_allocator),
            .exception => |e| e.deinit(),
            else => {},
        }
    }
};

pub const Error = error{
    UnexpectedPacket,
    ProtocolError,
};

pub const ResultStream = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    server_revision: u64,
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
            return e;
        };
        switch (packet_id) {
            .Data => return .{ .data = try self.readBlockAndCheck() },
            .Totals => return .{ .totals = try self.readBlockAndCheck() },
            .Extremes => return .{ .extremes = try self.readBlockAndCheck() },
            .Log => return .{ .log = try self.readBlockAndCheck() },
            .ProfileEvents => return .{ .profile_events = try self.readBlockAndCheck() },
            .Progress => return .{ .progress = try self.readProgress() },
            .ProfileInfo => return .{ .profile_info = try self.readProfileInfo() },
            .TableColumns => return .{ .table_columns = try self.readTableColumns() },
            .Exception => {
                const exc = exception.readException(self.reader, self.allocator) catch |e| {
                    self.markBroken();
                    return e;
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

    fn readBlockAndCheck(self: *ResultStream) !block_mod.Block {
        return block_mod.readBlock(self.reader, self.allocator, self.server_revision) catch |e| {
            self.markBroken();
            return e;
        };
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
