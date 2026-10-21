//! The end-to-end tests of zefir-redis against real Redis and Valkey
//! servers, on zio. The servers are those of the profile `redis` of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e      start the servers, run the tests
//!   zig build check    build the tests without running them; no servers
//!                      needed, so CI runs it on every system
//!   zig build up       only start the servers and wait until they are
//!                      healthy
//!   zig build down     stop the servers
//!
//! `up` and `down` touch the redis services only: the NATS and MongoDB
//! servers of the same compose file belong to tests/nats, tests/rpc-nats
//! and tests/mongo. The image comes from REDIS_IMAGE, redis:8.10.2 by
//! default: `REDIS_IMAGE=valkey/valkey:9.1.2 zig build e2e`; redis-old is
//! redis:6.2.24 whatever it says.

const std = @import("std");

/// The services of the profile `redis` that the tests use.
const services = [_][]const u8{ "redis-plain", "redis-auth", "redis-cluster", "redis-old" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait" });
    b.step("up", "Start the Redis servers and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
    b.step("down", "Stop the Redis servers").dependOn(&down.step);

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = zefir.module("zefir-core") },
                .{ .name = "redis", .module = zefir.module("zefir-redis") },
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
    b.step("e2e", "Run the end-to-end tests against the Redis servers").dependOn(&run.step);

    const check_step = b.step("check", "Build the tests without running them");
    check_step.dependOn(&e2e.step);
}

/// `docker compose --profile redis <args> <services>`, so that only the
/// redis services start and stop.
fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(&.{ "--profile", "redis" });
    run.addArgs(args);
    run.addArgs(&services);
    run.has_side_effects = true;
    return run;
}
