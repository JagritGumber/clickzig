//! Example 02 — Server-error handling with Diagnostics.
//!
//! Connecting with a wrong password makes the server send back an
//! Exception packet during the handshake. clickzig parses it, maps
//! known auth codes to `error.AuthenticationFailed`, and (if the caller
//! provided a `Diagnostics`) attaches the parsed `ServerError` so you
//! can inspect code, name, and message.
//!
//! Concepts:
//!   - `Diagnostics` is opt-in: pass `null` if you don't care.
//!   - The same diagnostic shape is reused by future query/insert
//!     paths — learn it once, use everywhere.
//!   - `ServerError.codeName()` resolves common codes to their symbolic
//!     name (516 → AUTHENTICATION_FAILED, 60 → UNKNOWN_TABLE, etc.).

const std = @import("std");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var diag: clickzig.Diagnostics = .{};
    defer diag.deinit();

    const result = clickzig.Client.connectTcp(.{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "definitely-not-the-password",
    }, io, null, &diag);

    if (result) |client| {
        client.close();
        std.debug.print("unexpected: connected with bad password\n", .{});
        return error.UnexpectedSuccess;
    } else |e| switch (e) {
        error.AuthenticationFailed => {
            const exc = diag.server_exception orelse return error.MissingDiagnostic;
            std.debug.print("auth rejected by server\n", .{});
            std.debug.print("  code: {d} ({s})\n", .{ exc.code, exc.codeName() orelse "unknown" });
            std.debug.print("  msg:  {s}\n", .{exc.message});
        },
        else => return e,
    }
}
