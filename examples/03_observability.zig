//! Example 03 — Lifecycle observability with on_event hook.
//!
//! `Config.on_event` is a function pointer the library calls at every
//! significant lifecycle moment (connecting, hello_sent, ping_sent,
//! pong_received, closing, ...). The user supplies an opaque `ctx` that
//! the library passes back unchanged — typical use is a counter, a
//! metric handle, or an OpenTelemetry span.
//!
//! Concepts:
//!   - Default is `null`: zero overhead when unused.
//!   - The callback contract (no panic, no allocation, no reentrancy,
//!     no blocking) is enforced by convention — see Client doc.
//!   - This is the foundation for v0.17 metrics + OTel integrations
//!     without further breaking API changes.

const std = @import("std");
const clickzig = @import("clickzig");

const EventLog = struct {
    counts: std.EnumArray(clickzig.Event, u32) = .initFill(0),

    fn observe(event: clickzig.Event, ctx: ?*anyopaque) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx.?));
        self.counts.set(event, self.counts.get(event) + 1);
        std.debug.print("[event] {s}\n", .{@tagName(event)});
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var log: EventLog = .{};

    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
        .on_event = EventLog.observe,
        .on_event_ctx = &log,
    }, io, null, null);
    defer client.close();

    try client.ping(null);
    try client.ping(null);

    std.debug.print("\nfinal counts:\n", .{});
    var it = log.counts.iterator();
    while (it.next()) |entry| {
        if (entry.value.* > 0) {
            std.debug.print("  {s}: {d}\n", .{ @tagName(entry.key), entry.value.* });
        }
    }
}
