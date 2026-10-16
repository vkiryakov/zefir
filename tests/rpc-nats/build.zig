//! The end-to-end tests of zefir-rpc-nats against real NATS servers, on
//! zio: the conformance suite of rpc with a live broker that restarts, the
//! NATS CLI (`nats req`, `nats micro`) against zefir services, the NATS
//! permissions of the guide, and a broker that goes away. Then the examples
//! of the guide, src/rpc-nats/examples, whose runs the guide must show as
//! they printed. The servers are those of docker-compose.yml at the
//! repository root.
//!
//!   zig build e2e              start the servers, run the tests, then the
//!                              examples and the check of the guide
//!   zig build example-<name>   start the servers, run one example and show
//!                              what it prints, such as
//!                              example-getting_started
//!   zig build check            build all of the above without running it; no
//!                              servers needed, so CI runs it on every system
//!   zig build up               only start the servers
//!   zig build down             stop the servers

const std = @import("std");

/// An example of the guide of rpc-nats, and its run.
const Example = struct {
    /// The file in src/rpc-nats/examples, without `.zig`.
    name: []const u8,
    /// The settings of its run here, against the servers of
    /// docker-compose.yml.
    env: []const [2][]const u8,
    /// The run as the guide shows it: what a reader types, against a server
    /// on the default port.
    command: []const u8,
};

const examples = [_]Example{
    .{
        .name = "getting_started",
        .env = &.{.{ "APP_NATS_URL", "nats://127.0.0.1:14222" }},
        .command = "$ zig build run",
    },
    .{
        .name = "two_services",
        .env = &.{
            .{ "APP_NATS_URL", "nats://127.0.0.1:14233" },
            .{ "APP_USERS_NATS_PASSWORD", "users" },
            .{ "APP_ORDERS_NATS_PASSWORD", "orders" },
        },
        .command = "$ APP_USERS_NATS_PASSWORD=users APP_ORDERS_NATS_PASSWORD=orders zig build run",
    },
};

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
    const e2e_step = b.step("e2e", "Run the end-to-end tests, then the examples of the guide, against the NATS servers");
    e2e_step.dependOn(&run.step);

    // The examples of the guide import the users service of the guide of
    // rpc, its contract and its handler, as packages.
    const users_api = b.createModule(.{
        .root_source_file = zefir.path("src/rpc/examples/users_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rpc", .module = zefir.module("zefir-rpc") },
            .{ .name = "validator", .module = zefir.module("zefir-validator") },
        },
    });
    const users_service = b.createModule(.{
        .root_source_file = zefir.path("src/rpc/examples/users_service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rpc", .module = zefir.module("zefir-rpc") },
            .{ .name = "core", .module = zefir.module("zefir-core") },
            .{ .name = "users-api", .module = users_api },
        },
    });
    const guide_examples = b.addOptions();
    var names: [examples.len][]const u8 = undefined;
    var commands: [examples.len][]const u8 = undefined;
    for (examples, &names, &commands) |example, *n, *c| {
        n.* = example.name;
        c.* = example.command;
    }
    guide_examples.addOption([]const []const u8, "names", &names);
    guide_examples.addOption([]const []const u8, "commands", &commands);
    const guide = b.addTest(.{
        .name = "guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guide_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guide-check", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/rpc/examples/guide_check.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "guide_examples", .module = guide_examples.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    guide.root_module.addAnonymousImport("guide", .{ .root_source_file = zefir.path("src/rpc-nats/examples/README.md") });
    guide.root_module.addAnonymousImport("acl.conf", .{ .root_source_file = b.path("conf/acl.conf") });

    // In `e2e` the examples run after the tests, one after another, and
    // what each prints goes to the check of the guide, which runs last.
    // The check of the guide embeds what the examples printed, so only `e2e`
    // builds it.
    const check_step = b.step("check", "Build the tests and the examples without running them");
    check_step.dependOn(&e2e.step);
    var previous: *std.Build.Step = &run.step;
    for (examples) |example| {
        const source = zefir.path(b.fmt("src/rpc-nats/examples/{s}.zig", .{example.name}));
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("example_main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "example", .module = b.createModule(.{
                    .root_source_file = source,
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "rpc", .module = zefir.module("zefir-rpc") },
                        .{ .name = "rpc-nats", .module = zefir.module("zefir-rpc-nats") },
                        .{ .name = "nats", .module = zefir.module("zefir-nats") },
                        .{ .name = "core", .module = zefir.module("zefir-core") },
                        .{ .name = "confy", .module = zefir.module("zefir-confy") },
                        .{ .name = "log", .module = zefir.module("zefir-log") },
                        .{ .name = "zio", .module = zio.module("zio") },
                        .{ .name = "users-api", .module = users_api },
                        .{ .name = "users-service", .module = users_service },
                    },
                }) }},
            }),
        });
        check_step.dependOn(&exe.step);

        const checked = b.addRunArtifact(exe);
        // The servers are outside the build graph: run every time.
        checked.has_side_effects = true;
        for (example.env) |pair| checked.setEnvironmentVariable(pair[0], pair[1]);
        checked.expectExitCode(0);
        checked.step.dependOn(&up.step);
        // After the tests, and after the example before it.
        checked.step.dependOn(previous);
        previous = &checked.step;
        guide.root_module.addAnonymousImport(b.fmt("{s}.out", .{example.name}), .{ .root_source_file = checked.captureStdOut(.{}) });
        guide.root_module.addAnonymousImport(b.fmt("{s}.zig", .{example.name}), .{ .root_source_file = source });

        const shown = b.addRunArtifact(exe);
        shown.has_side_effects = true;
        for (example.env) |pair| shown.setEnvironmentVariable(pair[0], pair[1]);
        shown.stdio = .inherit;
        shown.step.dependOn(&up.step);
        b.step(b.fmt("example-{s}", .{example.name}), b.fmt("Run the example {s} against the NATS servers", .{example.name})).dependOn(&shown.step);
    }
    const run_guide = b.addRunArtifact(guide);
    run_guide.stdio = .inherit;
    run_guide.has_side_effects = true;
    e2e_step.dependOn(&run_guide.step);
}

fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
