const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose clickzig as a module consumers can @import
    const clickzig_module = b.addModule("clickzig", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build static lib so consumers can also link if they want
    const lib = b.addLibrary(.{
        .name = "clickzig",
        .root_module = clickzig_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests on the main module
    const tests = b.addTest(.{
        .root_module = clickzig_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // End-to-end smoke executable. Talks to a real ClickHouse on
    // localhost:9000. Pass the scenario name after a `--`:
    //   zig build smoke -- happy
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("tests/smoke_connect.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_module.addImport("clickzig", clickzig_module);
    const smoke = b.addExecutable(.{
        .name = "smoke_connect",
        .root_module = smoke_module,
    });
    const run_smoke = b.addRunArtifact(smoke);
    if (b.args) |args| run_smoke.addArgs(args);
    const smoke_step = b.step("smoke", "Run smoke scenarios. Pass scenario via -- e.g. zig build smoke -- happy");
    smoke_step.dependOn(&run_smoke.step);

    // --- Examples ---
    // Each example is its own runnable: `zig build run-01-connect`,
    // `zig build run-02-diagnostics`, etc. `zig build examples` builds
    // (but doesn't run) all of them — useful as a smoke-compile check.
    const examples_step = b.step("examples", "Compile all examples");
    const example_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "01-connect", .path = "examples/01_connect.zig" },
        .{ .name = "02-diagnostics", .path = "examples/02_diagnostics.zig" },
        .{ .name = "03-observability", .path = "examples/03_observability.zig" },
        .{ .name = "04-health-check", .path = "examples/04_health_check.zig" },
        .{ .name = "05-custom-transport", .path = "examples/05_custom_transport.zig" },
    };
    for (example_files) |ex| {
        const ex_module = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
        });
        ex_module.addImport("clickzig", clickzig_module);
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = ex_module,
        });
        examples_step.dependOn(&ex_exe.step);

        const run_ex = b.addRunArtifact(ex_exe);
        const run_step_name = b.fmt("run-{s}", .{ex.name});
        const run_help = b.fmt("Run example {s}", .{ex.name});
        const run_step = b.step(run_step_name, run_help);
        run_step.dependOn(&run_ex.step);
    }
}
