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
}
