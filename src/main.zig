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

pub const ClientError = cherror.ClientError;
pub const ServerError = cherror.ServerError;

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

pub const VERSION = "0.16.1";

test {
    std.testing.refAllDecls(@This());
}
