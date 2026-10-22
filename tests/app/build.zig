//! The code of zefir.App that runs on zio, in a package of its own: the
//! end-to-end tests of App with real servers, and programs that the tests
//! run in processes of their own.
//!
//!   zig build e2e        run the end-to-end tests: servers of zefir-http on
//!                        http.native over loopback and of zefir-rpc on the
//!                        memory transport, beans of one App, on zio with
//!                        one executor and with four; then the programs of
//!                        programs/, stopped by SIGTERM (Linux and macOS)
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
    b.step("e2e", "Run the end-to-end tests of zefir.App on zio, then its programs stopped by SIGTERM").dependOn(&run_e2e.step);

    // Everything above built and nothing run.
    const check_step = b.step("check", "Build the end-to-end tests and the programs without running them");
    check_step.dependOn(&e2e.step);
}
