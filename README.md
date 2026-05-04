# clickzig

A native-protocol ClickHouse client for Zig 0.16, designed for low-latency analytical and quant workloads.

**Status: in development.** Not yet released. The first tagged release will be `v0.16.0`, mirroring Zig 0.16.0, and will ship the complete client (handshake + query + insert + compression + connection pool) as a single coherent package — no incremental tags between now and then. Track `main` if you want to see progress.

## what it is

clickzig speaks the ClickHouse native TCP protocol (port 9000) directly from Zig. Architecturally locked for predictable allocation, swap-able I/O backends, and explicit cancellation.

## what works on `main` today

- Connect / handshake against ClickHouse 26.x (ServerHello parsing through revision 54_466 with full revision-gated reads)
- Ping for liveness
- Lifecycle observability via `Config.on_event`
- Pluggable `Transport` (built-in `TcpTransport`, swap in your own)
- Typed `ConnectError` with `Diagnostics` carrying parsed `ServerError`

## what's still being built before v0.16.0 tags

- Query / Data / Block parsing + iterator-shaped `Client.query`
- Insert path with block-buffered builder
- LZ4 + ZSTD compression
- Connection pool
- TLS (separate-port style on 9440)
- DSN constructor

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

## quick start

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
        .client_name = "my-app/v1",
    }, init.io, null, null);
    defer client.close();

    std.debug.print("connected to {s} {d}.{d} (rev {d})\n", .{
        client.server_info.name,
        client.server_info.major_version,
        client.server_info.minor_version,
        client.server_info.revision,
    });

    try client.ping(null);
}
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
