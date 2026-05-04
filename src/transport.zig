//! Pluggable Transport interface for the clickzig Client.
//!
//! `Client` does NOT bind to `std.Io.net.Stream`. Instead it holds a
//! `Transport` vtable which exposes a `*std.Io.Reader`, `*std.Io.Writer`,
//! and `close()`. This lets a future caller swap in `Io.Uring`, a
//! `Kqueue` backend, a unix-domain socket, or a fully synthetic mock
//! without touching Client code.
//!
//! `TcpTransport` is the canonical built-in: connect over TCP via
//! `std.Io.net.IpAddress.connect` (IP literal) or
//! `std.Io.net.HostName.connect` (DNS).
//!
//! Lifecycle: heap-allocate via `TcpTransport.connect(...)`, take a
//! `Transport` view via `tcp.transport()`, hand that to `Client`. On
//! teardown the Client calls `transport.close()` which routes back to
//! `TcpTransport.close()` which closes the socket and frees buffers.
//! `TcpTransport` itself is destroyed by the caller (or by Client when
//! `transport_owned` is set).
//!
//! Note on timeouts: `setReadTimeout`/`setWriteTimeout` store the
//! requested ms value but DO NOT enforce it at the OS level in
//! v0.16.0-alpha. Per-operation timeouts via `std.Io.Timeout` land in
//! v0.17 alongside the query path. Documented loudly so callers don't
//! assume an OS-level guarantee.

const std = @import("std");
const Io = std.Io;

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reader: *const fn (ptr: *anyopaque) *Io.Reader,
        writer: *const fn (ptr: *anyopaque) *Io.Writer,
        close: *const fn (ptr: *anyopaque) void,
        setReadTimeout: *const fn (ptr: *anyopaque, ms: ?u32) anyerror!void,
        setWriteTimeout: *const fn (ptr: *anyopaque, ms: ?u32) anyerror!void,
    };

    pub fn reader(self: Transport) *Io.Reader {
        return self.vtable.reader(self.ptr);
    }
    pub fn writer(self: Transport) *Io.Writer {
        return self.vtable.writer(self.ptr);
    }
    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
    pub fn setReadTimeout(self: Transport, ms: ?u32) !void {
        return self.vtable.setReadTimeout(self.ptr, ms);
    }
    pub fn setWriteTimeout(self: Transport, ms: ?u32) !void {
        return self.vtable.setWriteTimeout(self.ptr, ms);
    }
};

pub const TcpOptions = struct {
    /// Caller-chosen reader buffer. Must be ≥ the largest "borrowed"
    /// string ever read (4 KiB for handshake; 64 KiB recommended for
    /// analytical workloads where block frames flow through the buffer).
    read_buffer_size: usize,
    /// Caller-chosen writer buffer. 4 KiB is fine for control flow;
    /// large INSERT paths benefit from 64 KiB so block flushes batch.
    write_buffer_size: usize,
    /// Connect dial timeout. 0 = infinite (NOT recommended in prod).
    dial_timeout_ms: u32 = 30_000,
};

pub const ConnectError = error{
    InvalidHost,
    HostResolutionFailed,
    ConnectionRefused,
    ConnectionTimeout,
    NetworkUnreachable,
    OutOfMemory,
} || Io.Cancelable;

/// TCP-over-std.Io.net transport. Heap-allocated because `reader_state`
/// and `writer_state` contain `Io.Reader` / `Io.Writer` interface fields
/// that use `@fieldParentPtr` — moving the struct invalidates them.
pub const TcpTransport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader_state: Io.net.Stream.Reader,
    writer_state: Io.net.Stream.Writer,
    read_timeout_ms: ?u32 = null,
    write_timeout_ms: ?u32 = null,
    closed: bool = false,

    /// Connect to `host:port`. `host` may be an IPv4/IPv6 literal or
    /// a DNS hostname. Returns a heap-allocated TcpTransport owned by
    /// the caller (or by the Client when handed off via `transport()`).
    pub fn connect(
        allocator: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        opts: TcpOptions,
    ) ConnectError!*TcpTransport {
        const self = allocator.create(TcpTransport) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);

        const read_buf = allocator.alloc(u8, opts.read_buffer_size) catch return error.OutOfMemory;
        errdefer allocator.free(read_buf);
        const write_buf = allocator.alloc(u8, opts.write_buffer_size) catch return error.OutOfMemory;
        errdefer allocator.free(write_buf);

        // std.Io.Threaded panics on both Windows (netConnectIpWindows) and
        // POSIX (netConnectIpPosix) if options.timeout != .none — both have
        // a `@panic("TODO implement ...")` guard as of Zig 0.16.0. We pass
        // .none everywhere and rely on the OS TCP connect timeout. Per-call
        // `dial_timeout_ms` enforcement lands in v0.17 alongside Io.Uring
        // and the proper per-op timeout wiring.
        _ = opts.dial_timeout_ms;
        const timeout: Io.Timeout = .none;

        const stream: Io.net.Stream = blk: {
            // Try IP literal first (cheap, no DNS).
            if (Io.net.IpAddress.parse(host, port)) |addr| {
                break :blk Io.net.IpAddress.connect(&addr, io, .{
                    .mode = .stream,
                    .timeout = timeout,
                }) catch |e| return mapConnectError(e);
            } else |_| {
                // Fall back to DNS.
                const hn = Io.net.HostName.init(host) catch return error.InvalidHost;
                break :blk Io.net.HostName.connect(hn, io, port, .{
                    .mode = .stream,
                    .timeout = timeout,
                }) catch |e| return mapHostConnectError(e);
            }
        };
        errdefer stream.close(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader_state = .init(stream, io, read_buf),
            .writer_state = .init(stream, io, write_buf),
        };
        return self;
    }

    /// Close the socket, free buffers. Safe to call once. Caller is
    /// responsible for `allocator.destroy(self)` afterward (or relies on
    /// the Client to do it when `transport_owned` is set).
    pub fn deinit(self: *TcpTransport) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
    }

    pub fn transport(self: *TcpTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .reader = readerImpl,
        .writer = writerImpl,
        .close = closeImpl,
        .setReadTimeout = setReadTimeoutImpl,
        .setWriteTimeout = setWriteTimeoutImpl,
    };

    fn readerImpl(ptr: *anyopaque) *Io.Reader {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return &self.reader_state.interface;
    }
    fn writerImpl(ptr: *anyopaque) *Io.Writer {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return &self.writer_state.interface;
    }
    fn closeImpl(ptr: *anyopaque) void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
    fn setReadTimeoutImpl(ptr: *anyopaque, ms: ?u32) anyerror!void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.read_timeout_ms = ms;
        // OS-level enforcement deferred to v0.17 when per-op Io.Timeout
        // is wired into the read/write paths. Storing for forward compat.
    }
    fn setWriteTimeoutImpl(ptr: *anyopaque, ms: ?u32) anyerror!void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.write_timeout_ms = ms;
    }
};

fn mapConnectError(e: Io.net.IpAddress.ConnectError) ConnectError {
    return switch (e) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.Timeout => error.ConnectionTimeout,
        error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => error.NetworkUnreachable,
        error.Canceled => error.Canceled,
        else => error.ConnectionRefused,
    };
}

fn mapHostConnectError(e: Io.net.HostName.ConnectError) ConnectError {
    return switch (e) {
        error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned => error.HostResolutionFailed,
        error.ConnectionRefused => error.ConnectionRefused,
        error.Timeout => error.ConnectionTimeout,
        error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => error.NetworkUnreachable,
        error.Canceled => error.Canceled,
        else => error.HostResolutionFailed,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Transport vtable round-trips through anyopaque" {
    // Synthetic transport over fixed buffers — exercises the vtable
    // dispatch without spinning up TCP. (Real TCP is exercised in the
    // smoke executable.)
    var read_buf: [16]u8 = .{ 1, 2, 3, 0 } ++ ([_]u8{0} ** 12);
    var write_buf: [16]u8 = undefined;
    var rdr: Io.Reader = .fixed(&read_buf);
    var wtr: Io.Writer = .fixed(&write_buf);

    const Mock = struct {
        r: *Io.Reader,
        w: *Io.Writer,
        closed: bool = false,
        fn rImpl(ptr: *anyopaque) *Io.Reader {
            const m: *@This() = @ptrCast(@alignCast(ptr));
            return m.r;
        }
        fn wImpl(ptr: *anyopaque) *Io.Writer {
            const m: *@This() = @ptrCast(@alignCast(ptr));
            return m.w;
        }
        fn cImpl(ptr: *anyopaque) void {
            const m: *@This() = @ptrCast(@alignCast(ptr));
            m.closed = true;
        }
        fn srtImpl(_: *anyopaque, _: ?u32) anyerror!void {}
        fn swtImpl(_: *anyopaque, _: ?u32) anyerror!void {}
    };

    var mock: Mock = .{ .r = &rdr, .w = &wtr };
    const vt: Transport.VTable = .{
        .reader = Mock.rImpl,
        .writer = Mock.wImpl,
        .close = Mock.cImpl,
        .setReadTimeout = Mock.srtImpl,
        .setWriteTimeout = Mock.swtImpl,
    };
    const t: Transport = .{ .ptr = &mock, .vtable = &vt };

    try testing.expectEqual(@as(u8, 1), try t.reader().takeByte());
    try t.writer().writeByte(0xFE);
    try testing.expectEqual(@as(u8, 0xFE), wtr.buffered()[0]);
    try t.setReadTimeout(1000);
    t.close();
    try testing.expect(mock.closed);
}
