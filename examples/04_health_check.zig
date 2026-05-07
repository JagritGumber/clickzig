//! Example 04 — Health check loop with cancellation token.
//!
//! Pings the server in a loop, sleeping 100ms between rounds. A
//! background "supervisor" thread flips an atomic bool after 1.5s,
//! demonstrating the cancellation contract: the cancel token is polled
//! at every I/O boundary inside `ping`, so the loop exits within at
//! most one in-flight operation.
//!
//! Concepts:
//!   - `?*const std.atomic.Value(bool)` is the v0.16.0
//!     cancellation primitive (a future major may switch to Io.Cancel).
//!   - Polling cadence is documented per-operation in client.zig.
//!   - `client.isReusable()` lets a future Pool decide whether to
//!     recycle a connection or discard it after an error.

const std = @import("std");
const clickzig = @import("clickzig");

const SupervisorArgs = struct {
    cancel: *std.atomic.Value(bool),
    io: std.Io,
};

fn supervisor(args: SupervisorArgs) void {
    const ms_1500: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(1_500),
        .clock = .awake,
    };
    ms_1500.sleep(args.io) catch return;
    std.debug.print("[supervisor] requesting cancel\n", .{});
    args.cancel.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var cancel: std.atomic.Value(bool) = .init(false);
    const sup = try std.Thread.spawn(.{}, supervisor, .{SupervisorArgs{ .cancel = &cancel, .io = io }});
    defer sup.join();

    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
    }, io, &cancel, null);
    defer client.close();

    const ms_100: std.Io.Clock.Duration = .{
        .raw = .fromMilliseconds(100),
        .clock = .awake,
    };
    var i: u32 = 0;
    while (true) : (i += 1) {
        client.ping(&cancel) catch |e| switch (e) {
            error.Cancelled => {
                std.debug.print("[loop] cancelled after {d} pings\n", .{i});
                break;
            },
            else => return e,
        };
        ms_100.sleep(io) catch break;
    }

    std.debug.print("[loop] reusable={}, broken={}\n", .{ client.isReusable(), client.is_broken });
}
