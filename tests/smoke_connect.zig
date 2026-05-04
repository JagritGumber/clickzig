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
    } else if (std.mem.eql(u8, scenario, "insert-roundtrip")) {
        try runInsertRoundtrip(allocator, io);
    } else if (std.mem.eql(u8, scenario, "nullable-roundtrip")) {
        try runNullableRoundtrip(allocator, io);
    } else if (std.mem.eql(u8, scenario, "complex-types")) {
        try runComplexTypes(allocator, io);
    } else if (std.mem.eql(u8, scenario, "pool")) {
        try runPool(allocator, io);
    } else if (std.mem.eql(u8, scenario, "dsn")) {
        try runDsn(allocator, io);
    } else if (std.mem.eql(u8, scenario, "decimal-ip")) {
        try runDecimalIp(allocator, io);
    } else if (std.mem.eql(u8, scenario, "tuple-map")) {
        try runTupleMap(allocator, io);
    } else if (std.mem.eql(u8, scenario, "compression")) {
        try runCompression(allocator, io);
    } else {
        std.debug.print("usage: smoke_connect [happy|ping|wrong-pass|unreachable|wrong-host|query-bytes]\n", .{});
        return error.UnknownScenario;
    }
}

fn runCompression(allocator: std.mem.Allocator, io: std.Io) !void {
    // Connect with compression enabled. Server should send Data blocks
    // wrapped in LZ4 compression frames; we decompress and parse.
    var cfg = baseConfig(allocator);
    cfg.compression = .Enable;
    const client = try clickzig.Client.connectTcp(cfg, io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        "SELECT number FROM numbers(100)",
        arena.allocator(),
        null,
        .{ .compression = .Enable },
    );
    var rows: u64 = 0;
    var sum: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            for (b.columns[0].column.UInt64) |n| {
                sum += n;
                rows += 1;
            }
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[compression] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 100) return error.UnexpectedRowCount;
    if (sum != 4950) return error.SumMismatch;
    std.debug.print("[compression] OK: 100 rows summed to {d} via LZ4 frames\n", .{sum});
}

fn runTupleMap(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var s = try client.query(
        \\SELECT
        \\    (number, toString(number * 10)) AS pair,
        \\    map('a', toInt64(1), 'b', toInt64(number)) AS m
        \\FROM numbers(2)
    , arena.allocator(), null, .{});
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const tup = b.columns[0].column.Tuple;
            const mp = b.columns[1].column.Map;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                const n = tup.elements[0].UInt64[i];
                const s_val = tup.elements[1].String[i];
                std.debug.print("[tuple-map] pair=({d}, {s})\n", .{ n, s_val });
                const start: usize = if (i == 0) 0 else @intCast(mp.offsets[i - 1]);
                const end: usize = @intCast(mp.offsets[i]);
                var j: usize = start;
                while (j < end) : (j += 1) {
                    std.debug.print("[tuple-map]   m[{s}]={d}\n", .{ mp.keys.String[j], mp.values.Int64[j] });
                }
            }
            rows += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[tuple-map] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[tuple-map] OK\n", .{});
}

fn runDecimalIp(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var s = try client.query(
        \\SELECT
        \\    toDecimal64(123.45, 2) AS price,
        \\    toIPv4('192.168.1.1') AS v4,
        \\    toIPv6('2001:db8::1') AS v6,
        \\    toUInt128(toUInt64(0xFFFF) * toUInt64(0x10001)) AS big
    , arena.allocator(), null, .{});
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            // Decimal64(2): scaled int64; 12345 / 100 = 123.45
            const price_raw = b.columns[0].column.Int64[0];
            const v4 = b.columns[1].column.UInt32[0];
            const v6_bytes = b.columns[2].column.FixedString.data[0..16];
            const big = b.columns[3].column.UInt128[0];
            std.debug.print("[decimal-ip] price_raw={d} (= {d}.{d:0>2})\n", .{ price_raw, @divTrunc(price_raw, 100), @rem(price_raw, 100) });
            std.debug.print("[decimal-ip] v4=0x{X:0>8} v6_first={X:0>2}{X:0>2} big={X}\n", .{ v4, v6_bytes[0], v6_bytes[1], big });
            if (price_raw != 12345) return error.DecimalMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[decimal-ip] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    std.debug.print("[decimal-ip] OK\n", .{});
}

fn runDsn(allocator: std.mem.Allocator, io: std.Io) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const result = try clickzig.fromUri(
        "clickhouse://default:test@127.0.0.1:9000/default?client_name=smoke-dsn",
        arena.allocator(),
        .{
            .control_allocator = allocator,
            .read_buffer_size = 64 * 1024,
            .write_buffer_size = 4 * 1024,
        },
    );
    const client = try clickzig.Client.connectTcp(result.config, io, null, null);
    defer client.close();
    try client.ping(null);
    std.debug.print("[dsn] connected via DSN; client_name={s}\n", .{result.config.client_name.?});
    std.debug.print("[dsn] OK\n", .{});
}

fn runPool(allocator: std.mem.Allocator, io: std.Io) !void {
    const pool = try clickzig.Pool.init(allocator, io, baseConfig(allocator), .{ .max_size = 4 });
    defer pool.deinit();

    // Acquire 3 distinct clients in parallel-ish (no real threads needed
    // for the smoke; just sequential acquire+ping+release with a peek
    // at live_count to confirm pool bookkeeping).
    const c1 = try pool.acquire(null);
    try c1.ping(null);
    const c2 = try pool.acquire(null);
    try c2.ping(null);
    std.debug.print("[pool] live={d} idle={d} after 2 acquires\n", .{ pool.liveCount(), pool.idleCount() });
    pool.release(c1);
    pool.release(c2);
    std.debug.print("[pool] live={d} idle={d} after release\n", .{ pool.liveCount(), pool.idleCount() });

    // Re-acquire — should hit the idle slot, no new dial.
    const c3 = try pool.acquire(null);
    try c3.ping(null);
    pool.release(c3);
    std.debug.print("[pool] live={d} idle={d} after re-acquire+release (should be 2/2)\n", .{ pool.liveCount(), pool.idleCount() });
    if (pool.liveCount() != 2) return error.PoolBookkeepingMismatch;
    std.debug.print("[pool] OK\n", .{});
}

fn runComplexTypes(allocator: std.mem.Allocator, io: std.Io) !void {
    // Hit Array, FixedString, and UUID in one query against the server.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        \\SELECT
        \\    [number, number * 2, number * 3] AS arr,
        \\    toFixedString(toString(number), 4) AS fs,
        \\    generateUUIDv4() AS id
        \\FROM numbers(2)
    , arena.allocator(), null, .{});
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const arr = b.columns[0].column.Array;
            const fs = b.columns[1].column.FixedString;
            const ids = b.columns[2].column.UUID;
            std.debug.print("[complex] arr type={s}, fs.width={d}\n", .{ b.columns[0].type_name, fs.width });
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                const start: usize = if (i == 0) 0 else @intCast(arr.offsets[i - 1]);
                const end: usize = @intCast(arr.offsets[i]);
                const row_arr = arr.inner.UInt64[start..end];
                const fs_row = fs.data[i * fs.width .. (i + 1) * fs.width];
                std.debug.print("[complex] row {d}: arr={any} fs='{s}' uuid_first_byte=0x{X:0>2}\n", .{ i, row_arr, fs_row, ids[i][0] });
                if (row_arr.len != 3) return error.ArrayShapeMismatch;
                if (row_arr[0] != i) return error.ArrayValueMismatch;
                if (row_arr[1] != i * 2) return error.ArrayValueMismatch;
                if (row_arr[2] != i * 3) return error.ArrayValueMismatch;
            }
            rows += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[complex] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[complex] OK: 2 rows of (Array(UInt64), FixedString(4), UUID)\n", .{});
}

fn runNullableRoundtrip(allocator: std.mem.Allocator, io: std.Io) !void {
    // Read a server-generated Nullable column and verify the mask comes
    // through. Bypasses INSERT to keep the test scope focused on read.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        \\SELECT
        \\    number AS n,
        \\    if(number % 2 = 0, NULL, toUInt32(number * 10)) AS maybe_n
        \\FROM numbers(5)
    , arena.allocator(), null, .{});
    var rows_seen: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ns = b.columns[0].column.UInt64;
            const nullable = b.columns[1].column.Nullable;
            const maybe = nullable.inner.UInt32;
            std.debug.print("[nullable] type={s}\n", .{b.columns[1].type_name});
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                if (nullable.mask[i] != 0) {
                    std.debug.print("[nullable] row n={d}: maybe_n=NULL\n", .{ns[i]});
                    if (ns[i] % 2 != 0) return error.NullMaskMismatch;
                } else {
                    std.debug.print("[nullable] row n={d}: maybe_n={d}\n", .{ ns[i], maybe[i] });
                    if (ns[i] % 2 == 0) return error.NullMaskMismatch;
                    if (maybe[i] != ns[i] * 10) return error.ValueMismatch;
                }
            }
            rows_seen += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[nullable] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows_seen != 5) return error.UnexpectedRowCount;
    std.debug.print("[nullable] OK: 5 rows with mixed null/non-null\n", .{});
}

fn runInsertRoundtrip(allocator: std.mem.Allocator, io: std.Io) !void {
    // Create a temp Memory-engine table, INSERT 3 rows, SELECT them back,
    // verify exact value match. Memory engine drops the table when the
    // server restarts so no cleanup needed across runs.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    // Drop+create.
    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_roundtrip", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[insert] drop failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }
    {
        var s = try client.query("CREATE TABLE smoke_roundtrip (id UInt32, label String) ENGINE = Memory", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[insert] create failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }

    // INSERT 3 rows.
    var ids = [_]u32{ 100, 200, 300 };
    var labels = [_][]u8{ @constCast("alpha"), @constCast("beta"), @constCast("gamma") };
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
    };
    try client.insert(
        "INSERT INTO smoke_roundtrip (id, label) FORMAT Native",
        "",
        3,
        &cols,
        arena.allocator(),
        null,
        .{ .query_id = "smoke-insert" },
    );
    std.debug.print("[insert] inserted 3 rows\n", .{});

    // SELECT them back ordered.
    var s = try client.query("SELECT id, label FROM smoke_roundtrip ORDER BY id", arena.allocator(), null, .{});
    var rows_seen: u32 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ids_back = b.columns[0].column.UInt32;
            const labels_back = b.columns[1].column.String;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                std.debug.print("[insert] read back: id={d} label={s}\n", .{ ids_back[i], labels_back[i] });
                if (ids_back[i] != ids[rows_seen + i]) return error.InsertMismatch;
                if (!std.mem.eql(u8, labels_back[i], labels[rows_seen + i])) return error.InsertMismatch;
            }
            rows_seen += @intCast(b.num_rows);
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[insert] select failed: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows_seen != 3) {
        std.debug.print("[insert] FAIL: expected 3 rows back, got {d}\n", .{rows_seen});
        return error.UnexpectedRowCount;
    }
    std.debug.print("[insert] OK: 3 rows round-tripped exactly\n", .{});
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
