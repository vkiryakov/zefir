//! The end-to-end tests of zefir-redis against real Redis and Valkey
//! servers, on zio. The servers are those of the profile `redis` of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e              start the servers, run the tests, then the
//!                              programs of the guide, checking their runs
//!                              against the guide
//!   zig build examples         start the servers, run only the programs of
//!                              the guide and check the guide
//!   zig build example-<name>   start the servers, run one program of the
//!                              guide and show what it prints, such as
//!                              example-quick_start
//!   zig build stress           start the servers, run the stress tests in
//!                              Debug and in ReleaseSafe
//!   zig build check            build the tests, the programs of the guide
//!                              and the stress tests without running them;
//!                              no servers needed, so CI runs it on every
//!                              system
//!   zig build up               only start the servers and wait until they
//!                              are healthy; it also unpauses redis-stall,
//!                              which a run that died in the middle of a
//!                              test leaves paused
//!   zig build down             stop the servers
//!
//! `up` and `down` touch the redis services only: the NATS and MongoDB
//! servers of the same compose file belong to tests/nats, tests/rpc-nats
//! and tests/mongo. The image comes from REDIS_IMAGE, redis:8.10.2 by
//! default: `REDIS_IMAGE=valkey/valkey:9.1.2 zig build e2e`; redis-old is
//! redis:6.2.24 whatever it says.

const std = @import("std");

/// The services of the profile `redis` that the tests use.
const services = [_][]const u8{ "redis-plain", "redis-auth", "redis-stall", "redis-restart", "redis-cluster", "redis-old" };

/// A program of the guide of zefir-redis, src/redis/examples, that needs a
/// server, and its run.
const Example = struct {
    /// The file in src/redis/examples, without `.zig`.
    name: []const u8,
    /// The settings of its run here, against the servers of
    /// docker-compose.yml.
    env: []const [2][]const u8,
    /// The run as the guide shows it: what a reader types, against a server
    /// of their own.
    command: []const u8,
};

/// redis-plain, for the programs without a password.
const plain: []const [2][]const u8 = &.{.{ "APP_REDIS_URL", "redis://127.0.0.1:16379" }};

/// The programs, in the order of the guide: `server_programs` of
/// src/redis/examples/cases.zig, which guide_test.zig checks.
const examples = [_]Example{
    .{ .name = "quick_start", .env = plain, .command = "$ zig build run" },
    .{
        .name = "connect",
        .env = &.{ .{ "APP_REDIS_URL", "redis://app@127.0.0.1:16380" }, .{ "APP_REDIS_PASSWORD", "app-pass" } },
        .command = "$ APP_REDIS_URL=redis://127.0.0.1:6380 APP_REDIS_PASSWORD=change-me zig build run",
    },
};

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
    const e2e_step = b.step("e2e", "Run the end-to-end tests, then the programs of the guide, against the Redis servers");
    e2e_step.dependOn(&run.step);

    // The programs of the guide that need a server, on zio: `e2e` runs them
    // after the tests, `examples` on their own, each run after the one
    // before it, and then checks that the guide shows every run as it
    // printed. `example-<name>` runs one and shows what it prints.
    const examples_step = b.step("examples", "Run the programs of the guide against the Redis servers, and check the guide");
    const check_step = b.step("check", "Build the tests, the programs of the guide and the stress tests without running them");
    check_step.dependOn(&e2e.step);
    const in_e2e = addGuideCheck(b, zefir, target, optimize);
    const alone = addGuideCheck(b, zefir, target, optimize);
    var after_tests: *std.Build.Step = &run.step;
    var after_previous: *std.Build.Step = &up.step;
    for (examples) |example| {
        const exe = addExample(b, zefir, zio, example.name, target, optimize);
        check_step.dependOn(&exe.step);
        const source = zefir.path(b.fmt("src/redis/examples/{s}.zig", .{example.name}));
        for ([_]*std.Build.Step.Compile{ in_e2e, alone }, [_]**std.Build.Step{ &after_tests, &after_previous }, [_][]const u8{ "e2e", "examples" }) |guide, previous, chain| {
            const checked = runExample(b, exe, example, .check);
            checked.step.dependOn(&up.step);
            checked.step.dependOn(previous.*);
            previous.* = &checked.step;
            // A run with side effects keeps what it printed in a directory
            // named by its arguments, its environment and this name, and
            // the programs share their environment: the name keeps the
            // runs apart.
            const out = checked.captureStdOut(.{ .basename = b.fmt("{s}-{s}.out", .{ chain, example.name }) });
            guide.root_module.addAnonymousImport(b.fmt("{s}.out", .{example.name}), .{ .root_source_file = out });
            guide.root_module.addAnonymousImport(b.fmt("{s}.zig", .{example.name}), .{ .root_source_file = source });
        }
        const shown = runExample(b, exe, example, .show);
        shown.step.dependOn(&up.step);
        b.step(b.fmt("example-{s}", .{example.name}), b.fmt("Run the program {s} of the guide against the Redis servers", .{example.name})).dependOn(&shown.step);
    }
    for ([_]*std.Build.Step.Compile{ in_e2e, alone }, [_]*std.Build.Step{ e2e_step, examples_step }, [_]*std.Build.Step{ after_tests, after_previous }) |guide, step, last| {
        const run_guide = b.addRunArtifact(guide);
        run_guide.stdio = .inherit;
        run_guide.has_side_effects = true;
        run_guide.step.dependOn(last);
        step.dependOn(&run_guide.step);
    }

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

/// The program `name` of the guide, src/redis/examples/<name>.zig, built
/// with the root of the guide's programs: a panic exits with code 3, a run
/// past two minutes with code 4.
fn addExample(
    b: *std.Build,
    zefir: *std.Build.Dependency,
    zio: *std.Build.Dependency,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const example = b.createModule(.{
        .root_source_file = zefir.path(b.fmt("src/redis/examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "redis", .module = zefir.module("zefir-redis") },
            .{ .name = "core", .module = zefir.module("zefir-core") },
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            .{ .name = "log", .module = zefir.module("zefir-log") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = zefir.path("src/redis/examples/example_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "example", .module = example }},
        }),
    });
}

/// A run of `exe` with the settings of `example`: `.check` captures what it
/// prints for the check of the guide, `.show` prints it.
fn runExample(b: *std.Build, exe: *std.Build.Step.Compile, example: Example, output: enum { check, show }) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    // The servers are outside the build graph: run every time.
    run.has_side_effects = true;
    for (example.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    switch (output) {
        .check => run.expectExitCode(0),
        .show => run.stdio = .inherit,
    }
    return run;
}

/// The check of the guide, guide_test.zig, without what the programs
/// printed: the caller embeds each program as `<name>.zig` and what it
/// printed as `<name>.out`.
fn addGuideCheck(b: *std.Build, zefir: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const options = b.addOptions();
    var names: [examples.len][]const u8 = undefined;
    var commands: [examples.len][]const u8 = undefined;
    for (examples, &names, &commands) |example, *name, *command| {
        name.* = example.name;
        command.* = example.command;
    }
    options.addOption([]const []const u8, "names", &names);
    options.addOption([]const []const u8, "commands", &commands);
    const guide = b.addTest(.{
        .name = "guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guide_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guide-check", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/redis/examples/guide_check.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "cases", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/redis/examples/cases.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "guide_examples", .module = options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    guide.root_module.addAnonymousImport("guide", .{ .root_source_file = zefir.path("src/redis/examples/README.md") });
    return guide;
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
