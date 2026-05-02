# clickzig

a fast, native-protocol ClickHouse client for Zig.

## what it is

clickzig speaks the ClickHouse native binary protocol directly from Zig, with zero allocations in hot paths and full support for ClickHouse's complex type system. designed for high-throughput analytics workloads where the standard HTTP interface adds too much overhead.

current version: **v0.15.2**

## why Zig

most ClickHouse clients are written in higher-level languages (Python, Go, Rust) and pay the cost in either runtime overhead or build complexity. Zig sits between C performance and Rust safety, with a build system that doesn't get in the way. clickzig leans into that — small binary, predictable allocation behavior, easy to embed.

## features

- native ClickHouse binary protocol implementation
- zero allocations in hot paths
- support for ClickHouse complex types (Array, Tuple, Map, Nullable, etc.)
- connection pooling
- async query support
- compression (LZ4, ZSTD)
- bulk insert optimization
- streaming for large result sets
- comprehensive error handling

## examples

the repo includes several examples covering different features. each example is buildable as a separate executable:

```bash
zig build run-basic_connection    # basic connection and query
zig build run-bulk_insert         # bulk data insertion
zig build run-streaming           # streaming large result sets
zig build run-compression         # data compression
zig build run-transaction         # transaction handling
zig build run-async_query         # async query execution
zig build run-materialized_view   # materialized view creation
zig build run-dictionary          # dictionary operations
zig build run-distributed_table   # distributed table setup
zig build run-query_profiling     # query profiling
zig build run-mutations           # data mutations
zig build run-sampling            # data sampling
zig build run-complex_types       # complex data types
zig build run-pool_config         # connection pool configuration
zig build run-query_control       # query monitoring and control
```

each example has inline comments explaining the relevant feature.

## status

actively developed. v0.15.2 is the current release. API may shift before v1.0.

## license

see LICENSE file.
