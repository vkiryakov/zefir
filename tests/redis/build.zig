//! The end-to-end tests of zefir-redis against real Redis and Valkey
//! servers, on zio. The servers are those of the profile `redis` of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e      start the servers, run the tests
//!   zig build stress   start the servers, run the stress tests in Debug
//!                      and in ReleaseSafe
//!   zig build check    build the tests and the stress tests without
//!                      running them; no servers needed, so CI runs it on
//!                      every system
//!   zig build up       only start the servers and wait until they are
//!                      healthy; it also unpauses redis-stall, which a run
//!                      that died in the middle of a test leaves paused
//!   zig build down     stop the servers
//!
//! `up` and `down` touch the redis services only: the NATS and MongoDB
//! servers of the same compose file belong to tests/nats, tests/rpc-nats
//! and tests/mongo. The image comes from REDIS_IMAGE, redis:8.10.2 by
//! default: `REDIS_IMAGE=valkey/valkey:9.1.2 zig build e2e`; redis-old is
//! redis:6.2.24 whatever it says.

const std = @import("std");

/// The services of the profile `redis` that the tests use.
const services = [_][]const u8{ "redis-plain", "redis-auth", "redis-stall", "redis-restart", "redis-cluster", "redis-old" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait" });
    // A run that died while a test held redis-stall paused leaves it
    // paused, and `up` cannot start a paused container. Unpause it first
    // and wait until its health check passes again, for `up --wait` takes
    // it as unhealthy until then. When it runs, or is not there,
    // `docker unpause` fails, and that is fine.
    const unpause = b.addSystemCommand(&.{
        "sh", "-c",
        \\if docker unpause zefir-redis-e2e-stall >/dev/null 2>&1; then
        \\  i=0
        \\  while [ $i -lt 100 ] && [ "$(docker inspect --format '{{.State.Health.Status}}' zefir-redis-e2e-stall)" != healthy ]; do
        \\    sleep 0.1
        \\    i=$((i + 1))
        \\  done
        \\fi
        \\true
    });
    unpause.has_side_effects = true;
    up.step.dependOn(&unpause.step);
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

    const check_step = b.step("check", "Build the tests and the stress tests without running them");
    check_step.dependOn(&e2e.step);

    // The stress tests, in Debug and then in ReleaseSafe whatever
    // -Doptimize says: each mode gets zefir and zio built in it. One mode
    // after the other, as they share the server and the CPU, and
    // ReleaseSafe runs even when Debug fails.
    const stress_step = b.step("stress", "Run the stress tests against the Redis servers, in Debug and in ReleaseSafe");
    const run_stress = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\"$1"; debug=$?
        \\"$2"; safe=$?
        \\[ $debug -eq 0 ] && [ $safe -eq 0 ]
        ,
        "stress",
    });
    run_stress.stdio = .inherit;
    run_stress.has_side_effects = true;
    run_stress.step.dependOn(&up.step);
    stress_step.dependOn(&run_stress.step);
    for ([_]std.lang.Optimize{ .debug, .safe }) |mode| {
        const mode_zefir = b.dependency("zefir", .{ .target = target, .optimize = mode });
        const mode_zio = b.dependency("zio", .{ .target = target, .optimize = mode });
        const imports: []const std.Build.Module.Import = &.{
            .{ .name = "core", .module = mode_zefir.module("zefir-core") },
            .{ .name = "redis", .module = mode_zefir.module("zefir-redis") },
            .{ .name = "zio", .module = mode_zio.module("zio") },
        };
        // The servers and the helpers of the end-to-end tests.
        const helpers = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = mode,
            .imports = imports,
        });
        const stress = b.addTest(.{
            .name = b.fmt("stress-{t}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("stress/root.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    imports[0],
                    imports[1],
                    imports[2],
                    .{ .name = "e2e", .module = helpers },
                },
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        run_stress.addArtifactArg(stress);
        // Built and not run: no servers needed.
        check_step.dependOn(&stress.step);
    }
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
