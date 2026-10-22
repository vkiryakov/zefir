//! The end-to-end tests of zefir-odm against real mongod servers, on zio:
//! the conformance suite on `mongo.OdmDriver`. The servers are mongo-plain
//! and mongo-auth, of the profile `mongo` of docker-compose.yml at the
//! repository root.
//!
//!   zig build e2e        start the servers, run the tests
//!   zig build check      build the tests without running them; no servers
//!                        needed, so CI runs it on every system
//!   zig build stress     the stress tests, in Debug and ReleaseSafe
//!   zig build examples   the programs of the guide of zefir-odm
//!   zig build up         only start the servers
//!   zig build down       stop the servers
//!
//! `up` and `down` touch mongo-plain and mongo-auth only: the other
//! servers of the same compose file belong to tests/nats, tests/rpc-nats
//! and tests/mongo. The image comes from MONGO_VERSION, 9.0.4 by default:
//! `MONGO_VERSION=7.0.45 zig build e2e`.

const std = @import("std");

/// The services of the profile `mongo` that the tests use.
const services = [_][]const u8{ "mongo-plain", "mongo-auth" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait" });
    b.step("up", "Start mongo-plain and mongo-auth and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
    b.step("down", "Stop mongo-plain and mongo-auth").dependOn(&down.step);

    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = zefir.module("zefir-core") },
                .{ .name = "confy", .module = zefir.module("zefir-confy") },
                .{ .name = "log", .module = zefir.module("zefir-log") },
                .{ .name = "validator", .module = zefir.module("zefir-validator") },
                .{ .name = "mongo-bson", .module = zefir.module("zefir-mongo-bson") },
                .{ .name = "odm", .module = zefir.module("zefir-odm") },
                .{ .name = "mongo", .module = zefir.module("zefir-mongo") },
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
    b.step("e2e", "Run the end-to-end tests against the mongod servers").dependOn(&run.step);

    const check_step = b.step("check", "Build the tests without running them");
    check_step.dependOn(&e2e.step);

    // The stress tests and the programs of the guide join these steps,
    // and `check`, with them.
    _ = b.step("stress", "Run the stress tests against the mongod servers, in Debug and in ReleaseSafe");
    _ = b.step("examples", "Run the programs of the guide of zefir-odm against the mongod servers, and check the guide");
}

/// `docker compose --profile mongo <args> <services>`, so that only the
/// services of these tests start and stop.
fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(&.{ "--profile", "mongo" });
    run.addArgs(args);
    run.addArgs(&services);
    run.has_side_effects = true;
    return run;
}
