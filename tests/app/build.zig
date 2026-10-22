//! The code of zefir.App that runs on zio, in a package of its own: the
//! end-to-end tests of App with real servers, programs that the tests run
//! in processes of their own, the shop with NATS and MongoDB, and the
//! shop of the guide of App.
//!
//!   zig build e2e        run the end-to-end tests: servers of zefir-http on
//!                        http.native over loopback and of zefir-rpc on the
//!                        memory transport, beans of one App, on zio with
//!                        one executor and with four; then the programs of
//!                        programs/, stopped by SIGTERM; then the examples
//!   zig build examples   run the shop of the guide, send it the guide's
//!                        curl commands, and check that the guide shows
//!                        each with its response, and the shop's log
//!                        (Linux and macOS)
//!   zig build shop       start the NATS and mongod servers in Docker, then
//!                        run the shop with NATS and MongoDB, shop/,
//!                        against them: an order over HTTP, read back over
//!                        rpc through NATS, then SIGTERM (Linux and macOS)
//!   zig build up         start the NATS server `plain` and the mongod
//!                        server `mongo-plain` of the repository's
//!                        docker-compose.yml and wait until they are healthy
//!   zig build check      build everything without running it; no servers
//!                        needed

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });

    // Only the servers the shop uses; the other services of the compose
    // file belong to the end-to-end tests of nats, rpc-nats and mongo, so
    // this package never stops them.
    const up = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    up.addFileArg(zefir.path("docker-compose.yml"));
    up.addArgs(&.{ "--profile", "mongo", "up", "--detach", "--wait", "plain", "mongo-plain" });
    up.has_side_effects = true;
    b.step("up", "Start the NATS server plain and the mongod server mongo-plain, and wait until they are healthy").dependOn(&up.step);

    // The runtimes every scenario runs on: forEachRuntime.
    const runtime = b.createModule(.{
        .root_source_file = b.path("runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
    });

    // The programs that the end-to-end tests start in processes of their
    // own, each an App on zio: their paths go to the tests.
    const programs = b.addOptions();
    for ([_][]const u8{ "signals", "deaf" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("programs/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zefir", .module = zefir.module("zefir") },
                    .{ .name = "zio", .module = zio.module("zio") },
                },
            }),
        });
        programs.addOptionPath(name, exe.getEmittedBin());
    }

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefir", .module = zefir.module("zefir") },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "runtime", .module = runtime },
                .{ .name = "programs", .module = programs.createModule() },
            },
        }),
        // One line per test; a panic exits with code 3 instead of aborting.
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_e2e = b.addRunArtifact(e2e);
    // Show each test as it ends, and run every time: the tests use the
    // network and the clock.
    run_e2e.stdio = .inherit;
    run_e2e.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run the end-to-end tests of zefir.App on zio, then its programs stopped by SIGTERM, then the examples");
    e2e_step.dependOn(&run_e2e.step);

    // The shop of the guide, src/core/examples/app/main.zig, through the
    // root of the guide's programs: a panic exits with code 3, a run past
    // two minutes with code 4.
    const guide_dir = "src/core/examples/app/";
    const service = b.addExecutable(.{
        .name = "shop-of-the-guide",
        .root_module = b.createModule(.{
            .root_source_file = zefir.path(guide_dir ++ "example_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "example", .module = b.createModule(.{
                .root_source_file = zefir.path(guide_dir ++ "main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zefir", .module = zefir.module("zefir") },
                    .{ .name = "zio", .module = zio.module("zio") },
                },
            }) }},
        }),
    });
    // The session of the guide: the shop started, the guide's curl commands
    // sent to it, and the guide checked against what they printed.
    const guide_options = b.addOptions();
    guide_options.addOptionPath("service", service.getEmittedBin());
    const guide = b.addTest(.{
        .name = "guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guide_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "guide-check", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/http/examples/guide_check.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "guide_options", .module = guide_options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    guide.root_module.addAnonymousImport("guide", .{ .root_source_file = zefir.path(guide_dir ++ "README.md") });
    // In `e2e` after the tests; `examples` runs it alone.
    for ([_]*std.Build.Step{ e2e_step, b.step("examples", "Run the shop of the guide with its curl session and check the guide") }, 0..) |step, i| {
        const run_guide = b.addRunArtifact(guide);
        run_guide.stdio = .inherit;
        run_guide.has_side_effects = true;
        if (i == 0) run_guide.step.dependOn(&run_e2e.step);
        step.dependOn(&run_guide.step);
    }

    // The shop with NATS and MongoDB, shop/: its program, and the test that
    // starts it against the servers of `up`, whose path it gets.
    const shop = b.addExecutable(.{
        .name = "shop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shop/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefir", .module = zefir.module("zefir") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    const shop_options = b.addOptions();
    shop_options.addOptionPath("shop", shop.getEmittedBin());
    const shop_test = b.addTest(.{
        .name = "shop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefir", .module = zefir.module("zefir") },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "shop_options", .module = shop_options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_shop = b.addRunArtifact(shop_test);
    run_shop.stdio = .inherit;
    run_shop.has_side_effects = true;
    run_shop.step.dependOn(&up.step);
    b.step("shop", "Start NATS and mongod in Docker, then run the shop with NATS and MongoDB, shop/, against them").dependOn(&run_shop.step);

    // Everything above built and nothing run.
    const check_step = b.step("check", "Build the end-to-end tests, the programs, the shops and the session of the guide without running them");
    check_step.dependOn(&e2e.step);
    check_step.dependOn(&shop_test.step);
    check_step.dependOn(&guide.step);
}
