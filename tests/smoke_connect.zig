//! End-to-end smoke executable for clickzig. Five scenarios:
//!   happy        — connect to localhost:9000 with default:test
//!   wrong-pass   — connect with wrong password; expect AuthenticationFailed
//!   ping         — connect + 100x ping in a loop
//!   unreachable  — connect to a port nothing listens on
//!   wrong-host   — connect to a TEST-NET-1 address that times out
//!
//! Run via: `zig build smoke -- <scenario>`. Requires a local
//! ClickHouse on 127.0.0.1:9000 with `default:test` for happy/ping
//! /wrong-pass scenarios.

const std = @import("std");
const builtin = @import("builtin");
const clickzig = @import("clickzig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const scenario = args.next() orelse "happy";

    if (std.mem.eql(u8, scenario, "happy")) {
        try runHappy(allocator, io);
    } else if (std.mem.eql(u8, scenario, "ping")) {
        try runPing(allocator, io);
    } else if (std.mem.eql(u8, scenario, "wrong-pass")) {
        try runWrongPass(allocator, io);
    } else if (std.mem.eql(u8, scenario, "unreachable")) {
        try runUnreachable(allocator, io);
    } else if (std.mem.eql(u8, scenario, "wrong-host")) {
        try runWrongHost(allocator, io);
    } else if (std.mem.eql(u8, scenario, "query-bytes")) {
        try runQueryBytes(allocator, io);
    } else if (std.mem.eql(u8, scenario, "query-mixed")) {
        try runQueryMixed(allocator, io);
    } else if (std.mem.eql(u8, scenario, "insert-roundtrip")) {
        try runInsertRoundtrip(allocator, io);
    } else if (std.mem.eql(u8, scenario, "nullable-roundtrip")) {
        try runNullableRoundtrip(allocator, io);
    } else if (std.mem.eql(u8, scenario, "complex-types")) {
        try runComplexTypes(allocator, io);
    } else if (std.mem.eql(u8, scenario, "pool")) {
        try runPool(allocator, io);
    } else if (std.mem.eql(u8, scenario, "dsn")) {
        try runDsn(allocator, io);
    } else if (std.mem.eql(u8, scenario, "decimal-ip")) {
        try runDecimalIp(allocator, io);
    } else if (std.mem.eql(u8, scenario, "column-coverage")) {
        try runColumnCoverage(allocator, io);
    } else if (std.mem.eql(u8, scenario, "tuple-map")) {
        try runTupleMap(allocator, io);
    } else if (std.mem.eql(u8, scenario, "compression")) {
        try runCompression(allocator, io);
    } else if (std.mem.eql(u8, scenario, "insert-compression")) {
        try runInsertCompression(allocator, io, .lz4);
    } else if (std.mem.eql(u8, scenario, "insert-zstd")) {
        try runInsertCompression(allocator, io, .zstd);
    } else if (std.mem.eql(u8, scenario, "lowcardinality")) {
        try runLowCardinality(allocator, io);
    } else if (std.mem.eql(u8, scenario, "lc-write")) {
        try runLowCardinalityWrite(allocator, io);
    } else if (std.mem.eql(u8, scenario, "timeout")) {
        try runTimeout(allocator, io);
    } else if (std.mem.eql(u8, scenario, "read-timeout")) {
        try runReadTimeout(allocator, io);
    } else if (std.mem.eql(u8, scenario, "write-timeout")) {
        try runWriteTimeout(allocator, io);
    } else if (std.mem.eql(u8, scenario, "json")) {
        try runJson(allocator, io);
    } else if (std.mem.eql(u8, scenario, "dynamic")) {
        try runDynamic(allocator, io);
    } else if (std.mem.eql(u8, scenario, "parameters")) {
        try runParameters(allocator, io);
    } else if (std.mem.eql(u8, scenario, "geo")) {
        try runGeo(allocator, io);
    } else if (std.mem.eql(u8, scenario, "external-data")) {
        try runExternalData(allocator, io);
    } else if (std.mem.eql(u8, scenario, "combined-features")) {
        try runCombinedFeatures(allocator, io);
    } else if (std.mem.eql(u8, scenario, "nested-compressed-insert")) {
        try runNestedCompressedInsert(allocator, io);
    } else if (std.mem.eql(u8, scenario, "pool-loop")) {
        try runPoolLoop(allocator, io);
    } else {
        std.debug.print("usage: smoke_connect [happy|ping|wrong-pass|unreachable|wrong-host|query-bytes|query-mixed|insert-roundtrip|nullable-roundtrip|complex-types|pool|dsn|decimal-ip|column-coverage|tuple-map|compression|insert-compression|insert-zstd|lowcardinality|lc-write|timeout|read-timeout|write-timeout|json|dynamic|parameters|geo|external-data|combined-features|nested-compressed-insert|pool-loop]\n", .{});
        return error.UnknownScenario;
    }
}

fn drainNoException(stream: *clickzig.ResultStream, label: []const u8) !void {
    while (try stream.next()) |p| switch (p) {
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[{s}] exception: {s}\n", .{ label, e.message });
            return error.QueryFailed;
        },
        else => {},
    };
}

fn runExternalData(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var xs = [_]u64{ 1, 2, 3 };
    var labels = [_][]u8{ @constCast("skip"), @constCast("keep"), @constCast("keep") };
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "x", .type_name = "UInt64", .data = .{ .UInt64 = &xs } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
    };
    const external = [_]clickzig.ExternalTable{
        .{ .name = "ext_data", .num_rows = 3, .columns = &cols },
    };

    var stream = try client.query(
        "SELECT sum(x) AS total, count() AS n FROM ext_data WHERE label = 'keep'",
        arena.allocator(),
        null,
        .{ .external_tables = &external },
    );
    var seen = false;
    while (try stream.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            if (b.columns[0].column.UInt64[0] != 5) return error.ExternalDataMismatch;
            if (b.columns[1].column.UInt64[0] != 2) return error.ExternalDataMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[external-data] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;
    std.debug.print("[external-data] OK\n", .{});
}

fn runCombinedFeatures(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.compression = .Enable;
    const client = try clickzig.Client.connectTcp(cfg, io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var params: clickzig.Parameters = .{};
    defer params.deinit(arena.allocator());
    try params.putUInt(arena.allocator(), "min_x", @as(u64, 1));
    try params.putString(arena.allocator(), "wanted", "keep");

    var settings: clickzig.settings.Map = .empty;
    defer settings.deinit(arena.allocator());
    try settings.put(arena.allocator(), "max_threads", "1");

    var xs = [_]u64{ 1, 2, 3, 4 };
    var labels = [_][]u8{ @constCast("skip"), @constCast("keep"), @constCast("keep"), @constCast("skip") };
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "x", .type_name = "UInt64", .data = .{ .UInt64 = &xs } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
    };
    const external = [_]clickzig.ExternalTable{
        .{ .name = "combo_ext", .num_rows = 4, .columns = &cols },
    };

    var stream = try client.query(
        "SELECT sum(x) AS total, count() AS n FROM combo_ext WHERE x > {min_x:UInt64} AND label = {wanted:String}",
        arena.allocator(),
        null,
        .{ .compression = .Enable, .settings = &settings, .parameters = &params, .external_tables = &external },
    );
    var seen = false;
    while (try stream.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            if (b.columns[0].column.UInt64[0] != 5) return error.CombinedFeatureMismatch;
            if (b.columns[1].column.UInt64[0] != 2) return error.CombinedFeatureMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[combined-features] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;
    std.debug.print("[combined-features] OK\n", .{});
}

fn runGeo(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var stream = try client.query(
        \\SELECT
        \\    CAST((1.25, 2.5), 'Point') AS p,
        \\    CAST([(0., 0.), (1., 0.), (1., 1.)], 'Ring') AS r,
        \\    CAST([(0., 0.), (2., 2.)], 'LineString') AS line,
        \\    CAST([[(0., 0.), (2., 2.)], [(3., 3.), (4., 4.)]], 'MultiLineString') AS multiline,
        \\    CAST([[(0., 0.), (1., 0.), (1., 1.)]], 'Polygon') AS poly,
        \\    CAST([[[(0., 0.), (1., 0.), (1., 1.)]]], 'MultiPolygon') AS multipoly
    , arena.allocator(), null, .{});
    var seen = false;
    while (try stream.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            const point = b.columns[0].column.Tuple;
            if (point.elements[0].Float64[0] != 1.25 or point.elements[1].Float64[0] != 2.5) return error.GeoMismatch;

            const ring = b.columns[1].column.Array;
            if (ring.offsets[0] != 3) return error.GeoMismatch;
            if (ring.inner.Tuple.elements[0].Float64[2] != 1.0) return error.GeoMismatch;
            if (ring.inner.Tuple.elements[1].Float64[2] != 1.0) return error.GeoMismatch;

            const line = b.columns[2].column.Array;
            if (line.offsets[0] != 2) return error.GeoMismatch;
            if (line.inner.Tuple.elements[0].Float64[1] != 2.0) return error.GeoMismatch;

            const multiline = b.columns[3].column.Array;
            if (multiline.offsets[0] != 2) return error.GeoMismatch;
            if (multiline.inner.Array.offsets[0] != 2) return error.GeoMismatch;
            if (multiline.inner.Array.offsets[1] != 4) return error.GeoMismatch;

            const poly = b.columns[4].column.Array;
            if (poly.offsets[0] != 1) return error.GeoMismatch;
            if (poly.inner.Array.offsets[0] != 3) return error.GeoMismatch;

            const multipoly = b.columns[5].column.Array;
            if (multipoly.offsets[0] != 1) return error.GeoMismatch;
            if (multipoly.inner.Array.offsets[0] != 1) return error.GeoMismatch;
            if (multipoly.inner.Array.inner.Array.offsets[0] != 3) return error.GeoMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[geo] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;

    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_geo", arena.allocator(), null, .{});
        try drainNoException(&s, "geo-drop");
    }
    {
        var s = try client.query(
            \\CREATE TABLE smoke_geo (
            \\    p Point,
            \\    r Ring,
            \\    line LineString,
            \\    multiline MultiLineString,
            \\    poly Polygon,
            \\    multipoly MultiPolygon
            \\) ENGINE = Memory
        , arena.allocator(), null, .{});
        try drainNoException(&s, "geo-create");
    }

    var p_x = [_]f64{9.0};
    var p_y = [_]f64{10.0};
    var p_elements = [_]clickzig.Column{ .{ .Float64 = &p_x }, .{ .Float64 = &p_y } };
    var point_box: clickzig.column.Tuple = .{ .row_count = 1, .elements = &p_elements };

    var r_x = [_]f64{ 0.0, 1.0, 1.0 };
    var r_y = [_]f64{ 0.0, 0.0, 1.0 };
    var r_elements = [_]clickzig.Column{ .{ .Float64 = &r_x }, .{ .Float64 = &r_y } };
    var r_tuple: clickzig.column.Tuple = .{ .row_count = 3, .elements = &r_elements };
    var r_offsets = [_]u64{3};
    var ring_box: clickzig.column.Array = .{ .offsets = &r_offsets, .inner = .{ .Tuple = &r_tuple } };

    var line_x = [_]f64{ 0.0, 2.0 };
    var line_y = [_]f64{ 0.0, 2.0 };
    var line_elements = [_]clickzig.Column{ .{ .Float64 = &line_x }, .{ .Float64 = &line_y } };
    var line_tuple: clickzig.column.Tuple = .{ .row_count = 2, .elements = &line_elements };
    var line_offsets = [_]u64{2};
    var line_box: clickzig.column.Array = .{ .offsets = &line_offsets, .inner = .{ .Tuple = &line_tuple } };

    var ml_x = [_]f64{ 0.0, 2.0, 3.0, 4.0 };
    var ml_y = [_]f64{ 0.0, 2.0, 3.0, 4.0 };
    var ml_elements = [_]clickzig.Column{ .{ .Float64 = &ml_x }, .{ .Float64 = &ml_y } };
    var ml_tuple: clickzig.column.Tuple = .{ .row_count = 4, .elements = &ml_elements };
    var ml_line_offsets = [_]u64{ 2, 4 };
    var ml_lines_box: clickzig.column.Array = .{ .offsets = &ml_line_offsets, .inner = .{ .Tuple = &ml_tuple } };
    var ml_offsets = [_]u64{2};
    var multiline_box: clickzig.column.Array = .{ .offsets = &ml_offsets, .inner = .{ .Array = &ml_lines_box } };

    var poly_x = [_]f64{ 0.0, 1.0, 1.0 };
    var poly_y = [_]f64{ 0.0, 0.0, 1.0 };
    var poly_elements = [_]clickzig.Column{ .{ .Float64 = &poly_x }, .{ .Float64 = &poly_y } };
    var poly_tuple: clickzig.column.Tuple = .{ .row_count = 3, .elements = &poly_elements };
    var poly_ring_offsets = [_]u64{3};
    var poly_ring_box: clickzig.column.Array = .{ .offsets = &poly_ring_offsets, .inner = .{ .Tuple = &poly_tuple } };
    var poly_offsets = [_]u64{1};
    var poly_box: clickzig.column.Array = .{ .offsets = &poly_offsets, .inner = .{ .Array = &poly_ring_box } };

    var mp_x = [_]f64{ 0.0, 1.0, 1.0 };
    var mp_y = [_]f64{ 0.0, 0.0, 1.0 };
    var mp_elements = [_]clickzig.Column{ .{ .Float64 = &mp_x }, .{ .Float64 = &mp_y } };
    var mp_tuple: clickzig.column.Tuple = .{ .row_count = 3, .elements = &mp_elements };
    var mp_ring_offsets = [_]u64{3};
    var mp_ring_box: clickzig.column.Array = .{ .offsets = &mp_ring_offsets, .inner = .{ .Tuple = &mp_tuple } };
    var mp_poly_offsets = [_]u64{1};
    var mp_poly_box: clickzig.column.Array = .{ .offsets = &mp_poly_offsets, .inner = .{ .Array = &mp_ring_box } };
    var mp_offsets = [_]u64{1};
    var multipoly_box: clickzig.column.Array = .{ .offsets = &mp_offsets, .inner = .{ .Array = &mp_poly_box } };

    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "p", .type_name = "Point", .data = .{ .Tuple = &point_box } },
        .{ .name = "r", .type_name = "Ring", .data = .{ .Array = &ring_box } },
        .{ .name = "line", .type_name = "LineString", .data = .{ .Array = &line_box } },
        .{ .name = "multiline", .type_name = "MultiLineString", .data = .{ .Array = &multiline_box } },
        .{ .name = "poly", .type_name = "Polygon", .data = .{ .Array = &poly_box } },
        .{ .name = "multipoly", .type_name = "MultiPolygon", .data = .{ .Array = &multipoly_box } },
    };
    try client.insert("INSERT INTO smoke_geo (p, r, line, multiline, poly, multipoly) FORMAT Native", "", 1, &cols, arena.allocator(), null, .{});

    var back = try client.query("SELECT p, r, line, multiline, poly, multipoly FROM smoke_geo", arena.allocator(), null, .{});
    var roundtrip_seen = false;
    while (try back.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            roundtrip_seen = true;
            if (b.columns[0].column.Tuple.elements[0].Float64[0] != 9.0) return error.GeoMismatch;
            if (b.columns[1].column.Array.offsets[0] != 3) return error.GeoMismatch;
            if (b.columns[2].column.Array.offsets[0] != 2) return error.GeoMismatch;
            if (b.columns[3].column.Array.inner.Array.offsets[1] != 4) return error.GeoMismatch;
            if (b.columns[4].column.Array.inner.Array.offsets[0] != 3) return error.GeoMismatch;
            if (b.columns[5].column.Array.inner.Array.inner.Array.offsets[0] != 3) return error.GeoMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[geo] roundtrip exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!roundtrip_seen) return error.UnexpectedRowCount;
    std.debug.print("[geo] OK\n", .{});
}

fn runParameters(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var params: clickzig.Parameters = .{};
    defer params.deinit(arena.allocator());
    try params.putUInt(arena.allocator(), "n", @as(u64, 41));
    try params.putString(arena.allocator(), "s", "clickzig");
    try params.putDate(arena.allocator(), "d", "2026-05-07");

    var stream = try client.query(
        "SELECT {n:UInt64} + 1 AS answer, {s:String} AS label, toDate({d:String}) AS day",
        arena.allocator(),
        null,
        .{ .parameters = &params },
    );
    var seen = false;
    while (try stream.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            if (b.columns[0].column.UInt64[0] != 42) return error.ParameterMismatch;
            if (!std.mem.eql(u8, b.columns[1].column.String[0], "clickzig")) return error.ParameterMismatch;
            if (b.columns[2].column.UInt16[0] == 0) return error.ParameterMismatch;
        },
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[parameters] exception: {s}\n", .{e.message});
            return error.QueryFailed;
        },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;
    std.debug.print("[parameters] OK\n", .{});
}

fn customTypeSettings(allocator: std.mem.Allocator) !clickzig.settings.Map {
    var settings: clickzig.settings.Map = .empty;
    try settings.put(allocator, "allow_experimental_json_type", "1");
    try settings.put(allocator, "allow_experimental_dynamic_type", "1");
    try settings.put(allocator, "output_format_native_write_json_as_string", "1");
    try settings.put(allocator, "output_format_native_use_flattened_dynamic_and_json_serialization", "1");
    return settings;
}

fn runJson(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var settings = try customTypeSettings(arena.allocator());
    var s = try client.query("SELECT toJSONString(CAST('{\"a\":1}' AS JSON)) AS j", arena.allocator(), null, .{ .settings = &settings });
    var seen = false;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            switch (b.columns[0].column) {
                .JSON => |rows| if (!std.mem.eql(u8, rows[0], "{\"a\":1}")) {
                    std.debug.print("[json] got '{s}'\n", .{rows[0]});
                    return error.JsonMismatch;
                },
                .String => |rows| if (!std.mem.eql(u8, rows[0], "{\"a\":1}")) {
                    std.debug.print("[json] got '{s}'\n", .{rows[0]});
                    return error.JsonMismatch;
                },
                else => return error.JsonMismatch,
            }
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[json] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;
    std.debug.print("[json] OK\n", .{});
}

fn runDynamic(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var settings = try customTypeSettings(arena.allocator());
    var s = try client.query("SELECT toString(CAST(number AS Dynamic)) AS d FROM numbers(2)", arena.allocator(), null, .{ .settings = &settings });
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            rows += b.num_rows;
            if (b.num_rows == 0) continue;
            if (b.columns[0].column.len() != b.num_rows) return error.DynamicMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[dynamic] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[dynamic] OK\n", .{});
}

fn runTimeout(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    if (builtin.os.tag == .windows) {
        // Zig 0.16's Windows threaded backend prints an internal
        // ACCESS_DENIED trace when a pending AFD connect is canceled.
        // Keep the Windows smoke quiet; Linux CI exercises the real
        // timeout path against TEST-NET-1 below.
        cfg.host = "127.0.0.1";
        cfg.port = 1;
    } else {
        cfg.host = "192.0.2.1";
    }
    cfg.dial_timeout_ms = 50;
    const started = std.Io.Clock.now(.awake, io);
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |c| {
        c.close();
        return error.UnexpectedSuccess;
    } else |e| {
        const elapsed_ms = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();
        if (e != error.ConnectTimeout and e != error.HostUnreachable and e != error.ConnectionFailed and e != error.ConnectionRefused) return e;
        if (elapsed_ms > 5_000) return error.TimeoutBudgetIgnored;
        std.debug.print("[timeout] OK: {s} after {d}ms\n", .{ @errorName(e), elapsed_ms });
    }
}

fn runReadTimeout(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    cfg.host = "127.0.0.1";
    cfg.port = server.socket.address.getPort();
    cfg.read_timeout_ms = 50;

    const started = std.Io.Clock.now(.awake, io);
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |client| {
        client.close();
        return error.UnexpectedSuccess;
    } else |e| {
        const elapsed_ms = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();
        if (e != error.ReadTimeout) return e;
        if (elapsed_ms > 5_000) return error.TimeoutBudgetIgnored;
        std.debug.print("[read-timeout] OK after {d}ms\n", .{elapsed_ms});
    }
}

fn runWriteTimeout(allocator: std.mem.Allocator, io: std.Io) !void {
    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const tcp = try clickzig.TcpTransport.connect(allocator, io, "127.0.0.1", server.socket.address.getPort(), .{
        .read_buffer_size = 4096,
        .write_buffer_size = 4096,
        .dial_timeout_ms = 1000,
    });
    defer {
        tcp.deinit();
        allocator.destroy(tcp);
    }
    try tcp.transport().setWriteTimeout(50);

    var chunk: [1024 * 1024]u8 = undefined;
    @memset(&chunk, 0xA5);
    const started = std.Io.Clock.now(.awake, io);
    var wrote: usize = 0;
    while (wrote < 1024) : (wrote += 1) {
        tcp.transport().writer().writeAll(&chunk) catch |e| {
            const elapsed_ms = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();
            if (e != error.WriteFailed) return e;
            const last = tcp.transport().lastWriteError() orelse return error.UnexpectedTimeoutError;
            if (last != error.Timeout) return last;
            if (elapsed_ms > 5_000) return error.TimeoutBudgetIgnored;
            std.debug.print("[write-timeout] OK after {d}ms ({d} MiB attempted)\n", .{ elapsed_ms, wrote + 1 });
            return;
        };
        tcp.transport().writer().flush() catch |e| {
            const elapsed_ms = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();
            if (e != error.WriteFailed) return e;
            const last = tcp.transport().lastWriteError() orelse return error.UnexpectedTimeoutError;
            if (last != error.Timeout) return last;
            if (elapsed_ms > 5_000) return error.TimeoutBudgetIgnored;
            std.debug.print("[write-timeout] OK after {d}ms ({d} MiB attempted)\n", .{ elapsed_ms, wrote + 1 });
            return;
        };
    }
    return error.UnexpectedSuccess;
}

fn runLowCardinalityWrite(allocator: std.mem.Allocator, io: std.Io) !void {
    // CREATE a Memory-engine table with LC(String) and LC(Nullable(UInt32)),
    // INSERT through the client (which now encodes LC frames), SELECT
    // back, and verify exact match. Round-trips both the read AND write
    // sides of the LC implementation against a real server.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_lc_w", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[lc-write] drop failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }
    {
        // ClickHouse rejects LowCardinality of numerics by default
        // (allow_suspicious_low_cardinality_types). Use the canonical
        // LC(String) and LC(Nullable(String)) shapes, which are the
        // primary real-world use case anyway. Numeric LC encoding is
        // covered by the unit tests in column.zig.
        var s = try client.query(
            \\CREATE TABLE smoke_lc_w (
            \\    k UInt32,
            \\    label LowCardinality(String),
            \\    note LowCardinality(Nullable(String))
            \\) ENGINE = Memory
        , arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[lc-write] create failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }

    var ks = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var labels = [_][]u8{
        @constCast("hot"), @constCast("cold"), @constCast("hot"),
        @constCast("cold"), @constCast("hot"), @constCast("hot"),
    };
    var note_mask = [_]u8{ 0, 1, 0, 0, 1, 0 };
    var note_values = [_][]u8{
        @constCast("primary"),
        @constCast(""),
        @constCast("backup"),
        @constCast("primary"),
        @constCast(""),
        @constCast("backup"),
    };
    var note_nullable: clickzig.column.Nullable = .{
        .mask = &note_mask,
        .inner = .{ .String = &note_values },
    };
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "k", .type_name = "UInt32", .data = .{ .UInt32 = &ks } },
        .{ .name = "label", .type_name = "LowCardinality(String)", .data = .{ .String = &labels } },
        .{
            .name = "note",
            .type_name = "LowCardinality(Nullable(String))",
            .data = .{ .Nullable = &note_nullable },
        },
    };
    try client.insert(
        "INSERT INTO smoke_lc_w (k, label, note) FORMAT Native",
        "",
        6,
        &cols,
        arena.allocator(),
        null,
        .{ .query_id = "smoke-lc-write" },
    );
    std.debug.print("[lc-write] inserted 6 rows via LC encoder\n", .{});

    var s = try client.query("SELECT k, label, note FROM smoke_lc_w ORDER BY k", arena.allocator(), null, .{});
    var seen: u32 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ks_back = b.columns[0].column.UInt32;
            const labels_back = b.columns[1].column.String;
            const notes_back = b.columns[2].column.Nullable;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                if (ks_back[i] != ks[seen + i]) return error.LcWriteMismatch;
                if (!std.mem.eql(u8, labels_back[i], labels[seen + i])) return error.LcWriteMismatch;
                if (notes_back.mask[i] != note_mask[seen + i]) return error.LcWriteMismatch;
                if (note_mask[seen + i] == 0) {
                    if (!std.mem.eql(u8, notes_back.inner.String[i], note_values[seen + i])) {
                        return error.LcWriteMismatch;
                    }
                }
            }
            seen += @intCast(b.num_rows);
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[lc-write] select failed: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (seen != 6) return error.UnexpectedRowCount;
    std.debug.print("[lc-write] OK: 6 rows round-tripped through LC write encoder\n", .{});
}

fn runLowCardinality(allocator: std.mem.Allocator, io: std.Io) !void {
    // CREATE a table with both LowCardinality(String) and
    // LowCardinality(Nullable(String)), populate via server-side
    // INSERT...SELECT (we don't ship client-side LC encoding yet),
    // then SELECT and verify the materialized data matches the
    // pattern we generated server-side.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_lc", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[lc] drop failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }
    {
        var s = try client.query(
            \\CREATE TABLE smoke_lc (
            \\    k UInt32,
            \\    v LowCardinality(String),
            \\    m LowCardinality(Nullable(String))
            \\) ENGINE = Memory
        , arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[lc] create failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }
    {
        var s = try client.query(
            \\INSERT INTO smoke_lc
            \\SELECT
            \\    number AS k,
            \\    ['alpha', 'beta', 'gamma'][(number % 3) + 1] AS v,
            \\    if(number % 4 = 0, NULL, ['x', 'y', 'z'][(number % 3) + 1]) AS m
            \\FROM numbers(20)
        , arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[lc] insert-select failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }

    var s = try client.query("SELECT k, v, m FROM smoke_lc ORDER BY k", arena.allocator(), null, .{});
    var seen: u32 = 0;
    var nulls: u32 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ks = b.columns[0].column.UInt32;
            const vs = b.columns[1].column.String;
            const ms = b.columns[2].column.Nullable;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                const k = ks[i];
                const expected_v = ([_][]const u8{ "alpha", "beta", "gamma" })[k % 3];
                if (!std.mem.eql(u8, vs[i], expected_v)) {
                    std.debug.print("[lc] v mismatch at k={d}: got '{s}' want '{s}'\n", .{ k, vs[i], expected_v });
                    return error.LcValueMismatch;
                }
                if (k % 4 == 0) {
                    if (ms.mask[i] != 1) return error.LcNullableMismatch;
                    nulls += 1;
                } else {
                    if (ms.mask[i] != 0) return error.LcNullableMismatch;
                    const expected_m = ([_][]const u8{ "x", "y", "z" })[k % 3];
                    if (!std.mem.eql(u8, ms.inner.String[i], expected_m)) return error.LcValueMismatch;
                }
            }
            seen += @intCast(b.num_rows);
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[lc] select failed: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (seen != 20) return error.UnexpectedRowCount;
    if (nulls != 5) return error.UnexpectedNullCount; // k = 0, 4, 8, 12, 16
    std.debug.print("[lc] OK: 20 rows, 5 nulls via LowCardinality(Nullable(String)) sentinel\n", .{});
}

fn runCompression(allocator: std.mem.Allocator, io: std.Io) !void {
    // Connect with compression enabled. Server should send Data blocks
    // wrapped in LZ4 compression frames; we decompress and parse.
    var cfg = baseConfig(allocator);
    cfg.compression = .Enable;
    const client = try clickzig.Client.connectTcp(cfg, io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        "SELECT number FROM numbers(100)",
        arena.allocator(),
        null,
        .{ .compression = .Enable },
    );
    var rows: u64 = 0;
    var sum: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            for (b.columns[0].column.UInt64) |n| {
                sum += n;
                rows += 1;
            }
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[compression] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 100) return error.UnexpectedRowCount;
    if (sum != 4950) return error.SumMismatch;
    std.debug.print("[compression] OK: 100 rows summed to {d} via LZ4 frames\n", .{sum});
}

fn runTupleMap(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var s = try client.query(
        \\SELECT
        \\    (number, toString(number * 10)) AS pair,
        \\    map('a', toInt64(1), 'b', toInt64(number)) AS m
        \\FROM numbers(2)
    , arena.allocator(), null, .{});
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const tup = b.columns[0].column.Tuple;
            const mp = b.columns[1].column.Map;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                const n = tup.elements[0].UInt64[i];
                const s_val = tup.elements[1].String[i];
                std.debug.print("[tuple-map] pair=({d}, {s})\n", .{ n, s_val });
                const start: usize = if (i == 0) 0 else @intCast(mp.offsets[i - 1]);
                const end: usize = @intCast(mp.offsets[i]);
                var j: usize = start;
                while (j < end) : (j += 1) {
                    std.debug.print("[tuple-map]   m[{s}]={d}\n", .{ mp.keys.String[j], mp.values.Int64[j] });
                }
            }
            rows += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[tuple-map] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[tuple-map] OK\n", .{});
}

fn runDecimalIp(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var s = try client.query(
        \\SELECT
        \\    toDecimal64(123.45, 2) AS price,
        \\    toIPv4('192.168.1.1') AS v4,
        \\    toIPv6('2001:db8::1') AS v6,
        \\    toUInt128(toUInt64(0xFFFF) * toUInt64(0x10001)) AS big
    , arena.allocator(), null, .{});
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            // Decimal64(2): scaled int64; 12345 / 100 = 123.45
            const price_raw = b.columns[0].column.Int64[0];
            const v4 = b.columns[1].column.UInt32[0];
            const v6_bytes = b.columns[2].column.FixedString.data[0..16];
            const big = b.columns[3].column.UInt128[0];
            std.debug.print("[decimal-ip] price_raw={d} (= {d}.{d:0>2})\n", .{ price_raw, @divTrunc(price_raw, 100), @rem(price_raw, 100) });
            std.debug.print("[decimal-ip] v4=0x{X:0>8} v6_first={X:0>2}{X:0>2} big={X}\n", .{ v4, v6_bytes[0], v6_bytes[1], big });
            if (price_raw != 12345) return error.DecimalMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[decimal-ip] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    std.debug.print("[decimal-ip] OK\n", .{});
}

fn runColumnCoverage(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        \\SELECT
        \\    toDateTime64('1960-01-01 00:00:00', 3, 'UTC') AS dt64,
        \\    CAST(42, 'SimpleAggregateFunction(sum, UInt64)') AS saf,
        \\    CAST([(1, 'a'), (2, 'b')], 'Nested(id UInt32, name String)') AS nested_col,
        \\    toIntervalDay(3) AS interval_day
    , arena.allocator(), null, .{});
    var seen = false;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            seen = true;
            const dt64 = b.columns[0].column.Int64[0];
            const saf = b.columns[1].column.UInt64[0];
            const nested = b.columns[2].column.Array;
            const interval_day = b.columns[3].column.Int64[0];

            if (dt64 != -315619200000) return error.DateTime64Mismatch;
            if (saf != 42) return error.SimpleAggregateMismatch;
            if (nested.offsets[0] != 2) return error.NestedMismatch;
            if (nested.inner.Tuple.elements[0].UInt32[1] != 2) return error.NestedMismatch;
            if (!std.mem.eql(u8, nested.inner.Tuple.elements[1].String[1], "b")) return error.NestedMismatch;
            if (interval_day != 3) return error.IntervalMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[column-coverage] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (!seen) return error.UnexpectedRowCount;
    std.debug.print("[column-coverage] OK\n", .{});
}

fn runDsn(allocator: std.mem.Allocator, io: std.Io) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const result = try clickzig.fromUri(
        "clickhouse://default:test@127.0.0.1:9000/default?client_name=smoke-dsn",
        arena.allocator(),
        .{
            .control_allocator = allocator,
            .read_buffer_size = 64 * 1024,
            .write_buffer_size = 4 * 1024,
        },
    );
    const client = try clickzig.Client.connectTcp(result.config, io, null, null);
    defer client.close();
    try client.ping(null);
    std.debug.print("[dsn] connected via DSN; client_name={s}\n", .{result.config.client_name.?});
    std.debug.print("[dsn] OK\n", .{});
}

fn runPool(allocator: std.mem.Allocator, io: std.Io) !void {
    const pool = try clickzig.Pool.init(allocator, io, baseConfig(allocator), .{ .max_size = 4 });
    defer pool.deinit();

    // Acquire 3 distinct clients in parallel-ish (no real threads needed
    // for the smoke; just sequential acquire+ping+release with a peek
    // at live_count to confirm pool bookkeeping).
    const c1 = try pool.acquire(null);
    try c1.ping(null);
    const c2 = try pool.acquire(null);
    try c2.ping(null);
    std.debug.print("[pool] live={d} idle={d} after 2 acquires\n", .{ pool.liveCount(), pool.idleCount() });
    pool.release(c1);
    pool.release(c2);
    std.debug.print("[pool] live={d} idle={d} after release\n", .{ pool.liveCount(), pool.idleCount() });

    // Re-acquire — should hit the idle slot, no new dial.
    const c3 = try pool.acquire(null);
    try c3.ping(null);
    pool.release(c3);
    std.debug.print("[pool] live={d} idle={d} after re-acquire+release (should be 2/2)\n", .{ pool.liveCount(), pool.idleCount() });
    if (pool.liveCount() != 2) return error.PoolBookkeepingMismatch;
    std.debug.print("[pool] OK\n", .{});
}

fn runPoolLoop(allocator: std.mem.Allocator, io: std.Io) !void {
    const pool = try clickzig.Pool.init(allocator, io, baseConfig(allocator), .{ .max_size = 2 });
    defer pool.deinit();

    var total: u64 = 0;
    var iter: u64 = 0;
    while (iter < 12) : (iter += 1) {
        const client = try pool.acquire(null);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();

        var params: clickzig.Parameters = .{};
        defer params.deinit(arena.allocator());
        try params.putUInt(arena.allocator(), "n", iter);
        var stream = try client.query(
            "SELECT {n:UInt64} + 1",
            arena.allocator(),
            null,
            .{ .parameters = &params },
        );
        while (try stream.next()) |p| switch (p) {
            .data => |b| {
                if (b.num_rows != 0) total += b.columns[0].column.UInt64[0];
            },
            .end_of_stream => break,
            .exception => |e| {
                pool.release(client);
                std.debug.print("[pool-loop] exception: {s}\n", .{e.message});
                return error.QueryFailed;
            },
            else => {},
        };
        pool.release(client);
    }
    if (total != 78) return error.PoolLoopMismatch;
    if (pool.liveCount() > 2 or pool.idleCount() > 2) return error.PoolBookkeepingMismatch;
    std.debug.print("[pool-loop] OK total={d} live={d} idle={d}\n", .{ total, pool.liveCount(), pool.idleCount() });
}

fn runComplexTypes(allocator: std.mem.Allocator, io: std.Io) !void {
    // Hit Array, FixedString, and UUID in one query against the server.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        \\SELECT
        \\    [number, number * 2, number * 3] AS arr,
        \\    toFixedString(toString(number), 4) AS fs,
        \\    generateUUIDv4() AS id
        \\FROM numbers(2)
    , arena.allocator(), null, .{});
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const arr = b.columns[0].column.Array;
            const fs = b.columns[1].column.FixedString;
            const ids = b.columns[2].column.UUID;
            std.debug.print("[complex] arr type={s}, fs.width={d}\n", .{ b.columns[0].type_name, fs.width });
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                const start: usize = if (i == 0) 0 else @intCast(arr.offsets[i - 1]);
                const end: usize = @intCast(arr.offsets[i]);
                const row_arr = arr.inner.UInt64[start..end];
                const fs_row = fs.data[i * fs.width .. (i + 1) * fs.width];
                std.debug.print("[complex] row {d}: arr={any} fs='{s}' uuid_first_byte=0x{X:0>2}\n", .{ i, row_arr, fs_row, ids[i][0] });
                if (row_arr.len != 3) return error.ArrayShapeMismatch;
                if (row_arr[0] != i) return error.ArrayValueMismatch;
                if (row_arr[1] != i * 2) return error.ArrayValueMismatch;
                if (row_arr[2] != i * 3) return error.ArrayValueMismatch;
            }
            rows += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[complex] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[complex] OK: 2 rows of (Array(UInt64), FixedString(4), UUID)\n", .{});
}

fn runNullableRoundtrip(allocator: std.mem.Allocator, io: std.Io) !void {
    // Read a server-generated Nullable column and verify the mask comes
    // through. Bypasses INSERT to keep the test scope focused on read.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var s = try client.query(
        \\SELECT
        \\    number AS n,
        \\    if(number % 2 = 0, NULL, toUInt32(number * 10)) AS maybe_n
        \\FROM numbers(5)
    , arena.allocator(), null, .{});
    var rows_seen: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ns = b.columns[0].column.UInt64;
            const nullable = b.columns[1].column.Nullable;
            const maybe = nullable.inner.UInt32;
            std.debug.print("[nullable] type={s}\n", .{b.columns[1].type_name});
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                if (nullable.mask[i] != 0) {
                    std.debug.print("[nullable] row n={d}: maybe_n=NULL\n", .{ns[i]});
                    if (ns[i] % 2 != 0) return error.NullMaskMismatch;
                } else {
                    std.debug.print("[nullable] row n={d}: maybe_n={d}\n", .{ ns[i], maybe[i] });
                    if (ns[i] % 2 == 0) return error.NullMaskMismatch;
                    if (maybe[i] != ns[i] * 10) return error.ValueMismatch;
                }
            }
            rows_seen += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[nullable] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows_seen != 5) return error.UnexpectedRowCount;
    std.debug.print("[nullable] OK: 5 rows with mixed null/non-null\n", .{});
}

fn runInsertCompression(allocator: std.mem.Allocator, io: std.Io, method: clickzig.compression.WriteMethod) !void {
    // Identical to runInsertRoundtrip but with compression enabled
    // end-to-end: Hello negotiates compression via per-query flag,
    // INSERT data block + terminator ride wrapped LZ4 frames, server's
    // schema-block schema response and post-write drain are read back
    // through the compressed path. 100 rows is the smallest size that
    // reliably exercises the compressed read path with a non-trivial
    // body, surfaces a Progress packet during drain, and gives the
    // assertion teeth.
    var cfg = baseConfig(allocator);
    cfg.compression = .Enable;
    cfg.compression_method = method;
    const client = try clickzig.Client.connectTcp(cfg, io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    // Belt-and-suspenders: client default is Enable AND every per-query
    // opts.compression is Enable. Either gate alone would flip
    // effective_compression to .Enable; setting both makes the smoke's
    // intent obvious and surfaces a regression if either gate stops
    // working independently.
    const compressed_opts: clickzig.query.QueryOptions = .{ .compression = .Enable, .compression_method = method };
    const label = if (method == .zstd) "insert-zstd" else "insert-compression";
    const method_label = if (method == .zstd) "ZSTD" else "LZ4";
    const table_name = if (method == .zstd) "smoke_insert_zstd" else "smoke_insert_compression";

    {
        const sql = try std.fmt.allocPrint(arena.allocator(), "DROP TABLE IF EXISTS {s}", .{table_name});
        var s = try client.query(sql, arena.allocator(), null, compressed_opts);
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[{s}] drop failed: {s}\n", .{ label, e.message }); return error.SetupFailed; },
            else => {},
        };
    }
    {
        const sql = try std.fmt.allocPrint(arena.allocator(), "CREATE TABLE {s} (id UInt32, label String) ENGINE = Memory", .{table_name});
        var s = try client.query(sql, arena.allocator(), null, compressed_opts);
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[{s}] create failed: {s}\n", .{ label, e.message }); return error.SetupFailed; },
            else => {},
        };
    }

    var ids: [100]u32 = undefined;
    var labels_storage: [100][16]u8 = undefined;
    var labels: [100][]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        ids[i] = @intCast(i);
        labels[i] = std.fmt.bufPrint(&labels_storage[i], "row-{d}", .{i}) catch unreachable;
    }
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
    };
    const insert_sql = try std.fmt.allocPrint(arena.allocator(), "INSERT INTO {s} (id, label) FORMAT Native", .{table_name});
    try client.insert(
        insert_sql,
        "",
        100,
        &cols,
        arena.allocator(),
        null,
        compressed_opts,
    );
    std.debug.print("[{s}] inserted 100 rows via {s} frames\n", .{ label, method_label });

    const select_sql = try std.fmt.allocPrint(arena.allocator(), "SELECT id, label FROM {s} ORDER BY id", .{table_name});
    var s = try client.query(select_sql, arena.allocator(), null, compressed_opts);
    var rows_seen: u32 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ids_back = b.columns[0].column.UInt32;
            const labels_back = b.columns[1].column.String;
            var j: usize = 0;
            while (j < b.num_rows) : (j += 1) {
                if (ids_back[j] != ids[rows_seen + j]) return error.InsertMismatch;
                if (!std.mem.eql(u8, labels_back[j], labels[rows_seen + j])) return error.InsertMismatch;
            }
            rows_seen += @intCast(b.num_rows);
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[{s}] select failed: {s}\n", .{ label, e.message }); return error.QueryFailed; },
        else => {},
    };
    if (rows_seen != 100) {
        std.debug.print("[{s}] FAIL: expected 100 rows, got {d}\n", .{ label, rows_seen });
        return error.UnexpectedRowCount;
    }
    std.debug.print("[{s}] OK: 100 rows round-tripped via {s} frames\n", .{ label, method_label });
}

fn runNestedCompressedInsert(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.compression = .Enable;
    cfg.compression_method = .zstd;
    const client = try clickzig.Client.connectTcp(cfg, io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const opts: clickzig.query.QueryOptions = .{ .compression = .Enable, .compression_method = .zstd };
    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_nested_compressed", arena.allocator(), null, opts);
        try drainNoException(&s, "nested-compressed-drop");
    }
    {
        var s = try client.query(
            \\CREATE TABLE smoke_nested_compressed (
            \\    id UInt32,
            \\    vals Array(Nullable(UInt32)),
            \\    attrs Map(String, Nullable(UInt32))
            \\) ENGINE = Memory
        , arena.allocator(), null, opts);
        try drainNoException(&s, "nested-compressed-create");
    }

    var ids = [_]u32{ 1, 2 };

    var vals_offsets = [_]u64{ 3, 5 };
    var vals_mask = [_]u8{ 0, 1, 0, 1, 0 };
    var vals_inner_values = [_]u32{ 10, 0, 30, 0, 50 };
    var vals_nullable: clickzig.column.Nullable = .{
        .mask = &vals_mask,
        .inner = .{ .UInt32 = &vals_inner_values },
    };
    var vals_array: clickzig.column.Array = .{
        .offsets = &vals_offsets,
        .inner = .{ .Nullable = &vals_nullable },
    };

    var attr_offsets = [_]u64{ 2, 3 };
    var attr_keys = [_][]u8{ @constCast("a"), @constCast("b"), @constCast("c") };
    var attr_mask = [_]u8{ 0, 1, 0 };
    var attr_values_raw = [_]u32{ 100, 0, 300 };
    var attr_values_nullable: clickzig.column.Nullable = .{
        .mask = &attr_mask,
        .inner = .{ .UInt32 = &attr_values_raw },
    };
    var attrs_map: clickzig.column.Map = .{
        .offsets = &attr_offsets,
        .keys = .{ .String = &attr_keys },
        .values = .{ .Nullable = &attr_values_nullable },
    };

    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
        .{ .name = "vals", .type_name = "Array(Nullable(UInt32))", .data = .{ .Array = &vals_array } },
        .{ .name = "attrs", .type_name = "Map(String, Nullable(UInt32))", .data = .{ .Map = &attrs_map } },
    };
    try client.insert(
        "INSERT INTO smoke_nested_compressed (id, vals, attrs) FORMAT Native",
        "",
        2,
        &cols,
        arena.allocator(),
        null,
        opts,
    );

    var s = try client.query("SELECT id, vals, attrs FROM smoke_nested_compressed ORDER BY id", arena.allocator(), null, opts);
    var rows: u64 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            rows += b.num_rows;
            const vals = b.columns[1].column.Array;
            const attrs = b.columns[2].column.Map;
            if (vals.offsets[0] != 3 or vals.offsets[1] != 5) return error.NestedCompressedMismatch;
            if (vals.inner.Nullable.mask[1] != 1 or vals.inner.Nullable.inner.UInt32[4] != 50) return error.NestedCompressedMismatch;
            if (attrs.offsets[0] != 2 or attrs.offsets[1] != 3) return error.NestedCompressedMismatch;
            if (!std.mem.eql(u8, attrs.keys.String[2], "c")) return error.NestedCompressedMismatch;
            if (attrs.values.Nullable.mask[1] != 1 or attrs.values.Nullable.inner.UInt32[2] != 300) return error.NestedCompressedMismatch;
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[nested-compressed-insert] exception: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows != 2) return error.UnexpectedRowCount;
    std.debug.print("[nested-compressed-insert] OK\n", .{});
}

fn runInsertRoundtrip(allocator: std.mem.Allocator, io: std.Io) !void {
    // Create a temp Memory-engine table, INSERT 3 rows, SELECT them back,
    // verify exact value match. Memory engine drops the table when the
    // server restarts so no cleanup needed across runs.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    // Drop+create.
    {
        var s = try client.query("DROP TABLE IF EXISTS smoke_roundtrip", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[insert] drop failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }
    {
        var s = try client.query("CREATE TABLE smoke_roundtrip (id UInt32, label String) ENGINE = Memory", arena.allocator(), null, .{});
        while (try s.next()) |p| switch (p) {
            .end_of_stream => break,
            .exception => |e| { std.debug.print("[insert] create failed: {s}\n", .{e.message}); return error.SetupFailed; },
            else => {},
        };
    }

    // INSERT 3 rows.
    var ids = [_]u32{ 100, 200, 300 };
    var labels = [_][]u8{ @constCast("alpha"), @constCast("beta"), @constCast("gamma") };
    const cols = [_]clickzig.block.InsertColumn{
        .{ .name = "id", .type_name = "UInt32", .data = .{ .UInt32 = &ids } },
        .{ .name = "label", .type_name = "String", .data = .{ .String = &labels } },
    };
    try client.insert(
        "INSERT INTO smoke_roundtrip (id, label) FORMAT Native",
        "",
        3,
        &cols,
        arena.allocator(),
        null,
        .{ .query_id = "smoke-insert" },
    );
    std.debug.print("[insert] inserted 3 rows\n", .{});

    // SELECT them back ordered.
    var s = try client.query("SELECT id, label FROM smoke_roundtrip ORDER BY id", arena.allocator(), null, .{});
    var rows_seen: u32 = 0;
    while (try s.next()) |p| switch (p) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const ids_back = b.columns[0].column.UInt32;
            const labels_back = b.columns[1].column.String;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                std.debug.print("[insert] read back: id={d} label={s}\n", .{ ids_back[i], labels_back[i] });
                if (ids_back[i] != ids[rows_seen + i]) return error.InsertMismatch;
                if (!std.mem.eql(u8, labels_back[i], labels[rows_seen + i])) return error.InsertMismatch;
            }
            rows_seen += @intCast(b.num_rows);
        },
        .end_of_stream => break,
        .exception => |e| { std.debug.print("[insert] select failed: {s}\n", .{e.message}); return error.QueryFailed; },
        else => {},
    };
    if (rows_seen != 3) {
        std.debug.print("[insert] FAIL: expected 3 rows back, got {d}\n", .{rows_seen});
        return error.UnexpectedRowCount;
    }
    std.debug.print("[insert] OK: 3 rows round-tripped exactly\n", .{});
}

fn runQueryMixed(allocator: std.mem.Allocator, io: std.Io) !void {
    // Multi-row, multi-type result — exercises String + Int64 + Float64
    // + DateTime decode in one go. `numbers(N)` gives us a deterministic
    // 4-row generator; the SELECT then casts/labels columns to known
    // types so the wire response has predictable schema.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const sql =
        \\SELECT
        \\    toString(number * 100) AS label,
        \\    toInt64(number) AS n,
        \\    toFloat64(number) / 3 AS frac,
        \\    toDateTime('2026-05-04 09:00:00') + number AS ts
        \\FROM numbers(4)
    ;
    var stream = try client.query(sql, arena.allocator(), null, .{ .query_id = "smoke-query-mixed" });
    var rows_seen: u64 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            if (b.num_rows == 0) continue;
            const labels = b.columns[0].column.String;
            const ns = b.columns[1].column.Int64;
            const fracs = b.columns[2].column.Float64;
            const ts = b.columns[3].column.UInt32;
            var i: usize = 0;
            while (i < b.num_rows) : (i += 1) {
                std.debug.print("[query-mixed] row: label={s} n={d} frac={d:.4} ts={d}\n", .{ labels[i], ns[i], fracs[i], ts[i] });
            }
            rows_seen += b.num_rows;
        },
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[query-mixed] server exception: {s}\n", .{e.message});
            return error.ServerExceptionDuringQuery;
        },
        else => {},
    };
    if (rows_seen != 4) {
        std.debug.print("[query-mixed] FAIL: expected 4 rows, got {d}\n", .{rows_seen});
        return error.UnexpectedRowCount;
    }
    std.debug.print("[query-mixed] OK: 4 rows x 4 columns decoded\n", .{});
}

fn runQueryBytes(allocator: std.mem.Allocator, io: std.Io) !void {
    // Full round-trip: send "SELECT 1", drain every server packet through
    // EndOfStream, dump what came back. Verifies wire format end-to-end
    // including BlockInfo, column header, and primitive column decode.
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var stream = try client.query("SELECT 1", arena.allocator(), null, .{ .query_id = "smoke-query-bytes" });
    var data_blocks: u32 = 0;
    var progress_packets: u32 = 0;
    while (try stream.next()) |packet| switch (packet) {
        .data => |b| {
            data_blocks += 1;
            std.debug.print("[query-bytes] data block: {d} cols x {d} rows\n", .{ b.columns.len, b.num_rows });
            for (b.columns) |c| {
                std.debug.print("[query-bytes]   col {s}: {s}\n", .{ c.name, c.type_name });
                switch (c.column) {
                    .UInt8 => |s| if (s.len > 0) std.debug.print("[query-bytes]     value[0]={d}\n", .{s[0]}),
                    else => {},
                }
            }
        },
        .progress => progress_packets += 1,
        .end_of_stream => break,
        .exception => |e| {
            std.debug.print("[query-bytes] server exception code={d} msg={s}\n", .{ e.code, e.message });
            return error.ServerExceptionDuringQuery;
        },
        else => {},
    };
    std.debug.print("[query-bytes] drained: {d} data blocks, {d} progress packets, state={s}\n", .{ data_blocks, progress_packets, @tagName(client.state) });
    if (client.state != .ready) return error.ClientNotReady;
}

fn baseConfig(allocator: std.mem.Allocator) clickzig.Config {
    return .{
        .control_allocator = allocator,
        .read_buffer_size = 64 * 1024,
        .write_buffer_size = 4 * 1024,
        .username = "default",
        .password = "test",
        .dial_timeout_ms = 5_000,
    };
}

fn runHappy(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    const info = client.server_info;
    std.debug.print("[happy] connected: {s} {d}.{d}.{d} rev {d}\n", .{
        info.name,
        info.major_version,
        info.minor_version,
        info.version_patch,
        info.revision,
    });
    if (info.timezone) |tz| std.debug.print("[happy] timezone: {s}\n", .{tz});
    if (info.display_name) |dn| std.debug.print("[happy] display:  {s}\n", .{dn});
    try client.ping(null);
    std.debug.print("[happy] ping/pong ok, last_used_at_ms={d}\n", .{client.last_used_at_ms});
}

fn runPing(allocator: std.mem.Allocator, io: std.Io) !void {
    const client = try clickzig.Client.connectTcp(baseConfig(allocator), io, null, null);
    defer client.close();
    const start = client.last_used_at_ms;
    var i: usize = 0;
    while (i < 100) : (i += 1) try client.ping(null);
    std.debug.print("[ping] 100 pings ok; last_used_at_ms drifted from {d} to {d}\n", .{ start, client.last_used_at_ms });
}

fn runWrongPass(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.password = "obviously-wrong";
    var diag: clickzig.Diagnostics = .{};
    defer diag.deinit();
    const result = clickzig.Client.connectTcp(cfg, io, null, &diag);
    if (result) |c| {
        c.close();
        std.debug.print("[wrong-pass] FAIL: connected with bad password\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        if (diag.server_exception) |exc| {
            std.debug.print("[wrong-pass] err={s} code={d} ({s}) msg={s}\n", .{
                @errorName(e),
                exc.code,
                exc.codeName() orelse "?",
                exc.message,
            });
        } else {
            std.debug.print("[wrong-pass] err={s} (no diagnostic)\n", .{@errorName(e)});
        }
        if (e != error.AuthenticationFailed) {
            std.debug.print("[wrong-pass] FAIL: expected AuthenticationFailed, got {s}\n", .{@errorName(e)});
            return e;
        }
    }
}

fn runUnreachable(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.port = 9001; // Nothing listens here
    cfg.dial_timeout_ms = 3_000;
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |c| {
        c.close();
        std.debug.print("[unreachable] FAIL: connected to dead port\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        std.debug.print("[unreachable] OK: got {s}\n", .{@errorName(e)});
    }
}

fn runWrongHost(allocator: std.mem.Allocator, io: std.Io) !void {
    var cfg = baseConfig(allocator);
    cfg.host = "192.0.2.1"; // TEST-NET-1; documented as unroutable
    cfg.dial_timeout_ms = 3_000;
    const result = clickzig.Client.connectTcp(cfg, io, null, null);
    if (result) |c| {
        c.close();
        std.debug.print("[wrong-host] FAIL: somehow connected to TEST-NET-1\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        std.debug.print("[wrong-host] OK: got {s}\n", .{@errorName(e)});
    }
}
