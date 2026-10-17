//! The code of zefir-http that runs on zio, in a package of its own: the
//! probes of how zio behaves on each system, the end-to-end tests, the
//! service of the guide, and later the benchmark.
//!
//!   zig build e2e        run the end-to-end tests: servers on http.native
//!                        over loopback, on zio with one executor and with
//!                        four; then the examples
//!   zig build examples   run the service of the guide, send it the guide's
//!                        curl commands, and check that the guide shows
//!                        each with its response, and the service's log
//!                        (Linux and macOS)
//!   zig build probes     run the probes, on zio with one executor and with
//!                        four: read and write timeouts, the socket watcher
//!                        of a request, and the cost of the tasks of a
//!                        request; they print what they measure
//!   zig build check      build everything without running it

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });

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

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = zefir.module("zefir-http") },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "runtime", .module = runtime },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.stdio = .inherit;
    run_e2e.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run the end-to-end tests of zefir-http on zio, then the examples of the guide");
    e2e_step.dependOn(&run_e2e.step);

    // The service of the guide, src/http/examples/main.zig, through the
    // root of the guide's programs: a panic exits with code 3, a run past
    // two minutes with code 4.
    const examples_dir = "src/http/examples/";
    const service = b.addExecutable(.{
        .name = "todo-service",
        .root_module = b.createModule(.{
            .root_source_file = zefir.path(examples_dir ++ "example_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "example", .module = b.createModule(.{
                .root_source_file = zefir.path(examples_dir ++ "main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "http", .module = zefir.module("zefir-http") },
                    .{ .name = "core", .module = zefir.module("zefir-core") },
                    .{ .name = "validator", .module = zefir.module("zefir-validator") },
                    .{ .name = "confy", .module = zefir.module("zefir-confy") },
                    .{ .name = "log", .module = zefir.module("zefir-log") },
                    .{ .name = "zio", .module = zio.module("zio") },
                },
            }) }},
        }),
    });
    // The session of the guide: the service started, the guide's curl
    // commands sent to it, and the guide checked against what they printed.
    const guide_options = b.addOptions();
    guide_options.addOptionPath("service", service.getEmittedBin());
    guide_options.addOptionPathUntracked("public_dir", zefir.path(examples_dir ++ "public"));
    const guide = b.addTest(.{
        .name = "guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guide_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "guide-check", .module = b.createModule(.{
                    .root_source_file = zefir.path(examples_dir ++ "guide_check.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "guide_options", .module = guide_options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    guide.root_module.addAnonymousImport("guide", .{ .root_source_file = zefir.path(examples_dir ++ "README.md") });
    // In `e2e` after the tests; `examples` runs it alone.
    for ([_]*std.Build.Step{ e2e_step, b.step("examples", "Run the service of the guide with its curl session and check the guide") }, 0..) |step, i| {
        const run_guide = b.addRunArtifact(guide);
        run_guide.stdio = .inherit;
        run_guide.has_side_effects = true;
        if (i == 0) run_guide.step.dependOn(&run_e2e.step);
        step.dependOn(&run_guide.step);
    }

    // Everything above built and nothing run.
    const check_step = b.step("check", "Build the probes, the end-to-end tests and the examples without running them");
    check_step.dependOn(&probes.step);
    check_step.dependOn(&e2e.step);
    check_step.dependOn(&guide.step);
    check_step.dependOn(&service.step);
}
