# API guide

This page documents the public API shape exposed from `@import("clickzig")`.
The API is synchronous and iterator-first. One `Client` owns one wire
connection and supports one in-flight operation at a time.

## Public imports

The root module re-exports the common types:

- `clickzig.Client`
- `clickzig.Config`
- `clickzig.QueryOptions`
- `clickzig.Parameters` / `clickzig.ParameterMap`
- `clickzig.ExternalTable`
- `clickzig.Block`
- `clickzig.Column`
- `clickzig.ResultStream`
- `clickzig.Packet`
- `clickzig.Pool` / `clickzig.PoolOptions`
- `clickzig.Transport`, `clickzig.TcpTransport`, `clickzig.TlsTransport`
- `clickzig.fromUri`

## Config

`Config` is the long-lived connection configuration:

```zig
const cfg: clickzig.Config = .{
    .control_allocator = allocator,
    .read_buffer_size = 64 * 1024,
    .write_buffer_size = 16 * 1024,
    .host = "127.0.0.1",
    .port = 9000,
    .username = "default",
    .password = "test",
    .database = "default",
};
```

Important fields:

| field | default | meaning |
|---|---:|---|
| `host` | `127.0.0.1` | TCP host |
| `port` | `9000` | ClickHouse native TCP port |
| `username` | `default` | ClickHouse user |
| `password` | empty | ClickHouse password |
| `database` | `default` | default database sent in Hello |
| `client_name` | null | custom client name, or library default |
| `control_allocator` | required | owns `Client`, server info, and connection diagnostics |
| `read_buffer_size` | required | transport read buffer size |
| `write_buffer_size` | required | transport write buffer size |
| `dial_timeout_ms` | `30000` | TCP connect timeout; `0` means infinite |
| `read_timeout_ms` | `60000` | socket read timeout; `0` means infinite |
| `write_timeout_ms` | `30000` | socket write timeout; `0` means infinite |
| `settings` | null | per-client default ClickHouse settings |
| `compression` | `.Disable` | opt-in wire compression |
| `compression_method` | `.lz4` | write method when compression is enabled |
| `on_event` | null | lifecycle callback |

`control_allocator` must outlive the `Client`. Per-query row/block buffers are
allocated from the allocator passed to `query` or `insert`, not from
`control_allocator`.

## Client lifecycle

```zig
const client = try clickzig.Client.connectTcp(cfg, io, cancel, diag);
defer client.close();
```

`cancel` is an optional `*const std.atomic.Value(bool)`. If it flips to `true`
before or during a supported I/O boundary, the operation returns
`error.Cancelled`.

`diag` is an optional `*clickzig.Diagnostics`. On handshake exceptions it can
hold a parsed `ServerError`.

One `Client` is not thread-safe. Use one client per thread or `clickzig.Pool`.

## Query

```zig
var stream = try client.query(sql, query_allocator, cancel, .{});

while (try stream.next()) |packet| switch (packet) {
    .data => |block| { /* read columns */ },
    .progress => |p| { _ = p; },
    .exception => |e| { _ = e; },
    .end_of_stream => break,
    else => {},
};
```

`query_allocator` owns every decoded `Block`, `ServerError`, and table metadata
object emitted by the stream. Passing an arena is the recommended pattern.

`ResultStream.next()` moves the client from `.busy` back to `.ready` when the
server sends EndOfStream. If a protocol or I/O error occurs, the client becomes
broken and should not be reused.

## QueryOptions

```zig
const opts: clickzig.QueryOptions = .{
    .query_id = "optional-id",
    .stage = .Complete,
    .compression = .Enable,
    .compression_method = .zstd,
    .settings = &settings,
    .parameters = &params,
    .external_tables = &external_tables,
};
```

| field | use |
|---|---|
| `query_id` | caller-provided query id, or empty for server-generated |
| `stage` | ClickHouse query processing stage, normally `.Complete` |
| `compression` | per-call compression override |
| `compression_method` | `.lz4` or `.zstd` for client-written Data frames |
| `settings` | per-query ClickHouse settings map |
| `parameters` | native `{name:Type}` query parameter map |
| `external_tables` | Native blocks sent as external tables after the Query packet |

## Parameters

```zig
var params: clickzig.Parameters = .{};
defer params.deinit(allocator);

try params.putString(allocator, "tenant", "acme");
try params.putInt(allocator, "delta", -10);
try params.putUInt(allocator, "limit", 100);
try params.putFloat(allocator, "ratio", 0.25);
try params.putBool(allocator, "active", true);
try params.putDate(allocator, "day", "2026-05-08");
try params.putDateTime(allocator, "created_at", "2026-05-08 13:30:00");
try params.putRaw(allocator, "advanced", "toDecimal64('12.30', 2)");
```

Parameter names must match `[A-Za-z_][A-Za-z0-9_]*`. Reusing a name overwrites
the previous value in the map.

`putRaw` is for callers who already have a ClickHouse literal string. Do not use
it for untrusted user input.

## Settings

Settings use `std.StringHashMapUnmanaged([]const u8)`:

```zig
var settings: clickzig.SettingsMap = .empty;
defer settings.deinit(allocator);

try settings.put(allocator, "max_threads", "4");
try settings.put(allocator, "readonly", "1");

var stream = try client.query(sql, allocator, null, .{
    .settings = &settings,
});
```

Settings and parameters are serialized into separate protocol sections.

## External tables

External tables are sent as named Native blocks before the empty query
terminator:

```zig
const rows = [_]u64{ 1, 2, 3 };
const ext_cols = [_]clickzig.block.InsertColumn{
    .{ .name = "id", .type_name = "UInt64", .data = .{ .UInt64 = &rows } },
};
const external = [_]clickzig.ExternalTable{
    .{ .name = "ids", .num_rows = rows.len, .columns = &ext_cols },
};

var stream = try client.query(
    "SELECT count() FROM ids",
    allocator,
    null,
    .{ .external_tables = &external },
);
```

Compression, settings, and parameters can be combined with external data in the
same `QueryOptions`.

## Insert

```zig
try client.insert(
    "INSERT INTO table_name (a, b) FORMAT Native",
    "",
    row_count,
    &columns,
    query_allocator,
    cancel,
    opts,
);
```

`columns` is a slice of `clickzig.block.InsertColumn`:

```zig
.{ .name = "a", .type_name = "UInt64", .data = .{ .UInt64 = values } }
```

The `type_name` string must match the server schema. Aliases such as `Date`,
`DateTime64(3)`, `Enum8(...)`, `LowCardinality(String)`, and `Nullable(UInt64)`
must be passed as the original ClickHouse type string.

## Pool

```zig
const pool = try clickzig.Pool.init(allocator, io, cfg, .{
    .max_size = 16,
    .max_lifetime_ms = 10 * 60 * 1000,
});
defer pool.deinit();

const client = try pool.acquire(null);
defer pool.release(client);
try client.ping(null);
```

The pool recycles clients only when `client.isReusable()` is true. Broken or
expired clients are closed instead of returned to the idle list.

## TLS

ClickHouse TLS uses a separate port, usually `9440`. Build a `TcpTransport`,
wrap it with `TlsTransport.over`, then pass the TLS transport into
`Client.fromTransport`.

Use `.system_ca` for production. `.insecure` skips certificate and hostname
verification and should be limited to local development.

## DSN parsing

```zig
const result = try clickzig.fromUri(
    "clickhouse://default:test@127.0.0.1:9000/analytics?max_threads=4",
    arena.allocator(),
    defaults,
);
const client = try clickzig.Client.connectTcp(result.config, io, null, null);
```

Unrecognized query parameters become ClickHouse settings. `client_name` is
handled specially and becomes `Config.client_name`.
