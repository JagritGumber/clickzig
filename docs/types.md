# Type mapping

clickzig uses column-oriented storage. A decoded `Block` contains
`ColumnEntry[]`; each entry has the server column name, the original
ClickHouse type string, and a `clickzig.Column` union payload.

## Ownership

Every decoded `Column` is owned by the allocator passed to `Client.query`.
`Packet.deinit`, `Block.deinit`, and `Column.deinit` free nested allocations.
Most applications pass an arena per query and free it when the stream is done.

## Read mapping

| ClickHouse type | `clickzig.Column` shape | notes |
|---|---|---|
| `UInt8` | `.UInt8: []u8` | native-endian values decoded from little-endian wire bytes |
| `UInt16` | `.UInt16: []u16` |  |
| `UInt32` | `.UInt32: []u32` | also used for `DateTime` and `IPv4` aliases |
| `UInt64` | `.UInt64: []u64` |  |
| `UInt128` | `.UInt128: []u128` |  |
| `UInt256` | `.UInt256: []u256` |  |
| `Int8` | `.Int8: []i8` |  |
| `Int16` | `.Int16: []i16` | also used for `Date` |
| `Int32` | `.Int32: []i32` | also used for `Date32`, `Enum8`, `Enum16`, and some decimals |
| `Int64` | `.Int64: []i64` | also used for `DateTime64` and intervals |
| `Int128` | `.Int128: []i128` | decimal backing storage |
| `Int256` | `.Int256: []i256` | decimal backing storage |
| `Float32` | `.Float32: []f32` |  |
| `Float64` | `.Float64: []f64` |  |
| `String` | `.String: [][]u8` | raw bytes, not UTF-8 validated |
| `FixedString(N)` | `.FixedString` | flat `data`, row width in `width` |
| `UUID` | `.UUID: [][16]u8` | raw UUID bytes |
| `Nullable(T)` | `.Nullable: *Nullable` | `mask[i] != 0` means NULL; values are in `inner` |
| `Array(T)` | `.Array: *Array` | cumulative `offsets`, flattened `inner` |
| `Tuple(...)` | `.Tuple: *Tuple` | one inner `Column` per tuple element |
| `Map(K, V)` | `.Map: *Map` | cumulative offsets plus flattened `keys` and `values` |
| `Nested(...)` | `.Array` of tuple-like values | ClickHouse alias expansion |
| `LowCardinality(T)` | materialized `T` | dictionary/index layer is hidden |
| `LowCardinality(Nullable(T))` | materialized `.Nullable` | dictionary null maps to the nullable mask |
| `JSON` | `.JSON: [][]u8` | raw JSON text in Native JSON string mode |
| `Dynamic` | `.Dynamic: *Dynamic` | preserves type names, row discriminators, and nested columns |
| `Sparse(T)` | materialized dense `T` where supported | sparse offsets/elements are expanded |
| `Point` | `.Tuple` | ClickHouse geo alias |
| `Ring`, `LineString`, `Polygon`, `MultiPolygon` | `.Array` / `.Tuple` composition | ClickHouse geo alias expansion |
| `SimpleAggregateFunction(f, T)` | `T` | decoded as the underlying type |

## Nullable

```zig
switch (column) {
    .Nullable => |n| {
        for (0..n.mask.len) |i| {
            if (n.mask[i] != 0) {
                // NULL
            } else {
                const value = n.inner.UInt64[i];
                _ = value;
            }
        }
    },
    else => {},
}
```

The nullable inner column always has the same row count as the mask.

## Array

`Array.offsets` stores cumulative end offsets. To read row `i`:

```zig
const start: u64 = if (i == 0) 0 else arr.offsets[i - 1];
const end: u64 = arr.offsets[i];
const values = arr.inner.UInt32[start..end];
```

Offsets are validated as monotonic and capped before inner allocation.

## Tuple

Tuple element columns share the parent row count:

```zig
const x = tuple.elements[0].Float64[i];
const y = tuple.elements[1].Float64[i];
```

Named tuple field names are currently preserved in the ClickHouse type string,
not as a separate metadata structure.

## Map

Map is encoded by ClickHouse as `Array(Tuple(K, V))`. clickzig exposes that as:

```zig
const start = if (i == 0) 0 else map.offsets[i - 1];
const end = map.offsets[i];
const keys = map.keys.String[start..end];
const values = map.values.UInt64[start..end];
```

## Dynamic

`Dynamic` stores the concrete types present in the block and a discriminator per
row. The null discriminator is `0xff`.

```zig
for (dynamic.discriminators, 0..) |disc, row| {
    if (disc == 0xff) continue; // NULL
    const type_name = dynamic.type_names[disc];
    const values = dynamic.values[disc];
    _ = .{ row, type_name, values };
}
```

## Insert mapping

INSERT uses `clickzig.block.InsertColumn`:

```zig
const column: clickzig.block.InsertColumn = .{
    .name = "amount",
    .type_name = "Decimal(18, 2)",
    .data = .{ .Int64 = amounts },
};
```

The `type_name` must be the ClickHouse type string declared by the table or
accepted by the INSERT statement. clickzig validates common tag/type mismatches
before writing the block.

## Limits

Read-side defensive caps:

- max rows per column: `10_000_000`
- max bytes in a single String/JSON value: `64 MiB`
- max bytes in one decoded column allocation: `1 GiB`

Compression frame caps are documented in [Security](security.md).
