//! The code of zefir-http that runs on zio, in a package of its own: the
//! probes of how zio behaves on each system, and later the end-to-end
//! tests, the examples of the guide and the benchmark.
//!
//!   zig build probes   run the probes, on zio with one executor and with
//!                      four: read and write timeouts, the socket watcher
//!                      of a request, and the cost of the tasks of a
//!                      request; they print what they measure
//!   zig build check    build everything without running it

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    // The runtimes every scenario runs on: forEachRuntime.
    const runtime = b.createModule(.{
        .root_source_file = b.path("runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
    });

    const probes = b.addTest(.{
        .name = "probes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("probes/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "runtime", .module = runtime },
            },
        }),
        // One line per test; a panic exits with code 3 instead of aborting.
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_probes = b.addRunArtifact(probes);
    // The probes measure the system: run every time, and show what they
    // print as each test ends.
    run_probes.stdio = .inherit;
    run_probes.has_side_effects = true;
    b.step("probes", "Run the probes of zio: timeouts, the socket watcher and the cost of request tasks").dependOn(&run_probes.step);

    // Everything above built and nothing run.
    const check_step = b.step("check", "Build the probes without running them");
    check_step.dependOn(&probes.step);
}
