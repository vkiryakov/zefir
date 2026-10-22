//! The code of zefir-http that runs on zio, in a package of its own: the
//! probes of how zio behaves on each system, the end-to-end tests, the
//! service of the guide, the benchmark and the target of the HTTP Garden.
//!
//!   zig build e2e        run the end-to-end tests: servers on http.native
//!                        over loopback, on zio with one executor and with
//!                        four; then the examples; and build the small
//!                        application of the guide of zefir-openapi
//!   zig build examples   run the service of the guide, send it the guide's
//!                        curl commands, and check that the guide shows
//!                        each with its response, and the service's log
//!                        (Linux and macOS)
//!   zig build probes     run the probes, on zio with one executor and with
//!                        four: read and write timeouts, the socket watcher
//!                        of a request, and the cost of the tasks of a
//!                        request; they print what they measure
//!   zig build bench      run the benchmark, built with ReleaseFast unless
//!                        -Dbench-optimize says otherwise (CI's bench.yml,
//!                        on Linux)
//!   zig build garden-echo
//!                        build the echo server of the HTTP Garden's target
//!                        into zig-out/bin (garden/README.md)
//!   zig build garden-payloads
//!                        print the corpus of the parser as lines of the
//!                        HTTP Garden's REPL
//!   zig build check      build everything without running it, the
//!                        benchmark in the mode of -Doptimize

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

    // The small application of the guide of zefir-openapi,
    // src/openapi/examples/main.zig, which imports zio: built, not run.
    // `zig build test-openapi` checks its document against its file.
    const openapi_app = b.addExecutable(.{
        .name = "openapi-todos",
        .root_module = b.createModule(.{
            .root_source_file = zefir.path("src/openapi/examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefir", .module = zefir.module("zefir") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    // Code generation too, not only analysis: the binary is asked for.
    _ = openapi_app.getEmittedBin();
    e2e_step.dependOn(&openapi_app.step);

    // The benchmark: `bench` runs it, built with ReleaseFast unless
    // -Dbench-optimize says otherwise, with zefir and zio built in that
    // mode too; it serves the files of the guide's service. Only CI runs it
    // (bench.yml, on Linux).
    const bench_optimize = b.option(std.lang.Optimize, "bench-optimize", "The mode of the benchmark (default: ReleaseFast)") orelse .fast;
    const run_bench = b.addRunArtifact(addBench(b, target, bench_optimize));
    run_bench.addDirectoryArg(zefir.path(examples_dir ++ "public"));
    run_bench.stdio = .inherit;
    run_bench.has_side_effects = true;
    b.step("bench", "Run the benchmark of zefir-http (ReleaseFast unless -Dbench-optimize says otherwise)").dependOn(&run_bench.step);

    // The target of the HTTP Garden (garden/README.md): the echo server
    // that its Dockerfile builds and runs, and the corpus of the parser as
    // lines of the Garden's REPL.
    const garden_echo = b.addExecutable(.{
        .name = "zefir-garden-echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("garden/echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http", .module = zefir.module("zefir-http") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    b.step("garden-echo", "Build the echo server of the HTTP Garden's target into zig-out/bin").dependOn(&b.addInstallArtifact(garden_echo, .{}).step);
    const garden_payloads = b.addExecutable(.{
        .name = "garden-payloads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("garden/payloads.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "corpus", .module = b.createModule(.{
                .root_source_file = zefir.path("src/http/h1/fuzz.zig"),
                .target = target,
                .optimize = optimize,
            }) }},
        }),
    });
    const run_payloads = b.addRunArtifact(garden_payloads);
    run_payloads.stdio = .inherit;
    run_payloads.has_side_effects = true;
    b.step("garden-payloads", "Print the corpus of the parser as lines of the HTTP Garden's REPL").dependOn(&run_payloads.step);

    // Everything above built and nothing run; the benchmark in the mode
    // of -Doptimize.
    const check_step = b.step("check", "Build the probes, the end-to-end tests, the examples, the benchmark and the Garden's target without running them");
    check_step.dependOn(&probes.step);
    check_step.dependOn(&e2e.step);
    check_step.dependOn(&guide.step);
    check_step.dependOn(&service.step);
    check_step.dependOn(&openapi_app.step);
    const checked_bench = addBench(b, target, optimize);
    // Code generation too, not only analysis: the binaries are asked for.
    for ([_]*std.Build.Step.Compile{ checked_bench, garden_echo, garden_payloads }) |exe| {
        _ = exe.getEmittedBin();
        check_step.dependOn(&exe.step);
    }
}

/// The benchmark, with zefir and zio built in `mode` too.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget, mode: std.lang.Optimize) *std.Build.Step.Compile {
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = mode });
    const zio = b.dependency("zio", .{ .target = target, .optimize = mode });
    return b.addExecutable(.{
        .name = b.fmt("bench-{t}", .{mode}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "http", .module = zefir.module("zefir-http") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
}
