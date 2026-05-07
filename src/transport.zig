//! Pluggable Transport interface for the clickzig Client.
//!
//! `Client` does NOT bind to `std.Io.net.Stream`. Instead it holds a
//! `Transport` vtable which exposes a `*std.Io.Reader`, `*std.Io.Writer`,
//! and `close()`. Alternate backends (Io.Uring, Kqueue, unix-domain
//! sockets, or synthetic mocks) can slot in without touching Client code.
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
//! Timeout note: Zig 0.16's threaded TCP connect implementation still
//! panics when std's per-connect timeout flag is used. TcpTransport
//! therefore enforces dial timeout by racing the normal connect path
//! against `Io.Timeout.sleep` and canceling the loser. Read/write
//! timeouts race the socket operation against a timer and retain the
//! underlying transport error so Client can map it to the public timeout
//! variants.

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
        lastReadError: *const fn (ptr: *anyopaque) ?anyerror,
        lastWriteError: *const fn (ptr: *anyopaque) ?anyerror,
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
    pub fn lastReadError(self: Transport) ?anyerror {
        return self.vtable.lastReadError(self.ptr);
    }
    pub fn lastWriteError(self: Transport) ?anyerror {
        return self.vtable.lastWriteError(self.ptr);
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
    ConcurrencyUnavailable,
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
    reader_state: TcpReader,
    writer_state: TcpWriter,
    read_timeout_ms: ?u32 = null,
    write_timeout_ms: ?u32 = null,
    socket_closed: bool = false,
    deinitialized: bool = false,

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

        const stream = connectWithTimeout(io, host, port, opts.dial_timeout_ms) catch |e| return e;
        errdefer stream.close(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader_state = .init(self, read_buf),
            .writer_state = .init(self, write_buf),
        };
        return self;
    }

    /// Close the socket, free buffers. Safe to call once. Caller is
    /// responsible for `allocator.destroy(self)` afterward (or relies on
    /// the Client to do it when `transport_owned` is set).
    pub fn deinit(self: *TcpTransport) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.closeSocket();
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
    }

    fn closeSocket(self: *TcpTransport) void {
        if (self.socket_closed) return;
        self.socket_closed = true;
        self.stream.close(self.io);
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
        .lastReadError = lastReadErrorImpl,
        .lastWriteError = lastWriteErrorImpl,
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
    }
    fn setWriteTimeoutImpl(ptr: *anyopaque, ms: ?u32) anyerror!void {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        self.write_timeout_ms = ms;
    }
    fn lastReadErrorImpl(ptr: *anyopaque) ?anyerror {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return self.reader_state.err;
    }
    fn lastWriteErrorImpl(ptr: *anyopaque) ?anyerror {
        const self: *TcpTransport = @ptrCast(@alignCast(ptr));
        return self.writer_state.err;
    }
};

const max_iovecs_len = 8;

fn timeoutFromMs(ms: u32) Io.Timeout {
    return .{ .duration = .{
        .raw = .fromMilliseconds(ms),
        .clock = .awake,
    } };
}

const TcpReader = struct {
    parent: *TcpTransport,
    interface: Io.Reader,
    err: ?anyerror = null,

    fn init(parent: *TcpTransport, buffer: []u8) TcpReader {
        return .{
            .parent = parent,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *TcpReader = @alignCast(@fieldParentPtr("interface", io_r));
        r.err = null;

        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);

        const n = if (r.parent.read_timeout_ms) |ms| blk: {
            if (ms == 0) break :blk try r.readNoTimeout(dest);
            break :blk try r.readWithTimeout(dest[0], ms);
        } else try r.readNoTimeout(dest);

        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            r.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn readNoTimeout(r: *TcpReader, dest: [][]u8) Io.Reader.Error!usize {
        const parent = r.parent;
        return parent.io.vtable.netRead(parent.io.userdata, parent.stream.socket.handle, dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
    }

    fn readWithTimeout(r: *TcpReader, dest: []u8, ms: u32) Io.Reader.Error!usize {
        const parent = r.parent;
        var dests = [_][]u8{dest};
        var queue_storage: [2]ReadResult = undefined;
        var queue: Io.Queue(ReadResult) = .init(&queue_storage);
        var group: Io.Group = .init;
        defer group.cancel(parent.io);

        group.concurrent(parent.io, readTask, .{ parent, &dests, &queue }) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        group.concurrent(parent.io, readTimeoutTask, .{ parent.io, ms, &queue }) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        const first = queue.getOne(parent.io) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        switch (first) {
            .read => |n| return n,
            .failed => |err| {
                r.err = err;
                return error.ReadFailed;
            },
            .timed_out => {
                r.err = error.Timeout;
                return error.ReadFailed;
            },
        }
    }
};

const ReadResult = union(enum) {
    read: usize,
    failed: anyerror,
    timed_out,
};

fn readTask(parent: *TcpTransport, dest: [][]u8, queue: *Io.Queue(ReadResult)) Io.Cancelable!void {
    const result: ReadResult = if (parent.io.vtable.netRead(parent.io.userdata, parent.stream.socket.handle, dest)) |n|
        .{ .read = n }
    else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => .{ .failed = err },
    };
    queue.putOne(parent.io, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

fn readTimeoutTask(io: Io, read_timeout_ms: u32, queue: *Io.Queue(ReadResult)) Io.Cancelable!void {
    try Io.Timeout.sleep(timeoutFromMs(read_timeout_ms), io);
    queue.putOne(io, .timed_out) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

const WriteResult = union(enum) {
    wrote: usize,
    failed: anyerror,
    timed_out,
};

const TcpWriter = struct {
    parent: *TcpTransport,
    interface: Io.Writer,
    err: ?anyerror = null,

    fn init(parent: *TcpTransport, buffer: []u8) TcpWriter {
        return .{
            .parent = parent,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .sendFile = sendFile,
                },
                .buffer = buffer,
            },
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *TcpWriter = @alignCast(@fieldParentPtr("interface", io_w));
        w.err = null;
        const n = if (w.parent.write_timeout_ms) |ms| blk: {
            if (ms == 0) break :blk try w.writeNoTimeout(io_w, data, splat);
            break :blk try w.writeWithTimeout(io_w, data, splat, ms);
        } else try w.writeNoTimeout(io_w, data, splat);
        return io_w.consume(n);
    }

    fn writeNoTimeout(w: *TcpWriter, io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const parent = w.parent;
        return parent.io.vtable.netWrite(parent.io.userdata, parent.stream.socket.handle, io_w.buffered(), data, splat) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
    }

    fn writeWithTimeout(w: *TcpWriter, io_w: *Io.Writer, data: []const []const u8, splat: usize, ms: u32) Io.Writer.Error!usize {
        const parent = w.parent;
        var queue_storage: [2]WriteResult = undefined;
        var queue: Io.Queue(WriteResult) = .init(&queue_storage);
        var group: Io.Group = .init;
        defer group.cancel(parent.io);

        group.concurrent(parent.io, writeTask, .{ parent, io_w.buffered(), data, splat, &queue }) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        group.concurrent(parent.io, writeTimeoutTask, .{ parent.io, ms, &queue }) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };

        const first = queue.getOne(parent.io) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        switch (first) {
            .wrote => |n| return n,
            .failed => |err| {
                w.err = err;
                return error.WriteFailed;
            },
            .timed_out => {
                w.err = error.Timeout;
                return error.WriteFailed;
            },
        }
    }

    fn sendFile(io_w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }
};

fn writeTask(
    parent: *TcpTransport,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    queue: *Io.Queue(WriteResult),
) Io.Cancelable!void {
    const result: WriteResult = if (parent.io.vtable.netWrite(parent.io.userdata, parent.stream.socket.handle, header, data, splat)) |n|
        .{ .wrote = n }
    else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => .{ .failed = err },
    };
    queue.putOne(parent.io, result) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

fn writeTimeoutTask(io: Io, write_timeout_ms: u32, queue: *Io.Queue(WriteResult)) Io.Cancelable!void {
    try Io.Timeout.sleep(timeoutFromMs(write_timeout_ms), io);
    queue.putOne(io, .timed_out) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

const DialResult = union(enum) {
    connected: Io.net.Stream,
    failed: ConnectError,
    timed_out,
};

fn connectWithTimeout(io: Io, host: []const u8, port: u16, dial_timeout_ms: u32) ConnectError!Io.net.Stream {
    if (dial_timeout_ms == 0) return connectNoStdTimeout(io, host, port);

    var queue_storage: [2]DialResult = undefined;
    var queue: Io.Queue(DialResult) = .init(&queue_storage);
    var group: Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, connectTask, .{ io, host, port, &queue });
    try group.concurrent(io, timeoutTask, .{ io, dial_timeout_ms, &queue });

    const first = queue.getOne(io) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => return error.ConnectionTimeout,
    };
    switch (first) {
        .connected => |stream| return stream,
        .failed => |err| return err,
        .timed_out => return error.ConnectionTimeout,
    }
}

fn connectTask(io: Io, host: []const u8, port: u16, queue: *Io.Queue(DialResult)) Io.Cancelable!void {
    const result: DialResult = if (connectNoStdTimeout(io, host, port)) |stream|
        .{ .connected = stream }
    else |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => .{ .failed = err },
    };
    queue.putOne(io, result) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => switch (result) {
            .connected => |stream| stream.close(io),
            else => {},
        },
    };
}

fn timeoutTask(io: Io, dial_timeout_ms: u32, queue: *Io.Queue(DialResult)) Io.Cancelable!void {
    const duration: Io.Clock.Duration = .{
        .raw = .fromMilliseconds(dial_timeout_ms),
        .clock = .awake,
    };
    try Io.Timeout.sleep(.{ .duration = duration }, io);
    queue.putOne(io, .timed_out) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

fn connectNoStdTimeout(io: Io, host: []const u8, port: u16) ConnectError!Io.net.Stream {
    // std.Io.Threaded panics on both Windows and POSIX if
    // options.timeout != .none as of Zig 0.16.0. Always pass .none
    // and let connectWithTimeout provide the budget.
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return Io.net.IpAddress.connect(&addr, io, .{
            .mode = .stream,
            .timeout = .none,
        }) catch |e| mapConnectError(e);
    } else |_| {
        const hn = Io.net.HostName.init(host) catch return error.InvalidHost;
        return Io.net.HostName.connect(hn, io, port, .{
            .mode = .stream,
            .timeout = .none,
        }) catch |e| mapHostConnectError(e);
    }
}

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
        fn lreImpl(_: *anyopaque) ?anyerror { return null; }
        fn lweImpl(_: *anyopaque) ?anyerror { return null; }
    };

    var mock: Mock = .{ .r = &rdr, .w = &wtr };
    const vt: Transport.VTable = .{
        .reader = Mock.rImpl,
        .writer = Mock.wImpl,
        .close = Mock.cImpl,
        .setReadTimeout = Mock.srtImpl,
        .setWriteTimeout = Mock.swtImpl,
        .lastReadError = Mock.lreImpl,
        .lastWriteError = Mock.lweImpl,
    };
    const t: Transport = .{ .ptr = &mock, .vtable = &vt };

    try testing.expectEqual(@as(u8, 1), try t.reader().takeByte());
    try t.writer().writeByte(0xFE);
    try testing.expectEqual(@as(u8, 0xFE), wtr.buffered()[0]);
    try t.setReadTimeout(1000);
    t.close();
    try testing.expect(mock.closed);
}
