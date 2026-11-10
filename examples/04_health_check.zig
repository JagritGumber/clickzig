//! Example 04 — Health check loop with `std.Io` cancellation.
//!
//! Runs a ping loop as an `Io` task (`io.concurrent`), then cancels it
//! from `main` after 1.5s. Cancellation is delivered by the `Io`
//! runtime: whichever operation the task is blocked in (the socket read
//! waiting for Pong, or the 100ms sleep) returns `error.Canceled`, and
//! clickzig propagates it unchanged.
//!
//! Concepts:
//!   - No cancel token: `future.cancel(io)` is the cancellation primitive.
//!   - The same code runs on `Io.Threaded` or an evented `Io`.
//!   - `client.isReusable()` tells you whether the connection survived
//!     (a ping canceled mid-flight leaves it broken; one canceled
//!     during the sleep leaves it ready).

const std = @import("std");
const clickzig = @import("clickzig");

fn healthLoop(client: *clickzig.Client, io: std.Io) clickzig.ConnectError!u32 {
    const ms_100: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(100),
        .clock = .awake,
    };
    var pings: u32 = 0;
    while (true) {
        client.ping() catch |e| switch (e) {
            error.Canceled => return pings,
            else => return e,
        };
        pings += 1;
        ms_100.sleep(io) catch return pings;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
    }, io, null);
    defer client.close();

    var task = try io.concurrent(healthLoop, .{ client, io });

    const ms_1500: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(1_500),
        .clock = .awake,
    };
    try ms_1500.sleep(io);
    std.debug.print("[main] canceling health loop\n", .{});

    const pings = try task.cancel(io);
    std.debug.print("[main] loop stopped after {d} pings; reusable={}\n", .{ pings, client.isReusable() });
}
