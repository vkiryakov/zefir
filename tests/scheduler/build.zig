//! The end-to-end tests of zefir-scheduler against real mongod servers, on
//! zio: the conformance suite on `mongo.SchedulerStore`, also through a
//! proxy that loses replies, the plan of a claim, and workers in several
//! instances, one of them in a process of its own that the tests kill,
//! through faults of the network and of the servers; its stress tests; and
//! the programs of its guide that need mongod. The servers are
//! mongo-plain, mongo-stall and mongo-restart, of the profile `mongo` of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e              start the servers, run the tests
//!   zig build examples         start the servers, run the programs of the
//!                              guide that need mongod, one after another
//!   zig build example-<name>   start the servers, run one program of the
//!                              guide and show what it prints, such as
//!                              example-mongo_quick_start
//!   zig build check            build the tests, the program they start,
//!                              the programs of the guide and the stress
//!                              tests without running them; no servers
//!                              needed, so CI runs it on every system
//!   zig build stress           start the servers, run the stress tests in
//!                              Debug and in ReleaseSafe
//!   zig build up               only start the servers; it also unpauses
//!                              mongo-stall, which a run that died in the
//!                              middle of a test leaves paused
//!   zig build down             stop the servers
//!
//! `up` and `down` touch these three services only: the other servers of
//! the same compose file belong to tests/nats, tests/rpc-nats, tests/mongo
//! and tests/odm. The image comes from MONGO_VERSION, 9.0.4 by default:
//! `MONGO_VERSION=7.0.45 zig build e2e`.

const std = @import("std");

/// The services of the profile `mongo` that the tests use.
const services = [_][]const u8{ "mongo-plain", "mongo-stall", "mongo-restart" };

/// A program of the guide of zefir-scheduler, src/scheduler/examples, that
/// needs mongod.
const Example = struct {
    /// The file in src/scheduler/examples, without `.zig`.
    name: []const u8,
    /// The settings of its run here, against the servers of
    /// docker-compose.yml.
    env: []const [2][]const u8,
};

/// mongo-plain.
const plain: []const [2][]const u8 = &.{.{ "APP_MONGO_URI", "mongodb://127.0.0.1:27117" }};

/// The programs, in the order of the guide: `server_programs` of
/// src/scheduler/examples/cases.zig.
const examples = [_]Example{
    .{ .name = "mongo_quick_start", .env = plain },
    .{ .name = "instances", .env = plain },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    const compose_file = zefir.path("docker-compose.yml");
    const up = compose(b, compose_file, &.{ "up", "--detach", "--wait" });
    // A run that died while a test held mongo-stall paused leaves it
    // paused, and `up` cannot start a paused container. Unpause it first
    // and wait until its health check passes again. When it runs, or is
    // not there, `docker unpause` fails, and that is fine.
    const unpause = b.addSystemCommand(&.{
        "sh", "-c",
        \\if docker unpause zefir-mongo-e2e-stall >/dev/null 2>&1; then
        \\  i=0
        \\  while [ $i -lt 100 ] && [ "$(docker inspect --format '{{.State.Health.Status}}' zefir-mongo-e2e-stall)" != healthy ]; do
        \\    sleep 0.1
        \\    i=$((i + 1))
        \\  done
        \\fi
        \\true
    });
    unpause.has_side_effects = true;
    up.step.dependOn(&unpause.step);
    b.step("up", "Start mongo-plain, mongo-stall and mongo-restart and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
    b.step("down", "Stop mongo-plain, mongo-stall and mongo-restart").dependOn(&down.step);

    const imports = importsOf(b, zefir, zio);
    // The worker that a test starts in a process of its own and kills: its
    // path goes to the tests.
    const child = b.addExecutable(.{
        .name = "worker_child",
        .root_module = b.createModule(.{
            .root_source_file = b.path("programs/worker_child.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const programs = b.addOptions();
    programs.addOptionPath("worker_child", child.getEmittedBin());
    const e2e_module = b.createModule(.{
        .root_source_file = b.path("e2e/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    e2e_module.addImport("programs", programs.createModule());
    const e2e = b.addTest(.{
        .name = "e2e",
        .root_module = e2e_module,
        // One line per test; a panic exits with code 3 instead of aborting.
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run = b.addRunArtifact(e2e);
    // The servers are outside the build graph: run every time, and show
    // each test as it ends.
    run.stdio = .inherit;
    run.step.dependOn(&up.step);
    b.step("e2e", "Run the end-to-end tests against the mongod servers").dependOn(&run.step);
    const check_step = b.step("check", "Build the tests, the program they start, the programs of the guide and the stress tests without running them");
    check_step.dependOn(&e2e.step);

    // The programs of the guide that need mongod, on zio: `examples` runs
    // them one after another, `example-<name>` runs one; each shows what
    // it prints, and fails unless it exits with code 0.
    const examples_step = b.step("examples", "Run the programs of the guide of zefir-scheduler that need mongod");
    var after_previous: *std.Build.Step = &up.step;
    for (examples) |example| {
        const exe = addExample(b, zefir, imports, example.name, target, optimize);
        check_step.dependOn(&exe.step);
        const in_turn = runExample(b, exe, example);
        in_turn.step.dependOn(after_previous);
        after_previous = &in_turn.step;
        const alone = runExample(b, exe, example);
        alone.step.dependOn(&up.step);
        b.step(b.fmt("example-{s}", .{example.name}), b.fmt("Run the program {s} of the guide against mongo-plain", .{example.name})).dependOn(&alone.step);
    }
    examples_step.dependOn(after_previous);

    // The stress tests, in Debug and then in ReleaseSafe whatever
    // -Doptimize says: each mode gets zefir and zio built in it. One mode
    // after the other, as they share the server and the CPU, and
    // ReleaseSafe runs even when Debug fails.
    const stress_step = b.step("stress", "Run the stress tests against mongo-plain, in Debug and in ReleaseSafe");
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
        const mode_imports = importsOf(b, b.dependency("zefir", .{ .target = target, .optimize = mode }), b.dependency("zio", .{ .target = target, .optimize = mode }));
        // The servers, the proxy and the helpers of the end-to-end tests.
        const helpers = b.createModule(.{
            .root_source_file = b.path("e2e/root.zig"),
            .target = target,
            .optimize = mode,
            .imports = mode_imports,
        });
        const stress = b.addTest(.{
            .name = b.fmt("stress-{t}", .{mode}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("stress/root.zig"),
                .target = target,
                .optimize = mode,
                .imports = mode_imports,
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        stress.root_module.addImport("e2e", helpers);
        run_stress.addArtifactArg(stress);
        // Built and not run: no servers needed.
        check_step.dependOn(&stress.step);
    }
}

/// The program `name` of the guide, src/scheduler/examples/<name>.zig,
/// built with the root of the guide's programs: a panic exits with code 3,
/// a run past two minutes with code 4.
fn addExample(
    b: *std.Build,
    zefir: *std.Build.Dependency,
    imports: []const std.Build.Module.Import,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const example = b.createModule(.{
        .root_source_file = zefir.path(b.fmt("src/scheduler/examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = zefir.path("src/scheduler/examples/example_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "example", .module = example }},
        }),
    });
}

/// A run of `exe` with the settings of `example`, which shows what it
/// prints.
fn runExample(b: *std.Build, exe: *std.Build.Step.Compile, example: Example) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    // The servers are outside the build graph: run every time.
    run.has_side_effects = true;
    run.stdio = .inherit;
    for (example.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    return run;
}

/// The modules of zefir and zio that the tests and the programs of the
/// guide import, of one build mode.
fn importsOf(b: *std.Build, zefir: *std.Build.Dependency, zio: *std.Build.Dependency) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "core", .module = zefir.module("zefir-core") },
        .{ .name = "confy", .module = zefir.module("zefir-confy") },
        .{ .name = "log", .module = zefir.module("zefir-log") },
        .{ .name = "scheduler", .module = zefir.module("zefir-scheduler") },
        .{ .name = "mongo", .module = zefir.module("zefir-mongo") },
        .{ .name = "mongo-bson", .module = zefir.module("zefir-mongo-bson") },
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
