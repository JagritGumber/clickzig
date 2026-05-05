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
- Primitives: UInt8/16/32/64/128/256, Int8/16/32/64/128/256, Float32/64, String, Bool
- Composite: Nullable(T), Array(T), FixedString(N), UUID, Tuple(...), Map(K, V)
- Aliases: Date, Date32, DateTime, DateTime64, Enum8, Enum16, IPv4, IPv6
- Decimal(P, S) → Int32/Int64/Int128/Int256 based on precision (Decimal32/64/128/256 explicit aliases too)
- LowCardinality(T) and LowCardinality(Nullable(T)) (read-side, materialized to T)

**Compression**
- LZ4 frames on both SELECT and INSERT (CityHash 1.0.2 frame checksum, vendored encoder + decoder)
- ZSTD frames decoded on the read side via stdlib (no encoder yet)

**Pool + DSN**
- `Pool` with thread-safe acquire/release, broken-discard, optional max-lifetime expiry
- `clickzig.fromUri("clickhouse://user:pw@host:port/db?key=val")` → Config

**TLS**
- `TlsTransport` over `TcpTransport`, supports `.insecure` (dev) or `.system_ca` (production) verify modes

## known gaps before v0.16.0

- **LowCardinality writes** — encoded only on the read side. Insert into LC columns by going through `INSERT ... SELECT` or by materializing via the inner type (server side adapts).
- **Sparse / Dynamic / JSON** — surface as `error.UnsupportedColumnType`. Decoders need polymorphic-variant support that doesn't fit the v0.16.0 column union; deferred.
- **Async via `std.Io` fibers** — current API is sync. Iterator-first stream contract is locked so the column-store decoder doesn't fight the API later.
- **Parameterised queries** — bindings via `?`/`{name:Type}` placeholders not yet implemented; all queries are raw text + Native blocks for INSERT data.
- **ZSTD encoder** — read side decodes ZSTD frames; write side ships LZ4 only.

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

## porting from other clients

If you've used `clickhouse-go`, `clickhouse-rs` (klickhouse), or `clickhouse-cpp`, the **type-name strings are identical** — clickzig matches every type literal the server exposes. What differs is the in-memory shape you read back:

| ClickHouse | clickzig shape | notes |
|---|---|---|
| `String` | `[][]u8` (one slice per row) | bytes are raw; not validated as UTF-8 |
| `FixedString(N)` | `FixedString { width, data }` | `data.len = num_rows * width`; row i is `data[i*width..][0..width]` |
| `Nullable(T)` | `*Nullable { mask, inner }` | `mask[i] == 1` means NULL; `inner.<TypeTag>[i]` holds the value |
| `Array(T)` | `*Array { offsets, inner }` | row i = `inner[offsets[i-1] .. offsets[i]]` (offsets[-1] = 0) |
| `Tuple(T1, T2, ...)` | `*Tuple { row_count, elements }` | `elements[k].<TypeTag>[i]` is the k-th element of row i |
| `Map(K, V)` | `*Map { offsets, keys, values }` | wire layout = `Array(Tuple(K, V))`; pair-flat |
| `Decimal(P, S)` | `Int32` / `Int64` / `Int128` / `Int256` | scaled int; divide by `10^S` to recover the rational |
| `IPv4` | `UInt32` | host order; format manually |
| `IPv6` | `FixedString { width=16 }` | 16 raw bytes per row |
| `UUID` | `[][16]u8` | 16 raw bytes per row, big-endian |
| `LowCardinality(T)` | materialized `T` | dict + indexes is decoded transparently; you see plain T |
| `LowCardinality(Nullable(T))` | materialized `*Nullable` | LC index 0 maps to `mask[i] = 1` |

**Allocation model.** Each `Block` owns its column buffers via the per-query allocator you passed to `client.query()`. Pass an arena and free in O(1) at end-of-query — clickzig deliberately does not pool buffers internally because that fights cancellation semantics.

**INSERT shape.** `client.insert()` takes `InsertColumn[]` slices that mirror the read shape (you build `[]u32`, `[][]u8`, `Nullable { mask, inner: .{ .UInt32 = ... } }`, and so on, then hand the slice in). No reflection-driven row marshalling — the row-of-struct -> column-of-arrays conversion is yours to write or generate.

## supported ClickHouse versions

Tested against ClickHouse 26.3.x. Pinned at `CLIENT_REVISION = 54_466`, which negotiates correctly against any server reporting 54_466 or higher. Older servers (down to ~21.x) should work; newer-revision fields are dormant until the pin is bumped.

## development

```bash
# unit tests (no infra)
zig build test

# end-to-end smoke against a running ClickHouse on localhost:9000
zig build smoke -- <scenario>
```

Scenarios: `happy`, `ping`, `wrong-pass`, `unreachable`, `wrong-host`, `query-bytes`, `query-mixed`, `insert-roundtrip`, `nullable-roundtrip`, `complex-types`, `tuple-map`, `decimal-ip`, `pool`, `dsn`, `compression`, `insert-compression`, `lowcardinality`.

The smoke harness assumes `clickhouse/clickhouse-server:26.3` running locally with `default:test` credentials. CI runs every scenario against a service container on every push.

### release pipeline

`.github/workflows/release.yml` is wired to fire on `v*` tag pushes. It gates on `zig build test` + `zig build examples` at the tagged commit, then creates a GitHub Release with auto-generated notes. Will fire once on `v0.16.0` when the package is feature-complete.

## license

See `LICENSE` (Apache-2.0).
