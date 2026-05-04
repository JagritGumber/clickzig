//! End-to-end smoke executable for clickzig. Five scenarios:
//!   happy        — connect to localhost:9000 with default:test
//!   wrong-pass   — connect with wrong password; expect AuthenticationFailed
//!   ping         — connect + 100x ping in a loop
//!   unreachable  — connect to a port nothing listens on
//!   wrong-host   — connect to a TEST-NET-1 address that times out
//!
//! Run via: `zig build smoke -- <scenario>`. Requires a local
//! ClickHouse on 127.0.0.1:9000 with `default:test` for happy/ping
//! /wrong-pass scenarios.

const std = @import("std");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const scenario = args.next() orelse "happy";

    if (std.mem.eql(u8, scenario, "happy")) {
        try runHappy(allocator, io);
    } else if (std.mem.eql(u8, scenario, "ping")) {
        try runPing(allocator, io);
    } else if (std.mem.eql(u8, scenario, "wrong-pass")) {
        try runWrongPass(allocator, io);
    } else if (std.mem.eql(u8, scenario, "unreachable")) {
        try runUnreachable(allocator, io);
    } else if (std.mem.eql(u8, scenario, "wrong-host")) {
        try runWrongHost(allocator, io);
    } else if (std.mem.eql(u8, scenario, "query-bytes")) {
        try runQueryBytes(allocator, io);
    } else if (std.mem.eql(u8, scenario, "query-mixed")) {
        try runQueryMixed(allocator, io);
    } else {
        std.debug.print("usage: smoke_connect [happy|ping|wrong-pass|unreachable|wrong-host|query-bytes]\n", .{});
        return error.UnknownScenario;
    }
}

fn runQueryMixed(allocator: std.mem.Allocator, io: std.Io) !void {
    // Multi-row, multi-type result — exercises String + Int64 + Float64
    // + DateTime decode in one go. `numbers(N)` gives us a deterministic
    // 4-row generator; the SELECT then casts/labels columns to known
    // types so the wire response has predictable schema.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const sql =
        \\SELECT
        \\    toString(number * 100) AS label,
        \\    toInt64(number) AS n,
        \\    toFloat64(number) / 3 AS frac,
        \\    toDateTime('2026-05-04 09:00:00') + number AS ts
        \\FROM numbers(4)
    ;
    var stream = try client.query(sql, arena.allocator(), null, .{ .query_id = "smoke-query-mixed" });
    var rows_seen: u64 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const labels = b.columns[0].column.String;
            const ns = b.columns[1].column.Int64;
            const fracs = b.columns[2].column.Float64;
            const ts = b.columns[3].column.UInt32;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                std.debug.print("[query-mixed] row: label={s} n={d} frac={d:.4} ts={d}\n", .{ labels[i], ns[i], fracs[i], ts[i] });
            }
            rows_seen += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[query-mixed] server exception: {s}\n", .{e.message});
            return error.ServerExceptionDuringQuery;
        },
        else => {},
    };
    if (rows_seen != 4) {
        std.debug.print("[query-mixed] FAIL: expected 4 rows, got {d}\n", .{rows_seen});
        return error.UnexpectedRowCount;
    }
    std.debug.print("[query-mixed] OK: 4 rows x 4 columns decoded\n", .{});
}

fn runQueryBytes(allocator: std.mem.Allocator, io: std.Io) !void {
    // Full round-trip: send "SELECT 1", drain every server packet through
    // EndOfStream, dump what came back. Verifies wire format end-to-end
    // including BlockInfo, column header, and primitive column decode.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var stream = try client.query("SELECT 1", arena.allocator(), null, .{ .query_id = "smoke-query-bytes" });
    var data_blocks: u32 = 0;
    var progress_packets: u32 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            data_blocks += 1;
            std.debug.print("[query-bytes] data block: {d} cols x {d} rows\n", .{ b.columns.len, b.num_rows });
            for (b.columns) |c| {
                std.debug.print("[query-bytes]   col {s}: {s}\n", .{ c.name, c.type_name });
                switch (c.column) {
                    .UInt8 => |s| if (s.len > 0) std.debug.print("[query-bytes]     value[0]={d}\n", .{s[0]}),
                    else => {},
                }
            }
        },
        .progress => progress_packets += 1,
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[query-bytes] server exception code={d} msg={s}\n", .{ e.code, e.message });
            return error.ServerExceptionDuringQuery;
        },
        else => {},
    };
    std.debug.print("[query-bytes] drained: {d} data blocks, {d} progress packets, state={s}\n", .{ data_blocks, progress_packets, @tagName(client.state) });
    if (client.state != .ready) return error.ClientNotReady;
}

fn baseConfig(allocator: std.mem.Allocator) clickzig.Config {
    return .{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
        .dial_timeout_ms = 5_000,
    };
}

fn runHappy(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    const info = client.server_info;
    std.debug.print("[happy] connected: {s} {d}.{d}.{d} rev {d}\n", .{
        info.name,
        info.major_version,
        info.minor_version,
        info.version_patch,
        info.revision,
    });
    if (info.timezone) |tz| std.debug.print("[happy] timezone: {s}\n", .{tz});
    if (info.display_name) |dn| std.debug.print("[happy] display:  {s}\n", .{dn});
    try client.ping(null);
    std.debug.print("[happy] ping/pong ok, last_used_at_ms={d}\n", .{client.last_used_at_ms});
}

fn runPing(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    const start = client.last_used_at_ms;
    var i: usize = 0;
    while (i < 100) : (i += 1) try client.ping(null);
    std.debug.print("[ping] 100 pings ok; last_used_at_ms drifted from {d} to {d}\n", .{ start, client.last_used_at_ms });
}

fn runWrongPass(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.password = "obviously-wrong";
    var diag: clickzig.Diagnostics = .{};
    defer diag.deinit();
    const result = clickzig.Client.connectTcp(cfg, io, null, &diag);
    if (result) |c| {
        c.close();
        std.debug.print("[wrong-pass] FAIL: connected with bad password\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        if (diag.server_exception) |exc| {
            std.debug.print("[wrong-pass] err={s} code={d} ({s}) msg={s}\n", .{
                @errorName(e),
                exc.code,
                exc.codeName() orelse "?",
                exc.message,
            });
        } else {
            std.debug.print("[wrong-pass] err={s} (no diagnostic)\n", .{@errorName(e)});
        }
        if (e != error.AuthenticationFailed) {
            std.debug.print("[wrong-pass] FAIL: expected AuthenticationFailed, got {s}\n", .{@errorName(e)});
            return e;
        }
    }
}

fn runUnreachable(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.port = 9001; // Nothing listens here
    cfg.dial_timeout_ms = 3_000;
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |c| {
        c.close();
        std.debug.print("[unreachable] FAIL: connected to dead port\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        std.debug.print("[unreachable] OK: got {s}\n", .{@errorName(e)});
    }
}

fn runWrongHost(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.host = "192.0.2.1"; // TEST-NET-1; documented as unroutable
    cfg.dial_timeout_ms = 3_000;
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |c| {
        c.close();
        std.debug.print("[wrong-host] FAIL: somehow connected to TEST-NET-1\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        std.debug.print("[wrong-host] OK: got {s}\n", .{@errorName(e)});
    }
}
