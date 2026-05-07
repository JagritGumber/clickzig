# Getting started

clickzig is a native-protocol ClickHouse client for Zig 0.16.0. It talks to the
ClickHouse TCP port directly: `9000` for plain TCP and `9440` for TLS.

## Requirements

- Zig 0.16.0
- A ClickHouse server for smoke tests
- Native protocol credentials; the repository smoke tests assume user
  `default`, password `test`, host `127.0.0.1`, and port `9000`

## Add the dependency

During development, depend on the branch that matches your Zig compiler:

```bash
zig fetch --save git+https://github.com/JagritGumber/clickzig#0.16.0
```

Then import the module from your `build.zig`:

```zig
const clickzig_dep = b.dependency("clickzig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("clickzig", clickzig_dep.module("clickzig"));
```

## Connect and query

```zig
const std = @import("std");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const client = try clickzig.Client.connectTcp(.{
        .control_allocator = init.gpa,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 16 * 1024,
        .host = "127.0.0.1",
        .port = 9000,
        .username = "default",
        .password = "test",
    }, init.io, null, null);
    defer client.close();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();

    var stream = try client.query(
        "SELECT number, number * 2 FROM numbers(5)",
        arena.allocator(),
        null,
        .{},
    );

    while (try stream.next()) |packet| switch (packet) {
        .data => |block| {
            const n = block.columns[0].column.UInt64;
            const doubled = block.columns[1].column.UInt64;
            for (0..block.num_rows) |i| {
                std.debug.print("{d} -> {d}\n", .{ n[i], doubled[i] });
            }
        },
        .exception => |e| return std.debug.print("ClickHouse error {d}: {s}\n", .{ e.code, e.message }),
        .end_of_stream => break,
        else => {},
    };
}
```

## Insert data

`Client.insert` writes Native blocks. Callers provide column-oriented buffers
that must match the ClickHouse type names.

```zig
var ids = [_]u32{ 1, 2, 3 };
var labels = [_][]u8{
    @constCast("alpha"),
    @constCast("beta"),
    @constCast("gamma"),
};

const columns = [_]clickzig.block.InsertColumn{
    .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
    .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
};

try client.insert(
    "INSERT INTO events (id, label) FORMAT Native",
    "",
    ids.len,
    &columns,
    arena.allocator(),
    null,
    .{},
);
```

## Native query parameters

Use ClickHouse native placeholders (`{name:Type}`) rather than rewriting SQL
client-side.

```zig
var params: clickzig.Parameters = .{};
defer params.deinit(arena.allocator());

try params.putUInt(arena.allocator(), "n", 41);
try params.putString(arena.allocator(), "label", "clickzig");

var stream = try client.query(
    "SELECT {n:UInt64} + 1, {label:String}",
    arena.allocator(),
    null,
    .{ .parameters = &params },
);
```

`QueryOptions.settings` and `QueryOptions.parameters` are separate sections of
the Query packet. Settings change execution behavior; parameters feed the
server's `{name:Type}` placeholders without text interpolation.

## Compression

Compression is supported and opt-in. Defaults are conservative:

```zig
var cfg: clickzig.Config = .{
    .control_allocator = init.gpa,
    .read_buffer_size = 64 * 1024,
    .write_buffer_size = 16 * 1024,
    .compression = .Enable,
    .compression_method = .zstd, // or .lz4
};
```

You can also enable compression per query or insert:

```zig
try client.insert(sql, "", rows, &columns, arena.allocator(), null, .{
    .compression = .Enable,
    .compression_method = .lz4,
});
```

## Run checks

No ClickHouse server is required for unit tests:

```bash
zig build test --summary all
zig build audit --summary all
zig build examples --summary all
```

With ClickHouse listening on `127.0.0.1:9000` as `default:test`:

```bash
zig build smoke-compression
zig build smoke-readiness
```
