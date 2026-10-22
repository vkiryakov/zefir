//! The end-to-end tests of zefir-odm against real mongod servers, on zio:
//! the conformance suite on `mongo.OdmDriver`, and the registry with its
//! tenants, connections and documents on mongod; and its stress tests. The
//! servers are mongo-plain and mongo-auth, of the profile `mongo` of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e        start the servers, run the tests
//!   zig build check      build the tests and the stress tests without
//!                        running them; no servers needed, so CI runs it
//!                        on every system
//!   zig build stress     start the servers, run the stress tests in Debug
//!                        and in ReleaseSafe
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
            .imports = imports(b, zefir, zio),
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

    const check_step = b.step("check", "Build the tests and the stress tests without running them");
    check_step.dependOn(&e2e.step);

    // The stress tests, in Debug and then in ReleaseSafe whatever
    // -Doptimize says: each mode gets zefir and zio built in it. One mode
    // after the other, as they share the servers and the CPU, and
    // ReleaseSafe runs even when Debug fails.
    const stress_step = b.step("stress", "Run the stress tests against the mongod servers, in Debug and in ReleaseSafe");
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
        // The servers and the helpers of the end-to-end tests.
        const helpers = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = mode,
            .imports = imports(b, mode_zefir, mode_zio),
        });
        const stress = b.addTest(.{
            .name = b.fmt("stress-{t}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("stress/root.zig"),
                .target = target,
                .optimize = mode,
                .imports = imports(b, mode_zefir, mode_zio),
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        stress.root_module.addImport("e2e", helpers);
        run_stress.addArtifactArg(stress);
        // Built and not run: no servers needed.
        check_step.dependOn(&stress.step);
    }

    // The programs of the guide join this step, and `check`, with them.
    _ = b.step("examples", "Run the programs of the guide of zefir-odm against the mongod servers, and check the guide");
}

/// The modules of zefir and zio that the tests import, of one build mode.
fn imports(b: *std.Build, zefir: *std.Build.Dependency, zio: *std.Build.Dependency) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "core", .module = zefir.module("zefir-core") },
        .{ .name = "confy", .module = zefir.module("zefir-confy") },
        .{ .name = "log", .module = zefir.module("zefir-log") },
        .{ .name = "validator", .module = zefir.module("zefir-validator") },
        .{ .name = "mongo-bson", .module = zefir.module("zefir-mongo-bson") },
        .{ .name = "odm", .module = zefir.module("zefir-odm") },
        .{ .name = "mongo", .module = zefir.module("zefir-mongo") },
        .{ .name = "zio", .module = zio.module("zio") },
    }) catch @panic("OOM");
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
