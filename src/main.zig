//! clickzig - native-protocol ClickHouse client for Zig 0.16+
//!
//! Status: v0.16.0-alpha. Sync TCP client targeting ClickHouse native
//! protocol. Async via std.Io fibers planned for v0.17.
//!
//! Public surface:
//!   - cherror.ClientError - error set for client-side failures
//!   - cherror.ServerError - parsed error packet from the server
//!   - cherror.Code        - well-known server error codes

const std = @import("std");

pub const cherror = @import("cherror.zig");
pub const protocol = @import("protocol.zig");
pub const ClientError = cherror.ClientError;
pub const ServerError = cherror.ServerError;

pub const VERSION = "0.16.0-alpha.1";

test {
    // Pull in tests from sub-modules.
    std.testing.refAllDecls(@This());
}
