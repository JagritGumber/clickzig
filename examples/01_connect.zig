//! Example 01 — Minimal connect.
//!
//! The smallest possible clickzig program: dial a local ClickHouse,
//! print what the server told us about itself, close cleanly. Run with
//! `zig build run-01-connect` after starting a server on localhost:9000
//! (the default `clickhouse/clickhouse-server` image with `default:test`
//! credentials works out of the box).
//!
//! Concepts:
//!   - `Config` requires only allocator + buffer sizes; everything else
//!     defaults to localhost:9000 / default user / empty database.
//!   - `Client.connectTcp` returns a heap-allocated `*Client` owned by
//!     the caller; pair with `defer client.close()`.
//!   - `client.server_info` is populated by the handshake — read it
//!     synchronously after connect succeeds.

const std = @import("std");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
    }, io, null, null);
    defer client.close();

    const info = client.server_info;
    std.debug.print("connected to {s} {d}.{d}.{d} (revision {d})\n", .{
        info.name,
        info.major_version,
        info.minor_version,
        info.version_patch,
        info.revision,
    });
    if (info.timezone) |tz| std.debug.print("server timezone: {s}\n", .{tz});
    if (info.display_name) |dn| std.debug.print("display name:    {s}\n", .{dn});
    std.debug.print("negotiated protocol revision: {d}\n", .{info.negotiated(clickzig.protocol.CLIENT_REVISION)});
}
