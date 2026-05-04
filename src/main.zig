//! clickzig - native-protocol ClickHouse client for Zig 0.16+
//!
//! Status: v0.16.0-alpha. Sync TCP client targeting the ClickHouse
//! native protocol (port 9000). Async via std.Io fibers planned for
//! v0.17 alongside the query/insert API and connection pool.
//!
//! Usage sketch:
//!   var threaded: std.Io.Threaded = .init(gpa, .{});
//!   defer threaded.deinit();
//!   const io = threaded.io();
//!
//!   const client = try clickzig.Client.connectTcp(.{
//!       .control_allocator = gpa,
//!       .read_buffer_size = 64 * 1024,
//!       .write_buffer_size = 4 * 1024,
//!       .username = "default",
//!       .password = "test",
//!   }, io, null, null);
//!   defer client.close();
//!
//!   try client.ping(null);

const std = @import("std");

pub const cherror = @import("cherror.zig");
pub const protocol = @import("protocol.zig");
pub const client_info = @import("client_info.zig");
pub const query = @import("query.zig");
pub const settings = @import("settings.zig");
pub const column = @import("column.zig");
pub const block = @import("block.zig");
pub const result_stream = @import("result_stream.zig");
pub const pool = @import("pool.zig");
pub const Pool = pool.Pool;
pub const PoolOptions = pool.Options;
pub const dsn = @import("dsn.zig");
pub const fromUri = dsn.fromUri;

pub const ClientError = cherror.ClientError;
pub const ServerError = cherror.ServerError;
pub const ClientInfo = client_info.ClientInfo;
pub const QueryOptions = query.QueryOptions;
pub const Block = block.Block;
pub const Column = column.Column;
pub const Packet = result_stream.Packet;
pub const Progress = result_stream.Progress;
pub const ResultStream = result_stream.ResultStream;

const client_mod = @import("client.zig");
pub const Client = client_mod.Client;
pub const Config = client_mod.Config;
pub const Event = client_mod.Event;
pub const Diagnostics = client_mod.Diagnostics;
pub const ConnectError = client_mod.ConnectError;
pub const State = client_mod.State;
pub const ServerInfo = client_mod.ServerInfo;

const transport_mod = @import("transport.zig");
pub const Transport = transport_mod.Transport;
pub const TcpTransport = transport_mod.TcpTransport;
pub const TcpOptions = transport_mod.TcpOptions;

/// Loose-typed settings map. Per-Client default attached on Config;
/// per-query overrides land in v0.17 with the Query packet.
pub const SettingsMap = std.StringHashMapUnmanaged([]const u8);

pub const VERSION = "0.16.0";

test {
    std.testing.refAllDecls(@This());
}
