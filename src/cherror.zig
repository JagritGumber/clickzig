//! ClickHouse error types.
//!
//! Two layers:
//!   1. ClientError - Zig error set for failures originating in the client
//!      (network, parse, type mismatch, protocol violation, auth).
//!   2. ServerError - heap-allocated wrapper for an error packet returned
//!      by the ClickHouse server, including the integer code, optional
//!      symbolic name, message, and optional server-side stack trace.
//!
//! When the server returns an error packet during a query, the client
//! stores the parsed ServerError on itself and returns
//! `ClientError.ServerErrorReceived` from the operation. Callers can then
//! retrieve the full ServerError via the client's accessor.

const std = @import("std");

/// Client-side error set. Server-returned errors surface as
/// `ServerErrorReceived`; retrieve the full ServerError from the client.
pub const ClientError = error{
    /// Server returned an error packet during a query. Inspect details
    /// via the client's last_server_error field.
    ServerErrorReceived,
    /// Could not establish or maintain the TCP connection.
    ConnectionFailed,
    /// Wire protocol violation: unexpected packet ID, malformed varint,
    /// length mismatch, etc.
    ProtocolError,
    /// Could not parse data sent by the server (corrupted, truncated,
    /// or unknown type tag).
    ParseError,
    /// Column type cannot be coerced to the requested Zig type.
    TypeMismatch,
    /// Compression header bad, decompression failed, or checksum mismatch.
    CompressionError,
    /// Operation cancelled by caller or by the Io runtime.
    Cancelled,
    /// Authentication rejected (wrong user/password, db not permitted).
    AuthenticationFailed,
    /// Allocator returned OutOfMemory mid-decode. Re-exported so callers
    /// can match a single error set for both alloc and protocol failures.
    OutOfMemory,
};

/// Wrapper for a server-returned error. Owns its strings.
///
/// SECURITY NOTE — `name`, `message`, and `stack_trace` are RAW BYTES
/// from the server. They may contain ANSI escape sequences, OSC payloads,
/// or other terminal control characters. A hostile or compromised server
/// can use these to clear the user's terminal, rewrite the window title,
/// or (on some terminals) write to the clipboard. Do NOT pass these
/// directly to a TTY; sanitise C0/C1 controls before printing. A
/// `sanitisedMessage()` helper is planned for v0.17.
pub const ServerError = struct {
    /// Numeric error code from the server. Hundreds of codes exist in
    /// ClickHouse/src/Common/ErrorCodes.cpp; common ones are listed
    /// in the `Code` namespace below.
    code: u32,
    /// Server-supplied symbolic name (e.g. "DB::Exception::REQUIRED_PASSWORD").
    /// May be an empty string if the server did not include one. UNTRUSTED.
    name: []const u8,
    /// Human-readable error message. UNTRUSTED — see struct doc.
    message: []const u8,
    /// Optional server-side stack trace; presence depends on the server
    /// `send_logs_level` setting and per-query overrides. UNTRUSTED.
    stack_trace: ?[]const u8,

    allocator: std.mem.Allocator,

    /// Construct a ServerError taking ownership of the provided strings.
    /// Intended for internal use after reading the error packet off the
    /// wire; strings must already be allocated with `allocator`.
    pub fn takeOwned(
        allocator: std.mem.Allocator,
        code: u32,
        name: []const u8,
        message: []const u8,
        stack_trace: ?[]const u8,
    ) ServerError {
        return .{
            .code = code,
            .name = name,
            .message = message,
            .stack_trace = stack_trace,
            .allocator = allocator,
        };
    }

    /// Construct by duplicating the provided strings. Useful for tests
    /// or for synthesising errors outside the wire-decode path.
    pub fn dupe(
        allocator: std.mem.Allocator,
        code: u32,
        name: []const u8,
        message: []const u8,
        stack_trace: ?[]const u8,
    ) std.mem.Allocator.Error!ServerError {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const msg_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(msg_copy);
        const st_copy: ?[]const u8 = if (stack_trace) |st|
            try allocator.dupe(u8, st)
        else
            null;
        return .{
            .code = code,
            .name = name_copy,
            .message = msg_copy,
            .stack_trace = st_copy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: ServerError) void {
        self.allocator.free(self.name);
        self.allocator.free(self.message);
        if (self.stack_trace) |st| self.allocator.free(st);
    }

    /// Returns the symbolic name for `code` if it is one of the well-known
    /// codes listed in `Code`. Returns null for unknown codes (which are
    /// still valid; new ClickHouse versions add codes regularly).
    pub fn codeName(self: ServerError) ?[]const u8 {
        return Code.name(self.code);
    }
};

/// Subset of well-known ClickHouse server error codes. The full list lives
/// in upstream ClickHouse/src/Common/ErrorCodes.cpp; this subset covers
/// the codes a client is most likely to want to match against.
///
/// Codes are stable across ClickHouse versions (numeric values are part
/// of the protocol contract).
pub const Code = struct {
    pub const UNSUPPORTED_METHOD: u32 = 1;
    pub const UNSUPPORTED_PARAMETER: u32 = 2;
    pub const ATTEMPT_TO_READ_AFTER_EOF: u32 = 32;
    pub const CANNOT_READ_ALL_DATA: u32 = 33;
    pub const NUMBER_OF_COLUMNS_DOESNT_MATCH: u32 = 39;
    pub const SIZES_OF_COLUMNS_DOESNT_MATCH: u32 = 40;
    pub const UNKNOWN_TABLE: u32 = 60;
    pub const UNKNOWN_DATABASE: u32 = 81;
    pub const CANNOT_PARSE_INPUT_ASSERTION_FAILED: u32 = 117;
    pub const TOO_LARGE_STRING_SIZE: u32 = 131;
    pub const TOO_MANY_ROWS: u32 = 158;
    pub const TIMEOUT_EXCEEDED: u32 = 159;
    pub const UNKNOWN_USER: u32 = 192;
    pub const WRONG_PASSWORD: u32 = 193;
    pub const REQUIRED_PASSWORD: u32 = 194;
    pub const NETWORK_ERROR: u32 = 210;
    pub const SOCKET_TIMEOUT: u32 = 209;
    /// Modern (CH 22.x+) replacement for WRONG_PASSWORD/REQUIRED_PASSWORD.
    /// Returned for any failed auth: bad password, unknown user, etc.
    pub const AUTHENTICATION_FAILED: u32 = 516;

    /// Symbolic name for a known code, or null if the code is not in
    /// our subset. Unknown codes are still valid - new ClickHouse versions
    /// add codes; this lookup is only for ergonomic matching/printing.
    pub fn name(code: u32) ?[]const u8 {
        return switch (code) {
            UNSUPPORTED_METHOD => "UNSUPPORTED_METHOD",
            UNSUPPORTED_PARAMETER => "UNSUPPORTED_PARAMETER",
            ATTEMPT_TO_READ_AFTER_EOF => "ATTEMPT_TO_READ_AFTER_EOF",
            CANNOT_READ_ALL_DATA => "CANNOT_READ_ALL_DATA",
            NUMBER_OF_COLUMNS_DOESNT_MATCH => "NUMBER_OF_COLUMNS_DOESNT_MATCH",
            SIZES_OF_COLUMNS_DOESNT_MATCH => "SIZES_OF_COLUMNS_DOESNT_MATCH",
            UNKNOWN_TABLE => "UNKNOWN_TABLE",
            UNKNOWN_DATABASE => "UNKNOWN_DATABASE",
            CANNOT_PARSE_INPUT_ASSERTION_FAILED => "CANNOT_PARSE_INPUT_ASSERTION_FAILED",
            TOO_LARGE_STRING_SIZE => "TOO_LARGE_STRING_SIZE",
            TOO_MANY_ROWS => "TOO_MANY_ROWS",
            TIMEOUT_EXCEEDED => "TIMEOUT_EXCEEDED",
            UNKNOWN_USER => "UNKNOWN_USER",
            WRONG_PASSWORD => "WRONG_PASSWORD",
            REQUIRED_PASSWORD => "REQUIRED_PASSWORD",
            SOCKET_TIMEOUT => "SOCKET_TIMEOUT",
            NETWORK_ERROR => "NETWORK_ERROR",
            AUTHENTICATION_FAILED => "AUTHENTICATION_FAILED",
            else => null,
        };
    }
};

// --- tests ---

test "ServerError dupe owns and frees" {
    const ally = std.testing.allocator;
    const err = try ServerError.dupe(ally, 60, "DB::Exception", "Table 'foo' does not exist", null);
    defer err.deinit();
    try std.testing.expectEqual(@as(u32, 60), err.code);
    try std.testing.expectEqualStrings("DB::Exception", err.name);
    try std.testing.expectEqualStrings("Table 'foo' does not exist", err.message);
    try std.testing.expectEqual(@as(?[]const u8, null), err.stack_trace);
}

test "ServerError dupe with stack trace" {
    const ally = std.testing.allocator;
    const err = try ServerError.dupe(ally, 158, "DB::Exception", "Too many rows", "stack frame 1\nstack frame 2");
    defer err.deinit();
    try std.testing.expectEqualStrings("stack frame 1\nstack frame 2", err.stack_trace.?);
}

test "Code.name returns names for well-known codes" {
    try std.testing.expectEqualStrings("UNKNOWN_TABLE", Code.name(60).?);
    try std.testing.expectEqualStrings("REQUIRED_PASSWORD", Code.name(194).?);
    try std.testing.expectEqualStrings("WRONG_PASSWORD", Code.name(193).?);
    try std.testing.expectEqual(@as(?[]const u8, null), Code.name(99999));
}

test "ServerError.codeName uses Code.name" {
    const ally = std.testing.allocator;
    const err = try ServerError.dupe(ally, 60, "", "", null);
    defer err.deinit();
    try std.testing.expectEqualStrings("UNKNOWN_TABLE", err.codeName().?);
}

test "ClientError set is usable" {
    const example: ClientError!void = error.AuthenticationFailed;
    try std.testing.expectError(error.AuthenticationFailed, example);
}
