//! Example 05 — Custom Transport (no TCP).
//!
//! Demonstrates the architectural decision that `Client` does not bind
//! to `std.Io.net.Stream`: it holds a `Transport` vtable. Here we
//! plug in a `MemTransport` whose reader replays a canned ServerHello
//! byte stream and whose writer discards client-emitted bytes. No
//! sockets are opened.
//!
//! Why this matters:
//!   - **Testing**: build deterministic protocol tests without docker.
//!   - **Backend swap**: a future Io.Uring or Kqueue transport drops in
//!     here without touching Client code.
//!   - **Embedded**: clickzig can drive a unix-domain socket, an SSH
//!     tunnel, or anything else that exposes byte streams.
//!
//! This example exceeds 100 lines because the canned ServerHello
//! payload + the MemTransport vtable are both load-bearing illustrations
//! of one concept. Splitting would obscure the lesson.

const std = @import("std");
const clickzig = @import("clickzig");

const MemTransport = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    write_sink: [4096]u8 = undefined,

    pub fn init(reply_bytes: []const u8) MemTransport {
        return .{
            .reader = .fixed(reply_bytes),
            .writer = .fixed(undefined),
        };
    }

    fn rImpl(ptr: *anyopaque) *std.Io.Reader {
        return &@as(*MemTransport, @ptrCast(@alignCast(ptr))).reader;
    }
    fn wImpl(ptr: *anyopaque) *std.Io.Writer {
        const self: *MemTransport = @ptrCast(@alignCast(ptr));
        // Re-init writer to a fresh buffer per call so the discard sink
        // never fills up. (In a real backend you'd flush to your socket.)
        self.writer = .fixed(&self.write_sink);
        return &self.writer;
    }
    fn cImpl(_: *anyopaque) void {}
    fn srtImpl(_: *anyopaque, _: ?u32) anyerror!void {}
    fn swtImpl(_: *anyopaque, _: ?u32) anyerror!void {}

    const vtable: clickzig.Transport.VTable = .{
        .reader = rImpl,
        .writer = wImpl,
        .close = cImpl,
        .setReadTimeout = srtImpl,
        .setWriteTimeout = swtImpl,
    };

    pub fn transport(self: *MemTransport) clickzig.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// Build a synthetic ServerHello at revision 54_466 (matching pinned
/// CLIENT_REVISION) so the handshake completes against the canned reply.
fn buildCannedHello(buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const wire = clickzig.protocol;
    _ = wire;
    // Hello packet id = 0
    w.writeByte(0) catch unreachable;
    writeStr(&w, "FakeClickHouse");
    writeVarint(&w, 99); // major
    writeVarint(&w, 9); // minor
    writeVarint(&w, 54_466); // revision
    writeStr(&w, "UTC"); // timezone (gate >= 54_058)
    writeStr(&w, "fake-display"); // display_name (gate >= 54_372)
    writeVarint(&w, 7); // version_patch (gate >= 54_401)
    writeVarint(&w, 0); // password complexity rules count (gate >= 54_461)
    w.writeInt(u64, 0xAABBCCDD, .little) catch unreachable; // nonce (gate >= 54_462)
    return w.buffered();
}

fn writeStr(w: *std.Io.Writer, s: []const u8) void {
    writeVarint(w, s.len);
    w.writeAll(s) catch unreachable;
}

fn writeVarint(w: *std.Io.Writer, val: u64) void {
    var v = val;
    while (v >= 0x80) : (v >>= 7) w.writeByte(@as(u8, @intCast(v & 0x7F)) | 0x80) catch unreachable;
    w.writeByte(@as(u8, @intCast(v))) catch unreachable;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    _ = io;

    var canned: [256]u8 = undefined;
    const reply = buildCannedHello(&canned);
    var mem: MemTransport = .init(reply);

    const client = try clickzig.Client.fromTransport(.{
        .control_allocator = allocator,
        .read_buffer_size = 4096,
        .write_buffer_size = 4096,
    }, std.Io.Threaded.global_single_threaded.io(), mem.transport(), null, null);
    defer client.close();

    std.debug.print("handshake against canned bytes complete\n", .{});
    std.debug.print("  server name: {s}\n", .{client.server_info.name});
    std.debug.print("  revision:    {d}\n", .{client.server_info.revision});
    std.debug.print("  nonce:       0x{X}\n", .{client.server_info.nonce.?});
}
