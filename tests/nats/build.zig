//! The end-to-end tests of zefir-nats against real NATS servers, on zio.
//! The servers are those of docker-compose.yml at the repository root.
//!
//!   zig build e2e    start the servers, run the tests
//!   zig build up     only start the servers
//!   zig build down   stop the servers; it also resets them after a run
//!                    that died while a test held one paused

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait" });
    // A run that died while a test held the stall server paused leaves it
    // paused, and `up` cannot start a paused container. Unpause it first and
    // wait until its health check passes again, for `up --wait` takes it as
    // unhealthy until then. When it runs, or is not there, `docker unpause`
    // fails, and that is fine.
    const unpause = b.addSystemCommand(&.{
        "sh", "-c",
        \\if docker unpause zefir-nats-e2e-stall >/dev/null 2>&1; then
        \\  i=0
        \\  while [ $i -lt 100 ] && [ "$(docker inspect --format '{{.State.Health.Status}}' zefir-nats-e2e-stall)" != healthy ]; do
        \\    sleep 0.1
        \\    i=$((i + 1))
        \\  done
        \\fi
    });
    unpause.has_side_effects = true;
    up.step.dependOn(&unpause.step);
    b.step("up", "Start the NATS servers and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
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

fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
