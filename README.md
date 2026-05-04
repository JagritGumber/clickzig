# clickzig

A native-protocol ClickHouse client for Zig 0.16, designed for low-latency analytical and quant workloads.

**Status: in development, approaching v0.16.0 tag.** All core paths land before the first tag — no incremental versions. Track `main` for progress.

## what it is

clickzig speaks the ClickHouse native TCP protocol (port 9000 / 9440 TLS) directly from Zig. Architecturally locked for predictable allocation, swap-able I/O backends, and explicit cancellation.

## what works on `main` today

**Lifecycle**
- Handshake against ClickHouse 26.x (ServerHello parsing through revision 54_466)
- Ping / Pong liveness
- Observability via `Config.on_event` (every state transition fires a callback)
- Typed `ConnectError` with `Diagnostics` carrying parsed `ServerError`
- Pluggable `Transport` (built-in `TcpTransport`, `TlsTransport`, or swap in your own)

**Queries + INSERT**
- `Client.query()` returns a `ResultStream` iterator over server packets
- Block decoder for SELECT responses (Data + Progress + ProfileInfo + ProfileEvents + Log + Totals + Extremes + TableColumns)
- `Client.insert()` for bulk INSERT in Native format

**Column types**
- Primitives: UInt8/16/32/64/128, Int8/16/32/64/128, Float32/64, String, Bool
- Composite: Nullable(T), Array(T), FixedString(N), UUID
- Aliases: Date, Date32, DateTime, DateTime64, Enum8, Enum16, IPv4, IPv6
- Decimal(P, S) → Int32/Int64/Int128 based on precision (Decimal32/64/128 explicit aliases too)

**Pool + DSN**
- `Pool` with thread-safe acquire/release, broken-discard, optional max-lifetime expiry
- `clickzig.fromUri("clickhouse://user:pw@host:port/db?key=val")` → Config

**TLS**
- `TlsTransport` over `TcpTransport`, supports `.insecure` (dev) or `.system_ca` (production) verify modes

## known gaps before v0.16.0

- **Compression (LZ4 / ZSTD)** — server replies are uncompressed by default; client always negotiates `CompressionEnabled.Disable`. Lands once CityHash 1.0.2 frozen + LZ4 codec are vendored.
- **Decimal256** — needs i256; defer alongside compression work.
- **Tuple / Map / LowCardinality** — column types not yet decoded.
- **Async via `std.Io` fibers** — current API is sync.
- **Parameterised queries** — bindings via `?`/`{name:Type}` placeholders not yet implemented.

## design decisions worth knowing up front

- **Allocator split.** `Config.control_allocator` is long-lived (owns Client + ServerInfo + ServerError). A future `query_allocator` will be a per-query arena (resettable; O(1) free for ingest at 10M rows/sec).
- **Transport interface, not concrete `Stream`.** `Client` holds a vtable. Built-in `TcpTransport` covers TCP/DNS; future `Io.Uring`, `Kqueue`, unix-domain socket, or test mocks drop in without touching Client code.
- **Iterator-first query shape (locked, not yet implemented).** v0.17 `Client.query()` will return a `QueryStream` with `next() !?Block`. Decided now so the column-store decoder doesn't fight the API later.
- **Lifecycle observability built in.** `Config.on_event` fires at every state transition (connecting, hello_sent, pong_received, ...). Default null = zero overhead. Layer metrics or OTel adapters on top without library changes.
- **Single-thread per Client.** State machine is non-atomic by design. Use one Client per thread; a Pool wraps that in v0.17.
- **Cancellation via `*const std.atomic.Value(bool)`.** Polled at every I/O boundary in Client methods. Zig 0.16's `Future.cancel` is async-task-bound; for a sync API the atomic-bool is the right primitive.

## install

Not installable yet — no tagged release. Once `v0.16.0` ships, the install snippet will land here.

To preview from `main`, clone the repo and `@import("clickzig")` from a relative path or file URL.

## quick start: query

```zig
const std = @import("std");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = init.gpa,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
    }, init.io, null, null);
    defer client.close();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();

    var stream = try client.query("SELECT number, number * 2 FROM numbers(5)", arena.allocator(), null, .{});
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            for (0..b.num_rows) |i| std.debug.print("{d} -> {d}\n", .{ b.columns[0].column.UInt64[i], b.columns[1].column.UInt64[i] });
        },
        .end_of_stream => break,
        else => {},
    };
}
```

## quick start: insert

```zig
var ids = [_]u32{ 1, 2, 3 };
var labels = [_][]u8{ @constCast("alpha"), @constCast("beta"), @constCast("gamma") };
const cols = [_]clickzig.block.InsertColumn{
    .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
    .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
};
try client.insert(
    "INSERT INTO my_table (id, label) FORMAT Native",
    "",
    3,
    &cols,
    arena.allocator(),
    null,
    .{},
);
```

## quick start: pool

```zig
const pool = try clickzig.Pool.init(init.gpa, init.io, config, .{ .max_size = 16 });
defer pool.deinit();

const client = try pool.acquire(null);
defer pool.release(client);
try client.ping(null);
```

## quick start: dsn

```zig
var arena: std.heap.ArenaAllocator = .init(init.gpa);
defer arena.deinit();
const result = try clickzig.fromUri(
    "clickhouse://default:test@127.0.0.1:9000/analytics?client_name=ingest",
    arena.allocator(),
    .{ .control_allocator = init.gpa, .read_buffer_size = 64 * 1024, .write_buffer_size = 4 * 1024 },
);
const client = try clickzig.Client.connectTcp(result.config, init.io, null, null);
defer client.close();
```

## examples

Five focused, copy-pasteable examples in `examples/`. Each demonstrates one concept in isolation:

| | example | what it shows | run |
|---|---|---|---|
| 01 | `01_connect.zig` | minimal happy path | `zig build run-01-connect` |
| 02 | `02_diagnostics.zig` | catch `error.AuthenticationFailed`, inspect the server's parsed `ServerError` | `zig build run-02-diagnostics` |
| 03 | `03_observability.zig` | wire `Config.on_event` to log every lifecycle transition | `zig build run-03-observability` |
| 04 | `04_health_check.zig` | ping loop with cross-thread cancellation token | `zig build run-04-health-check` |
| 05 | `05_custom_transport.zig` | plug a `MemTransport` (canned bytes) into `Client.fromTransport` | `zig build run-05-custom-transport` |

`zig build examples` compiles all of them as a smoke check.

## error handling

Connect errors are typed and granular. The OS-level cause flows into specific `ConnectError` variants; protocol-level failures attach a parsed `ServerError` to the optional `Diagnostics`:

| variant | meaning |
|---|---|
| `AuthenticationFailed` | server rejected credentials (codes 192/193/194/516) |
| `ServerExceptionDuringHello` | server sent an Exception packet that wasn't auth-related |
| `ConnectionRefused` | TCP connect refused |
| `HostUnreachable` | no route to host |
| `DnsFailure` | hostname did not resolve |
| `ConnectTimeout` | dial exceeded `dial_timeout_ms` |
| `ProtocolError` | malformed wire bytes (overlong varint, unexpected packet, length cap) |
| `Cancelled` | caller's atomic bool flipped mid-handshake |
| `ConnectionFailed` | catch-all for unmapped OS errors |

## supported ClickHouse versions

Tested against ClickHouse 26.3.x. Pinned at `CLIENT_REVISION = 54_466`, which negotiates correctly against any server reporting 54_466 or higher. Older servers (down to ~21.x) should work; newer-revision fields are dormant until the pin is bumped.

## development

```bash
# unit tests (no infra)
zig build test

# end-to-end smoke against a running ClickHouse on localhost:9000
zig build smoke -- happy
zig build smoke -- ping
zig build smoke -- wrong-pass
zig build smoke -- unreachable
zig build smoke -- wrong-host
```

The smoke harness assumes `clickhouse/clickhouse-server:26.3` running locally with `default:test` credentials. CI runs all five against a service container on every push.

### release pipeline

`.github/workflows/release.yml` is wired to fire on `v*` tag pushes. It gates on `zig build test` + `zig build examples` at the tagged commit, then creates a GitHub Release with auto-generated notes. Will fire once on `v0.16.0` when the package is feature-complete.

## license

See `LICENSE` (Apache-2.0).
