//! ClickHouse Client — owns a Transport, runs the Hello/Addendum
//! handshake, exposes ping. Future query/insert paths layer on top.
//!
//! Lifecycle (state machine, decision #7 of the locked plan):
//!   .connecting   — TCP dial in progress (set by `connectTcp` only)
//!   .handshaking  — Hello write, ServerHello read, Addendum write
//!   .ready        — handshake complete, no in-flight operation
//!   .busy         — an operation (ping / future query) is in flight
//!   .broken       — an I/O or protocol error occurred; not reusable
//!   .closed       — `close()` has been called; do not reuse
//!
//! Every error path inside Client methods MUST execute
//! `self.is_broken = true; self.state = .broken;` before returning
//! the error. This is the contract that lets a future Pool decide
//! whether a returned connection is reusable. Audited per merge.
//!
//! `Client` is non-copyable (decision #12). Constructors return
//! `*Client` allocated from `config.control_allocator`. Caller pattern:
//!   const client = try Client.connectTcp(cfg, io, null, null);
//!   defer client.close();   // single-call; frees the Client struct
//!
//! THREAD-SAFETY: a single `Client` is NOT thread-safe. State machine
//! writes (`state`, `is_broken`, `last_used_at_ms`) are non-atomic.
//! The protocol contract is "one connection serves one in-flight
//! operation at a time" — concurrent calls from multiple threads on
//! the same `Client` are undefined behaviour. For multi-threaded
//! workloads, use one `Client` per thread (a connection pool wrapping
//! per-thread Clients lands in v0.17).
//!
//! Cancellation note: `*const std.atomic.Value(bool)` is the right
//! primitive for our sync API. Zig 0.16's `Future.cancel` is tied to
//! async task cancellation and would require restructuring every public
//! method around `io.async`. The atomic-bool stays.

const std = @import("std");
const protocol = @import("protocol.zig");
const transport_mod = @import("transport.zig");
const hello = @import("hello.zig");
const addendum = @import("addendum.zig");
const wire = @import("wire.zig");
const cherror = @import("cherror.zig");
const query_mod = @import("query.zig");
const client_info_mod = @import("client_info.zig");
const result_stream_mod = @import("result_stream.zig");
const block_mod = @import("block.zig");
const compression_mod = @import("compression.zig");

pub const ServerInfo = hello.ServerInfo;

pub const State = enum { connecting, handshaking, ready, busy, broken, closed };

pub const Event = enum {
    connecting,
    connected,
    hello_sent,
    hello_received,
    addendum_sent,
    server_exception_received,
    ping_sent,
    pong_received,
    query_sent,
    closing,
    closed,
};

pub const QueryError = error{
    ConnectionFailed,
    ProtocolError,
    Cancelled,
    OutOfMemory,
    ClientNotReady,
};

pub const Diagnostics = struct {
    server_exception: ?cherror.ServerError = null,
    last_packet_id: ?u64 = null,
    byte_offset: ?u64 = null,
    context: ?[]const u8 = null,

    pub fn deinit(self: Diagnostics) void {
        if (self.server_exception) |e| e.deinit();
    }
};

pub const ConnectError = error{
    /// Generic catch-all transport failure. Prefer the more specific
    /// variants below when the cause is known; this remains for the
    /// "we couldn't connect, ask the OS why" case.
    ConnectionFailed,
    /// TCP connection refused by the peer (port not listening, or the
    /// server-side ACL rejected the SYN).
    ConnectionRefused,
    /// No route to the target IP (network down, gateway missing, etc.).
    HostUnreachable,
    /// DNS lookup of `Config.host` did not resolve to any address.
    DnsFailure,
    /// Wire-protocol violation: malformed varint, unexpected packet ID,
    /// length cap exceeded, etc.
    ProtocolError,
    /// Server rejected our credentials (wrong password, unknown user).
    AuthenticationFailed,
    /// Server returned an Exception during handshake that wasn't an
    /// auth failure. Inspect `Diagnostics.server_exception` for detail.
    ServerExceptionDuringHello,
    /// Negotiated revision too old for this client (unused at v0.16,
    /// reserved for the v0.17 query path).
    UnsupportedServerRevision,
    /// TCP `connect` did not complete before `dial_timeout_ms`.
    ConnectTimeout,
    /// Read on an established socket exceeded `read_timeout_ms`. Not
    /// yet enforced at the OS level — tracked for v0.17 per-op timeouts.
    ReadTimeout,
    /// Write on an established socket exceeded `write_timeout_ms`. Same
    /// caveat as `ReadTimeout`.
    WriteTimeout,
    /// Caller-provided cancellation token observed `true`.
    Cancelled,
    OutOfMemory,
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,
    username: []const u8 = "default",
    password: []const u8 = "",
    database: []const u8 = "default",

    /// Application identifier sent in the Hello packet. Surfaces in the
    /// server's `system.query_log.client_name` and `system.processes`
    /// views, which is how multi-tenant operators correlate workload by
    /// service. Pass null to use the library default
    /// (`"ClickHouse clickzig"`). Must outlive the Client.
    client_name: ?[]const u8 = null,

    /// Long-lived allocator for Client + ServerInfo + ServerError.
    /// MUST outlive the Client. Cannot be enforced at compile time.
    control_allocator: std.mem.Allocator,

    /// Required: 64 KiB recommended for analytical, 4 KiB for control.
    read_buffer_size: usize,
    write_buffer_size: usize,

    /// Timeouts (ms). 0 = infinite (NOT recommended in prod). At
    /// v0.16.0-alpha only `dial_timeout_ms` is enforced (by TcpTransport
    /// at connect time). Read/write timeouts are stored on the
    /// transport but not yet wired to per-op Io.Timeout — see v0.17.
    dial_timeout_ms: u32 = 30_000,
    read_timeout_ms: u32 = 60_000,
    write_timeout_ms: u32 = 30_000,

    /// Forward field; used by future query path. Currently unused.
    settings: ?*const std.StringHashMapUnmanaged([]const u8) = null,

    /// Addendum capabilities. Defaults are safe (let server pick).
    proto_send_chunked: []const u8 = "notchunked_optional",
    proto_recv_chunked: []const u8 = "notchunked_optional",

    /// Compression negotiation. Default is Disable; setting Enable
    /// advertises LZ4 as the only supported codec (ZSTD encoder isn't
    /// in 0.16's stdlib, so we negotiate LZ4 even though decompress
    /// supports both). When enabled, every Data block sent or received
    /// is wrapped in a compression frame (16-byte CityHash128 +
    /// method + sizes + payload).
    compression: protocol.CompressionEnabled = .Disable,

    /// Observability hook. See decision #11+#15 for the contract:
    /// callback must NOT panic, allocate from control_allocator,
    /// reenter Client methods, or block. Library does not catch
    /// misbehaviour — undefined behaviour around close()/cleanup.
    on_event: ?*const fn (event: Event, ctx: ?*anyopaque) void = null,
    on_event_ctx: ?*anyopaque = null,
};

pub const Client = struct {
    config: Config,
    io: std.Io,
    transport: transport_mod.Transport,
    transport_owned: ?*transport_mod.TcpTransport,
    state: State,
    server_info: ServerInfo,
    is_broken: bool,
    connected_at_ms: i64,
    last_used_at_ms: i64,
    /// Per-query default compression mode, copied from config at
    /// connect time. Per-call override on sendQuery/insert is allowed.
    compression: protocol.CompressionEnabled = .Disable,

    /// Connect over TCP using the built-in TcpTransport.
    pub fn connectTcp(
        config: Config,
        io: std.Io,
        cancel: ?*const std.atomic.Value(bool),
        diag: ?*Diagnostics,
    ) ConnectError!*Client {
        emit(config, .connecting);
        if (cancellationRequested(cancel)) return error.Cancelled;

        const tcp = transport_mod.TcpTransport.connect(config.control_allocator, io, config.host, config.port, .{
            .read_buffer_size = config.read_buffer_size,
            .write_buffer_size = config.write_buffer_size,
            .dial_timeout_ms = config.dial_timeout_ms,
        }) catch |e| return mapTcpConnectError(e);
        errdefer {
            tcp.deinit();
            config.control_allocator.destroy(tcp);
        }

        // Stored on transport for future per-op enforcement (no-op today).
        tcp.transport().setReadTimeout(config.read_timeout_ms) catch {};
        tcp.transport().setWriteTimeout(config.write_timeout_ms) catch {};

        const client = try fromTransport(config, io, tcp.transport(), cancel, diag);
        client.transport_owned = tcp;
        return client;
    }

    /// Caller-owned Transport. Useful for swap-in mocks or alternate
    /// I/O backends (Uring, Kqueue, unix-domain socket).
    pub fn fromTransport(
        config: Config,
        io: std.Io,
        transport: transport_mod.Transport,
        cancel: ?*const std.atomic.Value(bool),
        diag: ?*Diagnostics,
    ) ConnectError!*Client {
        const client = config.control_allocator.create(Client) catch return error.OutOfMemory;
        errdefer config.control_allocator.destroy(client);

        const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        client.* = .{
            .config = config,
            .io = io,
            .transport = transport,
            .transport_owned = null,
            .state = .handshaking,
            .server_info = undefined,
            .is_broken = false,
            .connected_at_ms = now_ms,
            .last_used_at_ms = now_ms,
            .compression = config.compression,
        };

        if (cancellationRequested(cancel)) {
            client.is_broken = true;
            client.state = .broken;
            return error.Cancelled;
        }

        // --- Hello write + flush ---
        emit(config, .hello_sent);
        hello.writeClientHello(transport.writer(), config.database, config.username, config.password, config.client_name) catch |e| {
            client.is_broken = true;
            client.state = .broken;
            return mapWriteError(e);
        };
        transport.writer().flush() catch |e| {
            client.is_broken = true;
            client.state = .broken;
            return mapWriteError(e);
        };

        if (cancellationRequested(cancel)) {
            client.is_broken = true;
            client.state = .broken;
            return error.Cancelled;
        }

        // --- ServerHello / Exception read ---
        const result = hello.readHelloResult(transport.reader(), config.control_allocator) catch |e| {
            client.is_broken = true;
            client.state = .broken;
            return mapReadError(e);
        };
        switch (result) {
            .ok => |info| client.server_info = info,
            .server_exception => |exc| {
                emit(config, .server_exception_received);
                client.is_broken = true;
                client.state = .broken;
                if (diag) |d| {
                    d.server_exception = exc;
                } else {
                    exc.deinit();
                }
                // Map auth-related codes to AuthenticationFailed for
                // ergonomic catch-blocks. Modern CH (22.x+) collapsed
                // WRONG_PASSWORD/REQUIRED_PASSWORD into AUTHENTICATION_FAILED;
                // accept all three for cross-version compatibility.
                const is_auth = exc.code == cherror.Code.AUTHENTICATION_FAILED
                    or exc.code == cherror.Code.REQUIRED_PASSWORD
                    or exc.code == cherror.Code.WRONG_PASSWORD
                    or exc.code == cherror.Code.UNKNOWN_USER;
                return if (is_auth) error.AuthenticationFailed else error.ServerExceptionDuringHello;
            },
        }
        emit(config, .hello_received);
        errdefer client.server_info.deinit();

        if (cancellationRequested(cancel)) {
            client.is_broken = true;
            client.state = .broken;
            return error.Cancelled;
        }

        // --- Addendum write + flush (no-op for pre-54_458 servers) ---
        // Use the negotiated revision, NOT the server's reported revision —
        // we must only write addendum fields the server expects given OUR
        // claimed CLIENT_REVISION. (Server's reported revision can be higher.)
        const negotiated = client.server_info.negotiated(protocol.CLIENT_REVISION);
        addendum.writeClientAddendum(transport.writer(), .{
            .quota_key = "",
            .proto_send_chunked = config.proto_send_chunked,
            .proto_recv_chunked = config.proto_recv_chunked,
        }, negotiated) catch |e| {
            client.is_broken = true;
            client.state = .broken;
            return mapWriteError(e);
        };
        transport.writer().flush() catch |e| {
            client.is_broken = true;
            client.state = .broken;
            return mapWriteError(e);
        };
        emit(config, .addendum_sent);

        client.state = .ready;
        client.last_used_at_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        emit(config, .connected);
        return client;
    }

    /// Single-call. Closes transport (if owned), frees server_info, then
    /// destroys the Client struct itself.
    ///
    /// CONTRACT: after `close()` returns, the `*Client` pointer is freed
    /// memory. Calling ANY method on it (including `close()` again,
    /// `ping()`, or reading public fields like `server_info` or
    /// `transport`) is undefined behaviour — use-after-free, not just
    /// a state-check error. The internal `state == .closed` guard
    /// prevents partial re-execution within a single call (e.g. during
    /// hook callbacks); it does NOT make the function callable twice.
    /// Recommended pattern: `defer client.close()` exactly once.
    pub fn close(self: *Client) void {
        if (self.state == .closed) return;
        const cfg = self.config;
        emit(cfg, .closing);
        self.state = .closed;
        self.server_info.deinit();
        if (self.transport_owned) |tcp| {
            tcp.deinit();
            cfg.control_allocator.destroy(tcp);
        }
        emit(cfg, .closed);
        cfg.control_allocator.destroy(self);
    }

    /// Health check. Sends Ping, expects Pong. Updates last_used_at_ms.
    pub fn ping(
        self: *Client,
        cancel: ?*const std.atomic.Value(bool),
    ) ConnectError!void {
        if (self.state != .ready) return error.ConnectionFailed;
        if (cancellationRequested(cancel)) return error.Cancelled;
        self.state = .busy;

        wire.writeClientPacketId(self.transport.writer(), .Ping) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteError(e);
        };
        self.transport.writer().flush() catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteError(e);
        };
        emit(self.config, .ping_sent);

        if (cancellationRequested(cancel)) {
            self.is_broken = true;
            self.state = .broken;
            return error.Cancelled;
        }

        const pkt = wire.readServerPacketId(self.transport.reader()) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapReadError(e);
        };
        if (pkt != .Pong) {
            self.is_broken = true;
            self.state = .broken;
            return error.ProtocolError;
        }
        emit(self.config, .pong_received);
        self.state = .ready;
        self.last_used_at_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    /// True if this connection can serve another request. Consulted by
    /// future Pool to decide whether to recycle or discard.
    pub fn isReusable(self: *const Client) bool {
        return !self.is_broken and self.state == .ready;
    }

    /// Send a Query packet plus the empty Data terminator. Does NOT
    /// drain the response — that's the next commit's job. Today's value
    /// is purely "does the server accept our bytes without disconnecting"
    /// so we can validate wire format end-to-end before building the
    /// response decoder on top.
    ///
    /// State transition: .ready -> .busy. Caller must subsequently
    /// drive the result-stream reader (also coming next commit) which
    /// will land state back at .ready on EndOfStream.
    pub fn sendQuery(
        self: *Client,
        query_text: []const u8,
        cancel: ?*const std.atomic.Value(bool),
        opts_in: query_mod.QueryOptions,
    ) QueryError!void {
        if (self.state != .ready) return error.ClientNotReady;
        if (cancellationRequested(cancel)) return error.Cancelled;
        self.state = .busy;

        // If caller didn't override, fall back to the client-wide setting.
        var opts = opts_in;
        if (opts.compression == .Disable and self.compression == .Enable) opts.compression = .Enable;

        const negotiated = self.server_info.negotiated(protocol.CLIENT_REVISION);
        const info: client_info_mod.ClientInfo = .{
            .client_name = self.config.client_name orelse protocol.ClientName,
            .initial_query_start_time_microseconds = @intCast(@max(0, std.Io.Clock.now(.real, self.io).toMilliseconds() * std.time.us_per_ms)),
        };

        query_mod.writeClientQuery(self.transport.writer(), query_text, info, negotiated, opts) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        // Empty Data terminator. When compression is on, wrap the
        // BLOCK BODY (everything after the packet_id + table_name) in
        // an LZ4 frame; the packet header itself stays uncompressed.
        query_mod.writeDataPacketHeader(self.transport.writer(), "") catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        var body_alloc: std.heap.ArenaAllocator = .init(self.config.control_allocator);
        defer body_alloc.deinit();
        var body_buf: std.Io.Writer.Allocating = .init(body_alloc.allocator());
        defer body_buf.deinit();
        query_mod.writeEmptyBlockBody(&body_buf.writer, negotiated) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        compression_mod.writeMaybeCompressed(self.transport.writer(), body_alloc.allocator(), body_buf.written(), opts.compression) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        self.transport.writer().flush() catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        emit(self.config, .query_sent);
        self.last_used_at_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
    }

    /// Send a query and return a `ResultStream` the caller iterates with
    /// `next()` until it yields `null` (EndOfStream or Exception). The
    /// `query_allocator` owns every Block, ServerError, and TableColumns
    /// the stream emits — typical caller pattern is to pass an arena
    /// that's reset between queries (per quant-ingest hot-path policy).
    pub fn query(
        self: *Client,
        query_text: []const u8,
        query_allocator: std.mem.Allocator,
        cancel: ?*const std.atomic.Value(bool),
        opts: query_mod.QueryOptions,
    ) QueryError!result_stream_mod.ResultStream {
        const effective_compression: protocol.CompressionEnabled = if (opts.compression == .Enable or self.compression == .Enable) .Enable else .Disable;
        try self.sendQuery(query_text, cancel, opts);
        return .{
            .reader = self.transport.reader(),
            .allocator = query_allocator,
            .server_revision = self.server_info.negotiated(protocol.CLIENT_REVISION),
            .compression = effective_compression,
            .client_state = .{
                .state = self,
                .is_broken = &self.is_broken,
                .set_ready = setReadyImpl,
                .set_broken = setBrokenImpl,
            },
        };
    }

    /// INSERT entry point. The caller pre-builds typed columns with their
    /// canonical type-names and passes them in. We send the Query packet,
    /// drain the server's schema-block + any ProfileEvents, write the data
    /// block, write the empty terminator, then drain to EndOfStream.
    ///
    /// `query_text` must be a complete `INSERT INTO table (col1, col2, ...)`
    /// statement — the server uses it to validate column types before
    /// accepting our data block.
    pub fn insert(
        self: *Client,
        query_text: []const u8,
        table_name: []const u8,
        num_rows: u64,
        columns: []const block_mod.InsertColumn,
        query_allocator: std.mem.Allocator,
        cancel: ?*const std.atomic.Value(bool),
        opts: query_mod.QueryOptions,
    ) QueryError!void {
        try self.sendQuery(query_text, cancel, opts);
        const negotiated = self.server_info.negotiated(protocol.CLIENT_REVISION);
        const effective_compression: protocol.CompressionEnabled = if (opts.compression == .Enable or self.compression == .Enable) .Enable else .Disable;
        const log_pe_compression: protocol.CompressionEnabled = if (effective_compression == .Enable and negotiated >= protocol.Revision.WITH_COMPRESSED_LOGS_PROFILE_EVENTS_COLUMNS) .Enable else .Disable;

        // Drain the server's pre-data packets — at minimum the schema block
        // (Data with 0 rows). Server may also interleave Progress / Log /
        // ProfileEvents before signalling readiness for our data.
        // Data/Totals/Extremes ride compressed when compression is on;
        // Log/ProfileEvents are revision-gated (see protocol.zig).
        var schema_seen = false;
        while (!schema_seen) {
            const pkt = wire.readServerPacketId(self.transport.reader()) catch |e| {
                self.is_broken = true;
                self.state = .broken;
                return mapReadErrQuery(e);
            };
            switch (pkt) {
                .Data => {
                    // Discard the schema block — we trust the user's column
                    // types match. A future hardening pass could validate here.
                    const tn = wire.readStringOwned(self.transport.reader(), query_allocator, wire.MAX_DEFAULT_STRING) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    const block = block_mod.readMaybeCompressed(self.transport.reader(), query_allocator, negotiated, tn, effective_compression) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    block.deinit();
                    schema_seen = true;
                },
                .Exception => {
                    const exc = @import("exception.zig").readException(self.transport.reader(), query_allocator) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    exc.deinit();
                    self.is_broken = true;
                    self.state = .broken;
                    return error.ProtocolError;
                },
                .Totals, .Extremes => {
                    const tn = wire.readStringOwned(self.transport.reader(), query_allocator, wire.MAX_DEFAULT_STRING) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    const blk = block_mod.readMaybeCompressed(self.transport.reader(), query_allocator, negotiated, tn, effective_compression) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    blk.deinit();
                },
                .Log, .ProfileEvents => {
                    const tn = wire.readStringOwned(self.transport.reader(), query_allocator, wire.MAX_DEFAULT_STRING) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    const blk = block_mod.readMaybeCompressed(self.transport.reader(), query_allocator, negotiated, tn, log_pe_compression) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    blk.deinit();
                },
                .Progress => {
                    _ = result_stream_mod.ResultStream.readProgressBody(self.transport.reader(), negotiated) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                },
                .ProfileInfo => {
                    _ = result_stream_mod.ResultStream.readProfileInfoBody(self.transport.reader()) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                },
                .TableColumns => {
                    const tc = result_stream_mod.ResultStream.readTableColumnsBody(self.transport.reader(), query_allocator) catch |e| {
                        self.is_broken = true;
                        self.state = .broken;
                        return mapReadErrQuery(e);
                    };
                    tc.deinit(query_allocator);
                },
                else => {
                    self.is_broken = true;
                    self.state = .broken;
                    return error.ProtocolError;
                },
            }
        }

        // Write our data block: packet_id (uncompressed) + table_name
        // (uncompressed) + body (optionally LZ4-framed). Mirrors
        // upstream Connection::sendData where `name` goes to raw out and
        // only the block body is wrapped in `maybe_compressed_out`.
        wire.writeClientPacketId(self.transport.writer(), .Data) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        wire.writeStringBinary(self.transport.writer(), table_name) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        var body_buf: std.Io.Writer.Allocating = .init(query_allocator);
        defer body_buf.deinit();
        block_mod.writeBlockBody(&body_buf.writer, .{}, num_rows, columns, negotiated) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        compression_mod.writeMaybeCompressed(self.transport.writer(), query_allocator, body_buf.written(), effective_compression) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };

        // Empty terminator: header + body via the same helpers.
        query_mod.writeDataPacketHeader(self.transport.writer(), "") catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        var term_buf: std.Io.Writer.Allocating = .init(query_allocator);
        defer term_buf.deinit();
        query_mod.writeEmptyBlockBody(&term_buf.writer, negotiated) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        compression_mod.writeMaybeCompressed(self.transport.writer(), query_allocator, term_buf.written(), effective_compression) catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };
        self.transport.writer().flush() catch |e| {
            self.is_broken = true;
            self.state = .broken;
            return mapWriteErrQuery(e);
        };

        // Drain server response through EndOfStream via a temporary stream.
        // Set `compression` so Data/Totals/Extremes (and gated
        // Log/ProfileEvents) decode their compressed bodies correctly.
        var stream: result_stream_mod.ResultStream = .{
            .reader = self.transport.reader(),
            .allocator = query_allocator,
            .server_revision = negotiated,
            .compression = effective_compression,
            .client_state = .{
                .state = self,
                .is_broken = &self.is_broken,
                .set_ready = setReadyImpl,
                .set_broken = setBrokenImpl,
            },
        };
        while (try mapStreamErr(stream.next())) |packet| switch (packet) {
            .end_of_stream => break,
            .exception => |e| {
                e.deinit();
                return error.ProtocolError;
            },
            .data, .totals, .extremes, .log, .profile_events => |b| b.deinit(),
            .table_columns => |t| t.deinit(query_allocator),
            .progress, .profile_info => {},
        };
    }
};

fn mapReadErrQuery(e: anyerror) QueryError {
    return switch (e) {
        error.ReadFailed, error.EndOfStream => error.ConnectionFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled, error.Cancelled => error.Cancelled,
        else => error.ProtocolError,
    };
}

fn mapStreamErr(r: anytype) QueryError!@typeInfo(@TypeOf(r)).error_union.payload {
    return r catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolError,
    };
}

fn setReadyImpl(state: *anyopaque) void {
    const c: *Client = @ptrCast(@alignCast(state));
    c.state = .ready;
    c.last_used_at_ms = std.Io.Clock.now(.real, c.io).toMilliseconds();
}

fn setBrokenImpl(state: *anyopaque) void {
    const c: *Client = @ptrCast(@alignCast(state));
    c.state = .broken;
}

// --- private helpers -------------------------------------------------------

inline fn emit(cfg: Config, event: Event) void {
    if (cfg.on_event) |cb| {
        @branchHint(.unlikely);
        cb(event, cfg.on_event_ctx);
    }
}

inline fn cancellationRequested(cancel: ?*const std.atomic.Value(bool)) bool {
    if (cancel) |c| return c.load(.acquire);
    return false;
}

fn mapWriteError(e: anyerror) ConnectError {
    return switch (e) {
        error.WriteFailed => error.ConnectionFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled, error.Cancelled => error.Cancelled,
        else => error.ConnectionFailed,
    };
}

fn mapReadError(e: anyerror) ConnectError {
    return switch (e) {
        error.ReadFailed, error.EndOfStream => error.ConnectionFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled, error.Cancelled => error.Cancelled,
        error.OverlongVarint,
        error.VarintOverflow,
        error.UnknownServerPacket,
        error.UnexpectedPacket,
        error.StringTooLong,
        error.NestedExceptionsUnsupported,
        => error.ProtocolError,
        else => error.ConnectionFailed,
    };
}

fn mapWriteErrQuery(e: anyerror) QueryError {
    return switch (e) {
        error.WriteFailed => error.ConnectionFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled, error.Cancelled => error.Cancelled,
        else => error.ConnectionFailed,
    };
}

fn mapTcpConnectError(e: transport_mod.ConnectError) ConnectError {
    return switch (e) {
        error.ConnectionTimeout => error.ConnectTimeout,
        error.ConnectionRefused => error.ConnectionRefused,
        error.NetworkUnreachable => error.HostUnreachable,
        error.HostResolutionFailed, error.InvalidHost => error.DnsFailure,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
    };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "Diagnostics deinit handles missing exception" {
    const d: Diagnostics = .{};
    d.deinit();
}

test "isReusable false when broken" {
    var c: Client = .{
        .config = undefined,
        .io = undefined,
        .transport = undefined,
        .transport_owned = null,
        .state = .ready,
        .server_info = undefined,
        .is_broken = true,
        .connected_at_ms = 0,
        .last_used_at_ms = 0,
    };
    try testing.expect(!c.isReusable());
    c.is_broken = false;
    try testing.expect(c.isReusable());
    c.state = .busy;
    try testing.expect(!c.isReusable());
}

test "mapReadError categorizes protocol vs network failures" {
    try testing.expectEqual(ConnectError.ConnectionFailed, mapReadError(error.EndOfStream));
    try testing.expectEqual(ConnectError.ProtocolError, mapReadError(error.OverlongVarint));
    try testing.expectEqual(ConnectError.ProtocolError, mapReadError(error.UnknownServerPacket));
    try testing.expectEqual(ConnectError.OutOfMemory, mapReadError(error.OutOfMemory));
}

test "Event enum covers handshake + ping + close lifecycle" {
    // Compile-time check that the values listed in the plan are present.
    const _e = [_]Event{
        .connecting,        .connected,
        .hello_sent,        .hello_received,
        .addendum_sent,     .server_exception_received,
        .ping_sent,         .pong_received,
        .closing,           .closed,
    };
    _ = _e;
}
