//! clickzig benchmark harness.
//!
//! Talks to a real ClickHouse on 127.0.0.1:9000 (`default:test`) and
//! prints one JSON object per measurement to stdout. Build with
//! `zig build bench -Doptimize=ReleaseFast`; `bench/plot.py` turns the
//! output into `assets/benchmarks.svg`.
//!
//! Every measurement runs one warm-up pass, then `runs` timed passes,
//! and reports the median.

const std = @import("std");
const clickzig = @import("clickzig");

const Io = std.Io;

const runs = 7;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    try benchRead(gpa, io, out, "read_uint64", "SELECT number FROM numbers(20000000)", 20_000_000, 8, .Disable);
    try benchRead(gpa, io, out, "read_uint64_lz4", "SELECT number FROM numbers(20000000)", 20_000_000, 8, .Enable);
    try benchRead(gpa, io, out, "read_string", "SELECT toString(number) AS s FROM numbers(5000000)", 5_000_000, null, .Disable);
    try benchRead(gpa, io, out, "read_string_lz4", "SELECT toString(number) AS s FROM numbers(5000000)", 5_000_000, null, .Enable);
    try out.flush();

    try benchInsert(gpa, io, out, "insert_none", .Disable, .lz4);
    try benchInsert(gpa, io, out, "insert_lz4", .Enable, .lz4);
    try benchInsert(gpa, io, out, "insert_zstd", .Enable, .zstd);
    try out.flush();

    try benchPing(gpa, io, out);
    try out.flush();

    for ([_]u32{ 1, 2, 4, 8, 16 }) |concurrency| {
        try benchConcurrency(gpa, io, out, concurrency);
        try out.flush();
    }
}

fn config(gpa: std.mem.Allocator) clickzig.Config {
    return .{
        .control_allocator = gpa,
        .read_buffer_size = 256 * 1024,
        .write_buffer_size = 256 * 1024,
        .username = "default",
        .password = "test",
    };
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

// --- reads ----------------------------------------------------------------

fn drain(client: *clickzig.Client, gpa: std.mem.Allocator, sql: []const u8, opts: clickzig.QueryOptions) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var stream = try client.query(sql, arena.allocator(), opts);
    var rows: u64 = 0;
    while (try stream.next()) |packet| {
        switch (packet) {
            .data => |b| rows += b.num_rows,
            .exception => |e| {
                std.debug.print("server exception: {s}\n", .{e.message});
                return error.ServerException;
            },
            .end_of_stream => break,
            else => {},
        }
        // Blocks are independent; free them as we go so a long scan
        // measures decoding, not arena growth.
        _ = arena.reset(.retain_capacity);
    }
    return rows;
}

fn benchRead(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    name: []const u8,
    sql: []const u8,
    expected_rows: u64,
    bytes_per_row: ?u64,
    compression: clickzig.protocol.CompressionEnabled,
) !void {
    const client = try clickzig.Client.connectTcp(config(gpa), io, null);
    defer client.close();
    const opts: clickzig.QueryOptions = .{ .compression = compression };

    _ = try drain(client, gpa, sql, opts);
    var samples: [runs]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = nowNs(io);
        const rows = try drain(client, gpa, sql, opts);
        sample.* = @intCast(nowNs(io) - t0);
        if (rows != expected_rows) return error.RowCountMismatch;
    }
    const ns = median(&samples);
    const rows_per_s = @as(f64, @floatFromInt(expected_rows)) / (@as(f64, @floatFromInt(ns)) / 1e9);
    try out.print("{{\"bench\":\"{s}\",\"rows\":{d},\"ns\":{d},\"rows_per_s\":{d:.0}", .{ name, expected_rows, ns, rows_per_s });
    if (bytes_per_row) |b| try out.print(",\"mb_per_s\":{d:.1}", .{rows_per_s * @as(f64, @floatFromInt(b)) / 1e6});
    try out.writeAll("}\n");
}

// --- inserts --------------------------------------------------------------

const insert_batch_rows = 100_000;
const insert_batches = 10;

fn benchInsert(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    name: []const u8,
    compression: clickzig.protocol.CompressionEnabled,
    method: clickzig.compression.WriteMethod,
) !void {
    const client = try clickzig.Client.connectTcp(config(gpa), io, null);
    defer client.close();
    _ = try drain(client, gpa, "DROP TABLE IF EXISTS bench_insert", .{});
    _ = try drain(client, gpa, "CREATE TABLE bench_insert (id UInt64, label String, value Float64) ENGINE = Null", .{});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ids = try a.alloc(u64, insert_batch_rows);
    const labels = try a.alloc([]u8, insert_batch_rows);
    const values = try a.alloc(f64, insert_batch_rows);
    for (ids, labels, values, 0..) |*id, *label, *value, i| {
        id.* = i;
        label.* = try a.print("event-{d}-{s}", .{ i % 5000, if (i % 3 == 0) "click" else "view" });
        value.* = @as(f64, @floatFromInt(i)) * 0.25;
    }
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "id", .type_name = "UInt64", .data = .{ .UInt64 = ids } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = labels } },
        .{ .name = "value", .type_name = "Float64", .data = .{ .Float64 = values } },
    };
    const opts: clickzig.QueryOptions = .{ .compression = compression, .compression_method = method };
    const sql = "INSERT INTO bench_insert (id, label, value) FORMAT Native";

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    try client.insert(sql, "", insert_batch_rows, &cols, scratch.allocator(), opts);

    var samples: [runs]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = nowNs(io);
        for (0..insert_batches) |_| {
            _ = scratch.reset(.retain_capacity);
            try client.insert(sql, "", insert_batch_rows, &cols, scratch.allocator(), opts);
        }
        sample.* = @intCast(nowNs(io) - t0);
    }
    const ns = median(&samples);
    const total_rows: u64 = insert_batch_rows * insert_batches;
    const rows_per_s = @as(f64, @floatFromInt(total_rows)) / (@as(f64, @floatFromInt(ns)) / 1e9);
    try out.print("{{\"bench\":\"{s}\",\"rows\":{d},\"ns\":{d},\"rows_per_s\":{d:.0}}}\n", .{ name, total_rows, ns, rows_per_s });
    _ = try drain(client, gpa, "DROP TABLE IF EXISTS bench_insert", .{});
}

// --- ping -----------------------------------------------------------------

fn benchPing(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const client = try clickzig.Client.connectTcp(config(gpa), io, null);
    defer client.close();
    const n = 20_000;
    const samples = try gpa.alloc(u64, n);
    defer gpa.free(samples);
    for (0..1000) |_| try client.ping();
    for (samples) |*sample| {
        const t0 = nowNs(io);
        try client.ping();
        sample.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    try out.print("{{\"bench\":\"ping\",\"n\":{d},\"p50_ns\":{d},\"p99_ns\":{d}}}\n", .{ n, samples[n / 2], samples[n * 99 / 100] });
}

// --- concurrency ----------------------------------------------------------

const concurrent_queries = 48;
const concurrent_sql = "SELECT number, toString(number) FROM numbers(500000)";

const Worker = struct {
    rows: u64 = 0,
    err: ?anyerror = null,
};

/// One worker = one connection. Workers pull query indexes from a shared
/// counter until all `concurrent_queries` are done.
fn worker(pool: *clickzig.Pool, gpa: std.mem.Allocator, next: *std.atomic.Value(u32), w: *Worker) Io.Cancelable!void {
    workerInner(pool, gpa, next, w) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => w.err = e,
    };
}

fn workerInner(pool: *clickzig.Pool, gpa: std.mem.Allocator, next: *std.atomic.Value(u32), w: *Worker) !void {
    const client = try pool.acquire();
    defer pool.release(client);
    while (next.fetchAdd(1, .monotonic) < concurrent_queries) {
        w.rows += try drain(client, gpa, concurrent_sql, .{});
    }
}

fn runConcurrentBatch(pool: *clickzig.Pool, gpa: std.mem.Allocator, io: Io, concurrency: u32) !void {
    var workers: [16]Worker = @splat(.{});
    var next: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    defer group.cancel(io);
    // `concurrent`, not `async`: every worker must really be in flight.
    for (workers[0..concurrency]) |*w| try group.concurrent(io, worker, .{ pool, gpa, &next, w });
    try group.await(io);
    var rows: u64 = 0;
    for (workers[0..concurrency]) |w| {
        if (w.err) |e| return e;
        rows += w.rows;
    }
    if (rows != concurrent_queries * 500_000) return error.RowCountMismatch;
}

fn benchConcurrency(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, concurrency: u32) !void {
    const pool = try clickzig.Pool.init(gpa, io, config(gpa), .{ .max_size = concurrency });
    defer pool.deinit();

    try runConcurrentBatch(pool, gpa, io, concurrency);
    var samples: [5]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = nowNs(io);
        try runConcurrentBatch(pool, gpa, io, concurrency);
        sample.* = @intCast(nowNs(io) - t0);
    }
    const ns = median(&samples);
    const qps = @as(f64, @floatFromInt(concurrent_queries)) / (@as(f64, @floatFromInt(ns)) / 1e9);
    try out.print("{{\"bench\":\"concurrency\",\"concurrency\":{d},\"queries\":{d},\"ns\":{d},\"queries_per_s\":{d:.1},\"rows_per_s\":{d:.0}}}\n", .{ concurrency, concurrent_queries, ns, qps, qps * 500_000 });
}
