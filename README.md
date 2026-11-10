<p align="center">
  <img src="https://cdn.simpleicons.org/clickhouse/FFCC01" alt="ClickHouse" height="86" align="middle">
  &nbsp;&nbsp;&nbsp;
  <img src="assets/plus.svg" alt="+" height="86" align="middle">
  &nbsp;&nbsp;&nbsp;
  <img src="https://cdn.simpleicons.org/zig/F7A41D" alt="Zig" height="86" align="middle">
</p>

<h1 align="center">clickzig</h1>

<h3 align="center">Native ClickHouse TCP for Zig 0.17</h3>

<p align="center">
  Async-ready over <code>std.Io</code>: streaming queries, Native INSERT, compression, pooling, TLS, parameters, external data, and broad ClickHouse type coverage.
</p>

<p align="center">
  <a href="https://github.com/JagritGumber/clickzig/actions/workflows/ci.yml"><img src="https://github.com/JagritGumber/clickzig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Zig-0.17-F7A41D?logo=zig&logoColor=white" alt="Zig 0.17">
  <img src="https://img.shields.io/badge/ClickHouse-26.3%20tested-FFCC01?logo=clickhouse&logoColor=black" alt="ClickHouse 26.3 tested">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0">
</p>

## at a glance

- ✅ **Supported for Zig 0.17** - `main` tracks Zig 0.17; the `0.16.0` branch keeps the Zig 0.16 line.
- 🔀 **Async via `std.Io`** - run queries concurrently with `io.async` / `io.concurrent` / `Io.Group`; cancel with `Future.cancel`, and clickzig tells the server to stop (protocol `Cancel`) while keeping the connection reusable.
- ⚡ **Native protocol** - talks ClickHouse TCP directly on `9000` or `9440` for TLS.
- 📡 **Streaming queries** - `Client.query()` returns a `ResultStream` over Data, Progress, Logs, Totals, Extremes, Exceptions, and EndOfStream.
- 📥 **Native INSERT** - bulk column-oriented INSERT with caller-owned buffers and explicit type names.
- 🧩 **Parameters + settings** - native `{name:Type}` parameters stay separate from ClickHouse settings.
- 📦 **External tables** - send named Native blocks alongside a query.
- 🗜️ **Compression** - LZ4 and ZSTD read/write frames, opt-in by config or per query.
- 🔐 **TLS + transports** - built-in TCP/TLS transports, plus a vtable for custom backends.
- 🧵 **Pool** - `std.Io`-safe acquire/release (threads or tasks), cancelable waits, broken-connection discard, and lifetime expiry.
- 🧬 **Type coverage** - primitives, Nullable, Array, Tuple, Map, Decimal, LowCardinality, JSON, Dynamic, Sparse, Geo aliases, and common ClickHouse aliases.
- 🛡️ **Security hardening** - allocation caps, timeout mapping, hostile-frame audit probes, and compression checksum validation.
- 🏎️ **Fast** - on par with or ahead of the C++ `clickhouse-client` on most read scans; see [benchmarks](#benchmarks).
- 🧪 **CI-backed smoke tests** - live ClickHouse tests cover compression, parameters, external data, pool, timeouts, cancellation, concurrency, and combined scenarios.

Versioning follows the Karl Seguin-style Zig package convention: branches target Zig compiler lines, not a normal semver release train. Package metadata is pinned to Zig 0.17 (`build.zig.zon` + `.zigversion`). The `0.16.0` branch is the long-lived Zig 0.16 line; a future `dev` branch may track Zig development snapshots.

## intentional non-goals

- **Multiplexing several queries over one connection** — the ClickHouse native protocol serves one query per connection at a time. Concurrency comes from several connections (`Pool`), not from interleaving on one.
- **SQL placeholder rewriting** — Go-style `?`, `$1`, and `@name` client-side rewriting is intentionally not implemented. Use native ClickHouse `{name:Type}` placeholders through `QueryOptions.parameters`.

## design decisions worth knowing up front

- **Allocator split.** `Config.control_allocator` is long-lived; query and insert calls accept a caller-owned allocator for per-query Blocks, ServerErrors, and scratch buffers.
- **Transport interface, not concrete `Stream`.** `Client` holds a vtable. Built-in `TcpTransport` covers TCP/DNS; alternate backends or test mocks drop in without touching Client code.
- **Iterator-first query shape.** `Client.query()` returns a `ResultStream` with `next() !?Packet`, so callers can stream Data, Progress, Log, Totals, Extremes, and Exception packets without buffering the full result.
- **Lifecycle observability built in.** `Config.on_event` fires at every state transition (connecting, hello_sent, pong_received, ...). Default null = zero overhead. Layer metrics or OTel adapters on top without library changes.
- **`std.Io` all the way down.** Every blocking step (dial, read, write, timeouts, pool waits) goes through the `Io` you pass in, so the same code is synchronous on `Io.Threaded` and concurrent under `io.async` / `io.concurrent` / `Io.Group`. Read/write timeouts use `Io.Batch` operations rather than helper tasks.
- **One in-flight call per Client.** The state machine is non-atomic by design. Give each concurrent task its own Client, or share a `Pool`.
- **Cancellation is `Io` cancellation.** `future.cancel(io)` / `group.cancel(io)` surfaces as `error.Canceled`. If the client was waiting for the next server packet it sends a protocol `Cancel`, drains the reply (bounded by `cancel_drain_timeout_ms`), and stays reusable; `ResultStream.cancel()` does the same when you just want to stop reading early.

## install

Depend on the branch that matches your Zig compiler:

```bash
zig fetch --save git+https://github.com/<owner>/clickzig#main
```

`main` targets Zig 0.17. Use the `0.16.0` branch for the maintained Zig 0.16 line. A future `dev` branch may target Zig development snapshots.

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
    }, init.io, null);
    defer client.close();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();

    var stream = try client.query("SELECT number, number * 2 FROM numbers(5)", arena.allocator(), .{});
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
    .{ .parameters = &params },
);
```

`QueryOptions.settings` remains separate from `QueryOptions.parameters`: settings change server execution behavior, while parameters feed ClickHouse native `{name:Type}` placeholders without SQL text interpolation. Parameter names must be ASCII identifiers such as `id`, `tenant_1`, or `_limit`; duplicate puts overwrite the old value in the map.

## quick start: pool

```zig
const pool = try clickzig.Pool.init(init.gpa, init.io, config, .{ .max_size = 16 });
defer pool.deinit();

const client = try pool.acquire();
defer pool.release(client);
try client.ping();
```

## quick start: async

```zig
// Fan out over a pool: each task gets its own connection.
var group: std.Io.Group = .init;
defer group.cancel(io);
for (&jobs) |*job| group.async(io, runJob, .{ pool, gpa, job });
try group.await(io);

// Deadline: cancel a slow query after 500ms. The server stops it too,
// and the connection goes back to the pool ready for reuse.
var slow = try io.concurrent(slowQuery, .{ pool, gpa });
try (std.Io.Clock.Duration{ .raw = .fromMilliseconds(500), .clock = .awake }).sleep(io);
_ = slow.cancel(io) catch |e| switch (e) {
    error.Canceled => {},
    else => return e,
};
```

Use `io.concurrent` (not `io.async`) when the caller must keep running while the task waits: `io.async` is allowed to run the task inline. See `examples/06_concurrent_queries.zig` for the full program.

> **Backend note (Zig 0.17.1):** `std.Io.Evented` (io_uring / kqueue) does not implement TCP networking yet — connect, `net_read`, and `net_write` are still `TODO` in std. Use `Io.Threaded`, which runs `async`/`concurrent` tasks on a thread pool and supports cancellation. clickzig only talks to the `Io` interface, so evented backends will work once std implements their networking.

## quick start: dsn

```zig
var arena: std.heap.ArenaAllocator = .init(init.gpa);
defer arena.deinit();
const result = try clickzig.fromUri(
    "clickhouse://default:test@127.0.0.1:9000/analytics?client_name=ingest",
    arena.allocator(),
    .{ .control_allocator = init.gpa, .read_buffer_size = 64 * 1024, .write_buffer_size = 4 * 1024 },
);
const client = try clickzig.Client.connectTcp(result.config, init.io, null);
defer client.close();
```

## examples

Six focused, copy-pasteable examples in `examples/`. Each demonstrates one concept in isolation:

| | example | what it shows | run |
|---|---|---|---|
| 01 | `01_connect.zig` | minimal happy path | `zig build run-01-connect` |
| 02 | `02_diagnostics.zig` | catch `error.AuthenticationFailed`, inspect the server's parsed `ServerError` | `zig build run-02-diagnostics` |
| 03 | `03_observability.zig` | wire `Config.on_event` to log every lifecycle transition | `zig build run-03-observability` |
| 04 | `04_health_check.zig` | ping loop in an `io.concurrent` task, stopped with `Future.cancel` | `zig build run-04-health-check` |
| 05 | `05_custom_transport.zig` | plug a `MemTransport` (canned bytes) into `Client.fromTransport` | `zig build run-05-custom-transport` |
| 06 | `06_concurrent_queries.zig` | `Pool` + `Io.Group` fan-out, and a query deadline via `Future.cancel` | `zig build run-06-concurrent-queries` |

`zig build examples` compiles all of them as a smoke check.

## benchmarks

<p align="center"><img src="assets/benchmarks.svg" alt="clickzig benchmark results: read throughput vs clickhouse-client, concurrent query scaling, ping latency, insert throughput" width="880"></p>

| workload | clickzig | clickhouse-client (C++) |
|---|---:|---:|
| UInt64 scan (20M rows) | 467.9M rows/s | 454.5M rows/s |
| UInt64 scan + LZ4 | 129.8M rows/s | 114.9M rows/s |
| String scan (5M rows) | 91.2M rows/s | 83.3M rows/s |
| String scan + LZ4 | 57.1M rows/s | 62.5M rows/s |
| INSERT 100k rows × 3 cols, Null engine | 1.7M rows/s | 1.6M rows/s |

Concurrent queries over a `Pool` (workers → queries/s): 1→101 · 2→152 · 4→216 · 8→265 · 16→266. Ping round trip p50 19 µs, p99 40 µs.

Zig 0.17.1 · ClickHouse 26.3 · AMD Ryzen 7 7840HS (16 threads) · Linux · Io.Threaded. Loopback TCP with client and server in the same container, so these numbers show client overhead, not network speed. `clickhouse-client` is a reference point rather than a strict head-to-head: it also re-encodes the Native output it receives. INSERT is server-bound, so both clients land at the same rate whatever the compression.

Reproduce (ClickHouse on `127.0.0.1:9000`, `default:test`):

```bash
zig build bench -Doptimize=ReleaseFast > run1.jsonl         # repeat for run2, run3
sh bench/reference_clickhouse_client.sh > ref.jsonl         # inside the ClickHouse container
python3 bench/collect.py --env "<machine>" --reference ref.jsonl run*.jsonl > bench/results.json
python3 bench/plot.py bench/results.json assets/benchmarks.svg
```

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
| `Canceled` | the calling `std.Io` task was canceled (`Future.cancel` / `Group.cancel`) |
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

# async + cancellation scenarios (cancel-query, stream-cancel, cancel-race, pool-cancel, fanout)
zig build smoke-async -- all
```

Scenarios: `happy`, `ping`, `wrong-pass`, `unreachable`, `wrong-host`, `query-bytes`, `query-mixed`, `insert-roundtrip`, `nullable-roundtrip`, `complex-types`, `tuple-map`, `decimal-ip`, `column-coverage`, `pool`, `pool-loop`, `dsn`, `compression`, `insert-compression`, `insert-zstd`, `nested-compressed-insert`, `lowcardinality`, `lc-write`, `timeout`, `read-timeout`, `write-timeout`, `json`, `dynamic`, `parameters`, `geo`, `external-data`, `combined-features`.

The smoke harness assumes `clickhouse/clickhouse-server:26.3` running locally with `default:test` credentials. CI runs every scenario against a service container on every push.

### branch policy

`main` targets the latest supported stable Zig line for this repository: currently Zig 0.17. The `0.16.0` branch is the maintained Zig 0.16 line. A future `dev` branch may track Zig development snapshots. Do not create GitHub Releases or semver tag trains for normal development.

## license

See `LICENSE` (Apache-2.0).
