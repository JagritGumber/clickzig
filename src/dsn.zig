//! DSN (data-source-name) parsing for clickzig Config.
//!
//! Accepts URLs of the form:
//!   clickhouse://[user[:password]@]host[:port][/database][?key=value...]
//!
//! Examples:
//!   clickhouse://localhost
//!   clickhouse://default:test@127.0.0.1:9000/analytics
//!   clickhouse://user@host.example.com:9440/db?client_name=ingest&max_threads=8
//!
//! All percent-encoded components are decoded into the supplied
//! `arena` allocator. The returned Config holds slices into that
//! arena — the arena MUST outlive the Client built from the Config.
//!
//! Recognised query parameters (any other key surfaces as a Settings
//! map entry, suitable for forwarding into Config.settings):
//!
//!   client_name        Override Hello packet client name.
//!
//! Defaults match Config defaults: port 9000, user "default", empty
//! password, database "default". Buffer sizes and timeouts must still
//! be filled in by the caller — DSNs don't traditionally encode them.

const std = @import("std");
const client_mod = @import("client.zig");

pub const ParseError = error{
    InvalidScheme,
    InvalidPort,
    OutOfMemory,
} || std.Uri.ParseError;

pub const Result = struct {
    config: client_mod.Config,
    /// Settings map populated from unrecognised query parameters.
    /// Lives in the same arena as `config`'s strings; null if no
    /// settings were present in the DSN.
    settings: ?*std.StringHashMapUnmanaged([]const u8) = null,
};

/// Parse a DSN into a Config. The caller must supply both the
/// long-lived `control_allocator` (for the Client itself) and an
/// `arena` for owned-string storage. Buffer sizes / timeouts must be
/// passed in via `defaults` — DSNs don't traditionally encode them.
pub fn fromUri(
    dsn: []const u8,
    arena: std.mem.Allocator,
    defaults: client_mod.Config,
) ParseError!Result {
    const uri = try std.Uri.parse(dsn);
    if (!std.mem.eql(u8, uri.scheme, "clickhouse")) return error.InvalidScheme;

    var cfg = defaults;
    if (uri.host) |h| cfg.host = try h.toRawMaybeAlloc(arena);
    if (uri.port) |p| cfg.port = p;
    if (uri.user) |u| cfg.username = try u.toRawMaybeAlloc(arena);
    if (uri.password) |p| cfg.password = try p.toRawMaybeAlloc(arena);

    // Path → database. Strip leading slash; empty path stays default.
    const path_raw = try uri.path.toRawMaybeAlloc(arena);
    if (path_raw.len > 1 and path_raw[0] == '/') {
        cfg.database = path_raw[1..];
    } else if (path_raw.len > 0 and path_raw[0] != '/') {
        cfg.database = path_raw;
    }

    var settings_ptr: ?*std.StringHashMapUnmanaged([]const u8) = null;
    if (uri.query) |q_component| {
        const q_raw = try q_component.toRawMaybeAlloc(arena);
        var settings = try arena.create(std.StringHashMapUnmanaged([]const u8));
        settings.* = .empty;
        var any_setting = false;
        var iter = std.mem.splitScalar(u8, q_raw, '&');
        while (iter.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "client_name")) {
                cfg.client_name = try arena.dupe(u8, val);
            } else {
                try settings.put(arena, try arena.dupe(u8, key), try arena.dupe(u8, val));
                any_setting = true;
            }
        }
        if (any_setting) {
            cfg.settings = settings;
            settings_ptr = settings;
        }
    }

    return .{ .config = cfg, .settings = settings_ptr };
}

const testing = std.testing;

test "fromUri parses host + port + user + password + database" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try fromUri(
        "clickhouse://default:test@127.0.0.1:9000/analytics",
        arena.allocator(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 64 * 1024,
            .write_buffer_size = 4 * 1024,
        },
    );
    try testing.expectEqualStrings("127.0.0.1", result.config.host);
    try testing.expectEqual(@as(u16, 9000), result.config.port);
    try testing.expectEqualStrings("default", result.config.username);
    try testing.expectEqualStrings("test", result.config.password);
    try testing.expectEqualStrings("analytics", result.config.database);
}

test "fromUri host-only inherits defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try fromUri(
        "clickhouse://localhost",
        arena.allocator(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 64 * 1024,
            .write_buffer_size = 4 * 1024,
        },
    );
    try testing.expectEqualStrings("localhost", result.config.host);
    try testing.expectEqual(@as(u16, 9000), result.config.port);
    try testing.expectEqualStrings("default", result.config.username);
    try testing.expectEqualStrings("default", result.config.database);
}

test "fromUri rejects non-clickhouse scheme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidScheme, fromUri(
        "postgres://localhost",
        arena.allocator(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 1024,
            .write_buffer_size = 1024,
        },
    ));
}

test "fromUri extracts client_name from query string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try fromUri(
        "clickhouse://localhost/?client_name=ingest-pipeline",
        arena.allocator(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 1024,
            .write_buffer_size = 1024,
        },
    );
    try testing.expectEqualStrings("ingest-pipeline", result.config.client_name.?);
}

test "fromUri puts unrecognised query params into settings map" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try fromUri(
        "clickhouse://localhost/?max_threads=8&max_memory_usage=1000000",
        arena.allocator(),
        .{
            .control_allocator = testing.allocator,
            .read_buffer_size = 1024,
            .write_buffer_size = 1024,
        },
    );
    const s = result.settings.?;
    try testing.expectEqualStrings("8", s.get("max_threads").?);
    try testing.expectEqualStrings("1000000", s.get("max_memory_usage").?);
}
