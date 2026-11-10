//! Example 06 — Concurrent queries with `std.Io`.
//!
//! 1. Fan out several queries over a `Pool` with an `Io.Group`. Each
//!    task acquires its own connection (a Client serves one in-flight
//!    call at a time; the native protocol has no multiplexing).
//! 2. Put a deadline on a slow query: run it as a `Future`, sleep for
//!    the budget, then `cancel`. clickzig sends the protocol `Cancel`
//!    packet, so the server stops working too, and the connection goes
//!    back to the pool ready for reuse.
//!
//! The code only talks to `std.Io`, so it runs unchanged on any `Io`
//! implementation that supports networking (`Io.Threaded` today).

const std = @import("std");
const clickzig = @import("clickzig");

const Io = std.Io;

const Job = struct {
    table: []const u8,
    rows: ?u64 = null,
    err: ?anyerror = null,
};

fn countRows(pool: *clickzig.Pool, gpa: std.mem.Allocator, job: *Job) Io.Cancelable!void {
    countRowsInner(pool, gpa, job) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => job.err = e,
    };
}

fn countRowsInner(pool: *clickzig.Pool, gpa: std.mem.Allocator, job: *Job) !void {
    const client = try pool.acquire();
    defer pool.release(client);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const sql = try arena.allocator().print("SELECT count() FROM {s}", .{job.table});

    var stream = try client.query(sql, arena.allocator(), .{});
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| if (b.num_rows > 0) {
            job.rows = b.columns[0].column.UInt64[0];
        },
        .exception => return error.ServerException,
        .end_of_stream => break,
        else => {},
    };
}

fn slowQuery(pool: *clickzig.Pool, gpa: std.mem.Allocator) !u64 {
    var job: Job = .{ .table = "numbers(100000000000)" };
    try countRowsInner(pool, gpa, &job);
    return job.rows orelse 0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const pool = try clickzig.Pool.init(gpa, io, .{
        .control_allocator = gpa,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
    }, .{ .max_size = 4 });
    defer pool.deinit();

    // 1. Fan-out.
    var jobs = [_]Job{
        .{ .table = "system.tables" },
        .{ .table = "system.columns" },
        .{ .table = "system.functions" },
        .{ .table = "system.settings" },
        .{ .table = "system.data_type_families" },
        .{ .table = "system.table_functions" },
    };
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&jobs) |*job| group.async(io, countRows, .{ pool, gpa, job });
    try group.await(io);

    for (jobs) |job| {
        if (job.err) |e| {
            std.debug.print("{s}: error {t}\n", .{ job.table, e });
        } else {
            std.debug.print("{s}: {d} rows\n", .{ job.table, job.rows.? });
        }
    }

    // 2. Deadline: give a very slow query 500ms, then cancel it. Use
    //    `io.concurrent`, not `io.async`: `async` may run the task
    //    inline to completion when no worker is free.
    var slow = try io.concurrent(slowQuery, .{ pool, gpa });
    const budget: Io.Clock.Duration = .{ .raw = .fromMilliseconds(500), .clock = .awake };
    try budget.sleep(io);
    if (slow.cancel(io)) |n| {
        std.debug.print("slow query finished early: {d}\n", .{n});
    } else |e| switch (e) {
        error.Canceled => std.debug.print("slow query canceled after 500ms; pool idle={d}\n", .{pool.idleCount()}),
        else => return e,
    }
}
