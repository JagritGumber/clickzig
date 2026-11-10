//! Async / cancellation smoke scenarios against a real ClickHouse on
//! 127.0.0.1:9000 (`default:test`), driven through `std.Io` tasks.
//!
//!   cancel-query   — cancel a long-running query from another task;
//!                    the client must send Cancel, drain, stay reusable,
//!                    and the server must no longer list the query.
//!   stream-cancel  — read one block of a huge result, then
//!                    `ResultStream.cancel()`; connection stays reusable.
//!   cancel-race    — cancel short queries at varying delays; every
//!                    outcome must leave the client either reusable (and
//!                    actually working) or explicitly broken.
//!   pool-cancel    — cancel a task blocked in `Pool.acquire` on a full
//!                    pool; no slot may leak.
//!   fanout         — run many queries concurrently through a Pool with
//!                    `Io.Group`; every result must be correct.
//!   all            — run every scenario above.
//!
//! Run via: `zig build smoke-async -- <scenario>`.

const std = @import("std");
const clickzig = @import("clickzig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const scenario = args.next() orelse "all";

    const scenarios = .{
        .{ "cancel-query", runCancelQuery },
        .{ "stream-cancel", runStreamCancel },
        .{ "cancel-race", runCancelRace },
        .{ "pool-cancel", runPoolCancel },
        .{ "fanout", runFanout },
    };
    var matched = false;
    inline for (scenarios) |entry| {
        if (std.mem.eql(u8, scenario, "all") or std.mem.eql(u8, scenario, entry[0])) {
            matched = true;
            try entry[1](gpa, io);
        }
    }
    if (!matched) {
        std.debug.print("unknown scenario: {s}\n", .{scenario});
        return error.UnknownScenario;
    }
}

fn baseConfig(gpa: std.mem.Allocator) clickzig.Config {
    return .{
        .control_allocator = gpa,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
        .dial_timeout_ms = 5_000,
    };
}

fn sleepMs(io: Io, ms: i64) !void {
    const d: Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake };
    try d.sleep(io);
}

fn nowMs(io: Io) i64 {
    return Io.Clock.now(.awake, io).toMilliseconds();
}

/// Run `sql` to completion and return the first UInt64 value seen (or 0).
fn queryScalar(client: *clickzig.Client, gpa: std.mem.Allocator, sql: []const u8, opts: clickzig.QueryOptions) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var stream = try client.query(sql, arena.allocator(), opts);
    var value: u64 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            if (b.num_rows > 0) switch (b.columns[0].column) {
                .UInt64 => |v| value = v[0],
                .UInt8 => |v| value = v[0],
                else => {},
            };
        },
        .exception => |e| {
            std.debug.print("server exception {d}: {s}\n", .{ e.code, e.message });
            return error.ServerException;
        },
        .end_of_stream => break,
        else => {},
    };
    return value;
}

fn expectWorking(client: *clickzig.Client, gpa: std.mem.Allocator) !void {
    if (!client.isReusable()) return error.ClientNotReusable;
    const one = try queryScalar(client, gpa, "SELECT toUInt64(1)", .{});
    if (one != 1) return error.FollowUpQueryWrong;
}

fn serverStillRuns(client: *clickzig.Client, gpa: std.mem.Allocator, io: Io, query_id: []const u8) !bool {
    var params: clickzig.Parameters = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try params.putString(arena.allocator(), "qid", query_id);
    // system.processes removal can trail the EndOfStream by a moment.
    var attempt: u32 = 0;
    while (attempt < 20) : (attempt += 1) {
        const n = try queryScalar(client, gpa, "SELECT count() FROM system.processes WHERE query_id = {qid:String}", .{ .parameters = &params });
        if (n == 0) return false;
        try sleepMs(io, 50);
    }
    return true;
}

// --- cancel-query ---------------------------------------------------------

fn longQuery(client: *clickzig.Client, gpa: std.mem.Allocator) clickzig.QueryError!u64 {
    return queryScalar(client, gpa, "SELECT max(number) FROM numbers(100000000000)", .{ .query_id = "smoke-async-cancel" }) catch |e| switch (e) {
        error.Canceled => error.Canceled,
        else => error.ProtocolError,
    };
}

fn runCancelQuery(gpa: std.mem.Allocator, io: Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(gpa), io, null);
    defer client.close();
    const observer = try clickzig.Client.connectTcp(baseConfig(gpa), io, null);
    defer observer.close();

    var task = try io.concurrent(longQuery, .{ client, gpa });
    try sleepMs(io, 300);
    if (!try serverStillRuns(observer, gpa, io, "smoke-async-cancel")) {
        _ = task.cancel(io) catch {};
        return error.QueryNotRunningBeforeCancel;
    }

    const t0 = nowMs(io);
    const result = task.cancel(io);
    const elapsed = nowMs(io) - t0;
    if (result) |_| return error.ExpectedCanceled else |e| if (e != error.Canceled) return e;
    if (elapsed > 3_000) return error.CancelTooSlow;

    try expectWorking(client, gpa);
    if (try serverStillRuns(observer, gpa, io, "smoke-async-cancel")) return error.ServerQueryNotKilled;
    std.debug.print("[cancel-query] OK canceled in {d}ms, client reusable, server query gone\n", .{elapsed});
}

// --- stream-cancel --------------------------------------------------------

fn runStreamCancel(gpa: std.mem.Allocator, io: Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(gpa), io, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var settings: clickzig.SettingsMap = .{};
    try settings.put(arena.allocator(), "max_block_size", "10000");
    var stream = try client.query("SELECT number FROM numbers(10000000000)", arena.allocator(), .{ .settings = &settings, .query_id = "smoke-async-stream-cancel" });
    var rows: u64 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            rows += b.num_rows;
            if (rows > 0) break;
        },
        .end_of_stream => return error.UnexpectedEnd,
        else => {},
    };
    stream.cancel();
    if (try stream.next() != null) return error.StreamNotFinished;
    try expectWorking(client, gpa);
    std.debug.print("[stream-cancel] OK stopped after {d} rows, client reusable\n", .{rows});
}

// --- cancel-race ----------------------------------------------------------

fn shortQuery(client: *clickzig.Client, gpa: std.mem.Allocator) clickzig.QueryError!u64 {
    return queryScalar(client, gpa, "SELECT sum(number) FROM numbers(3000000)", .{}) catch |e| switch (e) {
        error.Canceled => error.Canceled,
        error.ClientNotReady => error.ClientNotReady,
        else => error.ProtocolError,
    };
}

fn runCancelRace(gpa: std.mem.Allocator, io: Io) !void {
    var completed: u32 = 0;
    var canceled_clean: u32 = 0;
    var canceled_broken: u32 = 0;
    var delay: i64 = 0;
    while (delay < 40) : (delay += 1) {
        const client = try clickzig.Client.connectTcp(baseConfig(gpa), io, null);
        defer client.close();
        var task = try io.concurrent(shortQuery, .{ client, gpa });
        if (delay > 0) {
            // 250us steps: spans "canceled mid-query" through "already done".
            const d: Io.Clock.Duration = .{ .raw = .fromNanoseconds(delay * 250_000), .clock = .awake };
            try d.sleep(io);
        }
        if (task.cancel(io)) |sum| {
            if (sum != 4499998500000) return error.WrongSum;
            completed += 1;
        } else |e| switch (e) {
            error.Canceled => if (client.isReusable()) {
                canceled_clean += 1;
            } else {
                canceled_broken += 1;
                continue;
            },
            else => return e,
        }
        // Any reusable outcome must really be reusable — including the
        // race where Cancel reaches the server after the query ended.
        try expectWorking(client, gpa);
        try expectWorking(client, gpa);
    }
    std.debug.print("[cancel-race] OK completed={d} canceled_clean={d} canceled_broken={d}\n", .{ completed, canceled_clean, canceled_broken });
}

// --- pool-cancel ----------------------------------------------------------

fn runPoolCancel(gpa: std.mem.Allocator, io: Io) !void {
    const pool = try clickzig.Pool.init(gpa, io, baseConfig(gpa), .{ .max_size = 1 });
    defer pool.deinit();

    const held = try pool.acquire();
    var waiter = try io.concurrent(clickzig.Pool.acquire, .{pool});
    try sleepMs(io, 200);
    if (waiter.cancel(io)) |c| {
        pool.release(c);
        pool.release(held);
        return error.AcquireShouldHaveBlocked;
    } else |e| if (e != error.Canceled) return e;

    pool.release(held);
    const again = try pool.acquire();
    try again.ping();
    pool.release(again);
    if (pool.liveCount() != 1) return error.PoolSlotLeaked;
    std.debug.print("[pool-cancel] OK blocked acquire canceled, live={d}\n", .{pool.liveCount()});
}

// --- fanout ---------------------------------------------------------------

const FanoutSlot = struct {
    n: u64,
    result: ?u64 = null,
    err: ?anyerror = null,
};

fn fanoutTask(pool: *clickzig.Pool, gpa: std.mem.Allocator, slot: *FanoutSlot) Io.Cancelable!void {
    fanoutInner(pool, gpa, slot) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => slot.err = e,
    };
}

fn fanoutInner(pool: *clickzig.Pool, gpa: std.mem.Allocator, slot: *FanoutSlot) !void {
    const client = try pool.acquire();
    defer pool.release(client);
    var params: clickzig.Parameters = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try params.putUInt(arena.allocator(), "n", slot.n);
    slot.result = try queryScalar(client, gpa, "SELECT sum(number) FROM numbers({n:UInt64})", .{ .parameters = &params });
}

fn runFanout(gpa: std.mem.Allocator, io: Io) !void {
    const pool = try clickzig.Pool.init(gpa, io, baseConfig(gpa), .{ .max_size = 4 });
    defer pool.deinit();

    var slots: [24]FanoutSlot = undefined;
    for (&slots, 0..) |*s, i| s.* = .{ .n = 1_000_000 + i * 1000 };

    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&slots) |*s| group.async(io, fanoutTask, .{ pool, gpa, s });
    try group.await(io);

    for (slots) |s| {
        if (s.err) |e| return e;
        const expected = s.n * (s.n - 1) / 2;
        if (s.result != expected) return error.FanoutWrongResult;
    }
    if (pool.liveCount() > 4) return error.PoolOverCap;
    std.debug.print("[fanout] OK {d} concurrent queries over live={d} connections\n", .{ slots.len, pool.liveCount() });
}
