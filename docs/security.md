# Security and defensive behavior

clickzig is a native protocol client. Most hostile inputs come from the server
or an on-path peer able to send malformed ClickHouse frames. The implementation
uses explicit caps and deterministic audit probes to keep malformed wire data
from becoming unbounded allocation or recursion.

## Threat model

Covered:

- hostile or compromised ClickHouse server
- malformed native protocol frames
- hostile compression headers
- oversized block, column, string, parameter, and custom-serialization counts
- timeout behavior for dial/read/write stalls
- broken-connection handling for pool reuse

Not covered:

- SQL injection in caller-built SQL strings
- misuse of `Parameters.putRaw` with untrusted input
- application-level authorization
- server-side ClickHouse bugs
- TLS disabled by caller choice

## Query parameters

Use native ClickHouse placeholders:

```sql
SELECT {tenant:String}, {limit:UInt64}
```

Values are sent in the protocol's parameter section; they are not interpolated
into SQL text by clickzig.

Parameter hardening:

- names must match `[A-Za-z_][A-Za-z0-9_]*`
- values are length-capped by the same string payload policy used elsewhere
- duplicate names overwrite through explicit map behavior
- empty parameter maps serialize as the protocol sentinel

`putRaw` bypasses helper formatting. Treat it as an advanced API for trusted
ClickHouse literal strings.

## Compression

Supported:

- read: LZ4 and ZSTD frames
- write: LZ4 and ZSTD frames
- checksum validation before decompression
- Data, Totals, and Extremes block-body compression
- Log and ProfileEvents compression only after the ClickHouse revision gate

Caps:

- max compressed frame payload: `1 GiB`
- max decompressed frame size: `1 GiB`

Malformed frames rejected before large allocation include:

- unsupported compression method byte
- checksum mismatch
- `.none` frame size mismatch
- decompressed-size cap breach

## Column and block caps

Read-side caps:

- max block columns: `10_000`
- max rows per column: `10_000_000`
- max single string value: `64 MiB`
- max decoded column allocation: `1 GiB`

Array offsets are checked for monotonicity and capped before reading the inner
column. Sparse, Dynamic, JSON, and LowCardinality custom serialization counts
are also capped before allocation.

## Pool safety

A `Client` becomes broken after protocol or I/O errors. The pool consults
`Client.isReusable()` on release and closes broken clients instead of returning
them to the idle list.

Do not share one `Client` across threads. Use `Pool` or one client per thread.

## Timeouts

Nonzero timeout fields map to public errors:

- `dial_timeout_ms` -> `error.ConnectTimeout`
- `read_timeout_ms` -> `error.ReadTimeout`
- `write_timeout_ms` -> `error.WriteTimeout`

`0` means infinite and is useful for controlled environments only. Production
services should set finite budgets.

## TLS

Use `TlsTransport` with `.system_ca` for production. `.insecure` disables
certificate and hostname verification and is only appropriate for local smoke
tests or explicitly trusted development networks.

## Audit probes

`zig build audit --summary all` runs hostile-frame regression probes. These are
unit-level checks that intentionally avoid creating real decompression bombs or
large allocations. They verify that dangerous lengths and counts are rejected or
observed by capped allocators before the host can be exhausted.

Run the audit suite before merging security-sensitive protocol changes:

```bash
zig build audit --summary all
```
