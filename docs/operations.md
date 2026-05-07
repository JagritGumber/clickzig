# Operations

This page covers local ClickHouse setup, smoke scenarios, CI gates, pooling,
TLS, and branch policy.

## Local ClickHouse

The smoke harness expects:

- host: `127.0.0.1`
- native port: `9000`
- user: `default`
- password: `test`

With Docker-compatible tooling:

```bash
docker run --rm --name clickzig-clickhouse \
  -p 9000:9000 -p 8123:8123 \
  -e CLICKHOUSE_PASSWORD=test \
  clickhouse/clickhouse-server:26.3
```

Wait until ClickHouse accepts native connections before running smoke tests.

## Local verification

Run these without ClickHouse:

```bash
zig build test --summary all
zig build audit --summary all
zig build examples --summary all
```

Run these with ClickHouse:

```bash
zig build smoke-compression
zig build smoke-readiness
```

Focused smoke scenario:

```bash
zig build smoke -- parameters
```

## Smoke scenarios

Current scenarios:

- `happy`
- `ping`
- `wrong-pass`
- `unreachable`
- `wrong-host`
- `query-bytes`
- `query-mixed`
- `insert-roundtrip`
- `nullable-roundtrip`
- `complex-types`
- `tuple-map`
- `decimal-ip`
- `column-coverage`
- `pool`
- `pool-loop`
- `dsn`
- `compression`
- `insert-compression`
- `insert-zstd`
- `nested-compressed-insert`
- `lowcardinality`
- `lc-write`
- `timeout`
- `read-timeout`
- `write-timeout`
- `json`
- `dynamic`
- `parameters`
- `geo`
- `external-data`
- `combined-features`

`smoke-readiness` runs the release-confidence subset that exercises pooling,
timeouts, compression, custom types, external data, parameters, and combined
feature interactions.

## CI gate

The expected release-confidence gate is:

```bash
zig build test --summary all
zig build audit --summary all
zig build examples --summary all
zig build smoke-compression
zig build smoke-readiness
```

CI should run the ClickHouse-backed steps against a service container exposing
native port `9000` with user `default` and password `test`.

## Pooling

`Pool` is intended for multi-threaded applications that need more than one
in-flight operation. A single `Client` is not thread-safe.

```zig
const pool = try clickzig.Pool.init(allocator, io, cfg, .{
    .max_size = 16,
    .max_lifetime_ms = 30 * 60 * 1000,
});
defer pool.deinit();

const client = try pool.acquire(null);
defer pool.release(client);
```

Pool behavior:

- `acquire(null)` waits for or creates a reusable connection.
- `release(client)` recycles ready clients and closes broken clients.
- expired clients are retired according to `max_lifetime_ms`.
- callers must not use a client after releasing it.

## Timeouts

Timeouts are configured on `Config` in milliseconds:

```zig
.dial_timeout_ms = 5_000,
.read_timeout_ms = 60_000,
.write_timeout_ms = 30_000,
```

`0` means infinite. Nonzero values map to public errors:

- `error.ConnectTimeout`
- `error.ReadTimeout`
- `error.WriteTimeout`

The built-in `TcpTransport` implements timeout-aware dial/read/write behavior
without relying on Zig 0.16's panicking TCP connect timeout path.

## TLS

ClickHouse TLS uses port `9440`.

Use `TlsTransport` when you need encrypted native protocol traffic:

1. Connect a `TcpTransport` to port `9440`.
2. Wrap it with `TlsTransport.over`.
3. Pass the TLS transport to `Client.fromTransport`.

Use `.system_ca` for production certificate verification. `.insecure` is for
local development and self-signed smoke setups only.

## Branch policy

`main` targets the current stable Zig line for this package, currently Zig
0.16.0. The `0.16.0` branch is the maintained Zig 0.16 line. Future Zig
development snapshots can use a `dev` branch when needed.

Do not create release tags, GitHub Releases, or publish artifacts unless the
maintainer explicitly asks for a publish/release step.
