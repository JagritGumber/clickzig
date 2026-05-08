# clickzig

A native-protocol ClickHouse client for Zig 0.16, designed for low-latency analytical and quant workloads.

**Status: supported for Zig 0.16.0.** Track `main` for the current stable Zig line.
Versioning follows the Karl Seguin-style Zig package convention: branches target Zig compiler lines, not a normal semver release train. Package metadata is pinned to Zig 0.16.0 (`build.zig.zon` + `.zigversion`). The `0.16.0` branch is the long-lived Zig 0.16 line; a future `dev` branch may track Zig development snapshots.

## what it is

clickzig speaks the ClickHouse native TCP protocol (port 9000 / 9440 TLS) directly from Zig. Architecturally locked for predictable allocation, swap-able I/O backends, and explicit cancellation.

## supported on `main`

**Lifecycle**
- Handshake against ClickHouse 26.x (ServerHello parsing through revision 54_466)
- Ping / Pong liveness
- Observability via `Config.on_event` (every state transition fires a callback)
- Typed `ConnectError` with `Diagnostics` carrying parsed `ServerError`
- Pluggable `Transport` (built-in `TcpTransport`, `TlsTransport`, or swap in your own)

**Queries + INSERT**
- `Client.query()` returns a `ResultStream` iterator over server packets
- Native ClickHouse query parameters via `{name:Type}` placeholders and `clickzig.Parameters`
- Block decoder for SELECT responses (Data + Progress + ProfileInfo + ProfileEvents + Log + Totals + Extremes + TableColumns)
- `Client.insert()` for bulk INSERT in Native format

**Column types**
- Primitives: UInt8/16/32/64/128/256, Int8/16/32/64/128/256, Float32/64, String, Bool
- Composite: Nullable(T), Array(T), FixedString(N), UUID, Tuple(...), Map(K, V)
- Aliases: Date, Date32, DateTime, DateTime64, Enum8, Enum16, IPv4, IPv6
- Decimal(P, S) → Int32/Int64/Int128/Int256 based on precision (Decimal32/64/128/256 explicit aliases too)
- LowCardinality(T) and LowCardinality(Nullable(T)) — read materializes to T; INSERT encodes a per-block dictionary on the fly (numeric, String, FixedString inner)
- JSON, Dynamic, and Sparse(T) custom serialization coverage for the supported Native modes

**Compression**
- Opt-in compression via `Config.compression = .Enable` or per-query `QueryOptions.compression = .Enable`
- LZ4 frames on both SELECT and INSERT (CityHash 1.0.2 frame checksum, vendored encoder + decoder)
- ZSTD frames on read and write via stdlib/raw-block encoder

**Pool + DSN**
- `Pool` with thread-safe acquire/release, broken-discard, optional max-lifetime expiry
- `clickzig.fromUri("clickhouse://user:pw@host:port/db?key=val")` → Config

**TLS**
- `TlsTransport` over `TcpTransport`, supports `.insecure` (dev) or `.system_ca` (production) verify modes

## intentional non-goals for v0.16.0

- **Async via `std.Io` fibers** — current API is sync. Iterator-first stream contract is locked so the column-store decoder doesn't fight the API later.
- **SQL placeholder rewriting** — Go-style `?`, `$1`, and `@name` client-side rewriting is intentionally not implemented. Use native ClickHouse `{name:Type}` placeholders through `QueryOptions.parameters`.

## design decisions worth knowing up front

- **Allocator split.** `Config.control_allocator` is long-lived; query and insert calls accept a caller-owned allocator for per-query Blocks, ServerErrors, and scratch buffers.
- **Transport interface, not concrete `Stream`.** `Client` holds a vtable. Built-in `TcpTransport` covers TCP/DNS; alternate backends or test mocks drop in without touching Client code.
- **Iterator-first query shape.** `Client.query()` returns a `ResultStream` with `next() !?Packet`, so callers can stream Data, Progress, Log, Totals, Extremes, and Exception packets without buffering the full result.
- **Lifecycle observability built in.** `Config.on_event` fires at every state transition (connecting, hello_sent, pong_received, ...). Default null = zero overhead. Layer metrics or OTel adapters on top without library changes.
- **Single-thread per Client.** State machine is non-atomic by design. Use one Client per thread or the built-in `Pool` for multi-threaded workloads.
- **Cancellation via `*const std.atomic.Value(bool)`.** Polled at every I/O boundary in Client methods. Zig 0.16's `Future.cancel` is async-task-bound; for a sync API the atomic-bool is the right primitive.

## install

Depend on the branch that matches your Zig compiler:

```bash
zig fetch --save git+https://github.com/<owner>/clickzig#main
```

`main` targets Zig 0.16.0. Use the `0.16.0` branch for the maintained Zig 0.16 line. A future `dev` branch may target Zig development snapshots.

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

## quick start: parameters

```zig
var params: clickzig.Parameters = .{};
defer params.deinit(arena.allocator());

try params.putUInt(arena.allocator(), "n", 41);
try params.putString(arena.allocator(), "label", "clickzig");
try params.putDate(arena.allocator(), "day", "2026-05-07");

var stream = try client.query(
    "SELECT {n:UInt64} + 1, {label:String}, toDate({day:String})",
    arena.allocator(),
    null,
    .{ .parameters = &params },
);
```

`QueryOptions.settings` remains separate from `QueryOptions.parameters`: settings change server execution behavior, while parameters feed ClickHouse native `{name:Type}` placeholders without SQL text interpolation. Parameter names must be ASCII identifiers such as `id`, `tenant_1`, or `_limit`; duplicate puts overwrite the old value in the map.

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

## documentation

The root README is the short overview. The full docs live in `docs/`:

- [`docs/getting-started.md`](docs/getting-started.md) — install, connect, query, insert, parameters, compression, and checks
- [`docs/api.md`](docs/api.md) — public API guide for `Config`, `Client`, `QueryOptions`, parameters, external tables, insert, pool, TLS, and DSN parsing
- [`docs/types.md`](docs/types.md) — ClickHouse type mapping and `Column` shapes
- [`docs/operations.md`](docs/operations.md) — smoke scenarios, CI gates, pooling, TLS, timeouts, and branch policy
- [`docs/security.md`](docs/security.md) — defensive caps, timeout behavior, compression/frame security, and audit probes

## error handling

Connect errors are typed and granular. The OS-level cause flows into specific `ConnectError` variants; protocol-level failures attach a parsed `ServerError` to the optional `Diagnostics`:

| variant | meaning |
|---|---|
| `AuthenticationFailed` | server rejected credentials (codes 192/193/194/516) |
| `ServerExceptionDuringHello` | server sent an Exception packet that wasn't auth-related |
| `ConnectionRefused` | TCP connect refused |
| `HostUnreachable` | no route to host |
| `DnsFailure` | hostname did not resolve |
| `ConnectTimeout` | TCP connect did not complete within `dial_timeout_ms` |
| `ReadTimeout` | established socket read exceeded `read_timeout_ms` |
| `WriteTimeout` | established socket write exceeded `write_timeout_ms` |
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
| `Nested(x T, y U)` | `*Array { inner = Tuple(T, U) }` | ClickHouse alias for an array of named tuple fields |
| `Decimal(P, S)` | `Int32` / `Int64` / `Int128` / `Int256` | scaled int; divide by `10^S` to recover the rational |
| `IPv4` | `UInt32` | host order; format manually |
| `IPv6` | `FixedString { width=16 }` | 16 raw bytes per row |
| `UUID` | `[][16]u8` | 16 raw bytes per row, big-endian |
| `DateTime64(...)` | `Int64` | signed fractional-second ticks |
| `Interval*` | `Int64` | raw interval count |
| `SimpleAggregateFunction(f, T)` | `T` | materialized as the underlying value type |
| Geo aliases | existing Tuple/Array shapes | `Point`, `Ring`, `LineString`, `Polygon`, etc. expand to ClickHouse's tuple/array layout |
| `LowCardinality(T)` | materialized `T` | dict + indexes is decoded transparently; you see plain T |
| `LowCardinality(Nullable(T))` | materialized `*Nullable` | LC index 0 maps to `mask[i] = 1` |
| `JSON` | `[][]u8` via `.JSON` | raw JSON text per row in Native JSON string mode |
| `Dynamic` | `*Dynamic { type_names, discriminators, values }` | `0xff` discriminator means NULL |
| `Sparse(T)` | materialized dense `T` where supported | sparse indexes are expanded into the existing column shape |

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

Scenarios: `happy`, `ping`, `wrong-pass`, `unreachable`, `wrong-host`, `query-bytes`, `query-mixed`, `insert-roundtrip`, `nullable-roundtrip`, `complex-types`, `tuple-map`, `decimal-ip`, `column-coverage`, `pool`, `pool-loop`, `dsn`, `compression`, `insert-compression`, `insert-zstd`, `nested-compressed-insert`, `lowcardinality`, `lc-write`, `timeout`, `read-timeout`, `write-timeout`, `json`, `dynamic`, `parameters`, `geo`, `external-data`, `combined-features`.

The smoke harness assumes `clickhouse/clickhouse-server:26.3` running locally with `default:test` credentials. CI runs every scenario against a service container on every push.

### branch policy

`main` targets the latest supported stable Zig line for this repository: currently Zig 0.16.0. The `0.16.0` branch is the maintained Zig 0.16 line. A future `dev` branch may track Zig development snapshots. Do not create GitHub Releases or semver tag trains for normal development.

## license

See `LICENSE` (Apache-2.0).
