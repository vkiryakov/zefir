//! The end-to-end tests of zefir-nats against real NATS servers, on zio.
//!
//!   zig build e2e    start the servers of docker-compose.yml, run the tests
//!   zig build up     only start the servers
//!   zig build down   stop the servers

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const up = compose(b, &.{ "up", "--detach", "--wait" });
    b.step("up", "Start the NATS servers and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, &.{"down"});
    b.step("down", "Stop the NATS servers").dependOn(&down.step);

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nats", .module = zefir.module("zefir-nats") },
                .{ .name = "zio", .module = zio.module("zio") },
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
}

fn compose(b: *std.Build, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(b.path("docker-compose.yml"));
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
