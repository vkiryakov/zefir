//! The end-to-end tests of zefir-rpc-nats against real NATS servers, on
//! zio: the conformance suite of rpc with a live broker that restarts, the
//! NATS CLI (`nats req`, `nats micro`) against zefir services, the NATS
//! permissions of the guide, and a broker that goes away. The servers are
//! those of docker-compose.yml at the repository root.
//!
//!   zig build e2e     start the servers, run the tests
//!   zig build check   build the tests without running them; no servers
//!                     needed, so CI runs it on every system
//!   zig build up      only start the servers
//!   zig build down    stop the servers

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    // Only the servers these tests use.
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait", "plain", "restart", "rpc-acl" });
    b.step("up", "Start the NATS servers and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
    b.step("down", "Stop the NATS servers").dependOn(&down.step);

    // The tests run the NATS CLI of the compose file, nats-box.
    const options = b.addOptions();
    options.addOptionPathUntracked("compose_file", compose_file);

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rpc", .module = zefir.module("zefir-rpc") },
                .{ .name = "rpc-nats", .module = zefir.module("zefir-rpc-nats") },
                .{ .name = "nats", .module = zefir.module("zefir-nats") },
                .{ .name = "core", .module = zefir.module("zefir-core") },
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "e2e_options", .module = options.createModule() },
            },
        }),
        // One line per test; a panic exits with code 3 instead of aborting.
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run = b.addRunArtifact(e2e);
    // The servers are outside the build graph: run every time, and show
    // each test as it ends.
    run.stdio = .inherit;
    run.step.dependOn(&up.step);
    b.step("e2e", "Run the end-to-end tests against the NATS servers").dependOn(&run.step);

    // Built and not run: no servers needed.
    b.step("check", "Build the tests without running them").dependOn(&e2e.step);
}

fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
