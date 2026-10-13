//! The end-to-end tests, examples, stress tests and benchmark of
//! zefir-nats against real NATS servers, on zio. The servers are those of
//! docker-compose.yml at the repository root.
//!
//!   zig build e2e              start the servers, run the tests and the examples
//!   zig build examples         start the servers, run the examples
//!   zig build example-<name>   start the servers, run one example, such as
//!                              example-pub_sub
//!   zig build stress           start the servers, run the stress tests in
//!                              Debug and in ReleaseSafe
//!   zig build bench            start the servers, run the benchmark,
//!                              built with ReleaseFast unless
//!                              -Dbench-optimize says otherwise
//!   zig build up               only start the servers
//!   zig build down             stop the servers; it also resets them after a run
//!                              that died while a test held one paused

const std = @import("std");

/// A run of an example of src/nats/examples, and what it must print.
const Example = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The step that runs it alone is `example-<run>`.
    run: []const u8,
    /// The settings it reads from the environment.
    env: []const [2][]const u8,
    /// Lines its output must hold; the timestamp in front of each varies.
    expect: []const []const u8,
    exit_code: u8 = 0,
};

const plain = "nats://127.0.0.1:14222";
const auth = "nats://127.0.0.1:14223";

const examples = [_]Example{
    .{
        .name = "pub_sub",
        .run = "pub_sub",
        .env = &.{.{ "APP_NATS_URL", plain }},
        .expect = &.{
            "INFO  [shop] Order placed order_id=1001\n",
            "INFO  [shop] Order cancelled order_id=1002\n",
            "INFO  [mailer] Confirmation sent order_id=1003 to=grace@example.com total=120.00\n",
            "INFO  [mailer] Cancellation sent order_id=1002 reason=out-of-stock\n",
        },
    },
    .{
        .name = "queue_group",
        .run = "queue_group",
        .env = &.{.{ "APP_NATS_URL", plain }},
        .expect = &.{"INFO  [shop] All orders handled orders=9\n"},
    },
    .{
        .name = "request_reply",
        .run = "request_reply",
        .env = &.{.{ "APP_NATS_URL", plain }},
        .expect = &.{
            "INFO  [checkout] Quote received sku=grinder cents=4900 currency=EUR\n",
            "INFO  [checkout] Cart priced items=3 total_cents=6598\n",
            "WARN  [checkout] No shipping service, shipping priced later\n",
        },
    },
    .{
        .name = "scatter_gather",
        .run = "scatter_gather",
        .env = &.{.{ "APP_NATS_URL", plain }},
        .expect = &.{
            "INFO  [shop] Stock counted sku=sku-42 warehouses=3 units=42\n",
            "INFO  [shop] Enough stock found needed=20 found=42\n",
        },
    },
    .{
        .name = "user_password_auth",
        .run = "user_password_auth",
        .env = &.{ .{ "APP_NATS_URL", auth }, .{ "APP_NATS_USER", "alice" }, .{ "APP_NATS_PASSWORD", "secret" } },
        .expect = &.{
            "INFO  Connecting config.nats.url=nats://127.0.0.1:14223 config.nats.user=alice config.nats.password=[REDACTED]\n",
            "INFO  Connected user=alice\n",
        },
    },
    .{
        .name = "user_password_auth",
        .run = "user_password_auth-refused",
        .env = &.{ .{ "APP_NATS_URL", auth }, .{ "APP_NATS_USER", "alice" }, .{ "APP_NATS_PASSWORD", "wrong" } },
        .expect = &.{"ERROR The server refused the user or the password user=alice\n"},
        .exit_code = 1,
    },
    .{
        .name = "zio_app",
        .run = "zio_app",
        .env = &.{ .{ "APP_NATS_URL", plain }, .{ "APP_RUN_SECONDS", "1" } },
        .expect = &.{
            "INFO  [customers] Order confirmed order_id=1\n",
            "INFO  [app] Stopping\n",
            "INFO  [events] Closed reason=drained\n",
        },
    },
};

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
    // fails, and that is fine. A run that died in the middle of the password
    // test leaves the reload server with the new password: it gets the old
    // one back.
    const unpause = b.addSystemCommand(&.{
        "sh", "-c",
        \\if docker unpause zefir-nats-e2e-stall >/dev/null 2>&1; then
        \\  i=0
        \\  while [ $i -lt 100 ] && [ "$(docker inspect --format '{{.State.Health.Status}}' zefir-nats-e2e-stall)" != healthy ]; do
        \\    sleep 0.1
        \\    i=$((i + 1))
        \\  done
        \\fi
        \\if [ "$(docker inspect --format '{{.State.Running}}' zefir-nats-e2e-reload 2>/dev/null)" = true ]; then
        \\  docker exec zefir-nats-e2e-reload cp /conf/reload.conf /tmp/nats.conf
        \\  docker kill --signal SIGHUP zefir-nats-e2e-reload >/dev/null
        \\fi
        \\true
    });
    unpause.has_side_effects = true;
    up.step.dependOn(&unpause.step);
    b.step("up", "Start the NATS servers and wait until they are healthy").dependOn(&up.step);
    const down = compose(b, compose_file, &.{"down"});
    b.step("down", "Stop the NATS servers").dependOn(&down.step);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("e2e/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nats", .module = zefir.module("zefir-nats") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });
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
    const e2e_step = b.step("e2e", "Run the end-to-end tests and the examples against the NATS servers");
    e2e_step.dependOn(&run.step);

    // The examples: `e2e` runs them after the tests, one after another;
    // `examples` and `example-<name>` run them on their own.
    const examples_step = b.step("examples", "Run the examples against the NATS servers");
    var after_tests: *std.Build.Step = &run.step;
    var after_previous: *std.Build.Step = &up.step;
    var built: std.StringHashMapUnmanaged(*std.Build.Step.Compile) = .empty;
    for (examples) |example| {
        const exe = built.get(example.name) orelse exe: {
            const exe = addExample(b, zefir, zio, example.name, target, optimize);
            built.put(b.allocator, example.name, exe) catch @panic("OOM");
            break :exe exe;
        };
        const in_e2e = runExample(b, exe, example, .check);
        in_e2e.step.dependOn(after_tests);
        after_tests = &in_e2e.step;
        e2e_step.dependOn(&in_e2e.step);

        const alone = runExample(b, exe, example, .check);
        alone.step.dependOn(after_previous);
        after_previous = &alone.step;
        examples_step.dependOn(&alone.step);
        // A run that must fail is a check only.
        if (example.exit_code != 0) continue;
        const one = runExample(b, exe, example, .show);
        one.step.dependOn(&up.step);
        b.step(b.fmt("example-{s}", .{example.run}), b.fmt("Run the {s} example against the NATS servers", .{example.run})).dependOn(&one.step);
    }

    // The benchmark: `bench` runs it, built with ReleaseFast unless
    // -Dbench-optimize says otherwise; `e2e` builds it with ReleaseFast
    // without running it, so that CI knows it compiles.
    const bench_optimize = b.option(std.lang.Optimize, "bench-optimize", "The mode of the benchmark (default: ReleaseFast)") orelse .fast;
    const run_bench = b.addRunArtifact(addBench(b, target, bench_optimize));
    run_bench.stdio = .inherit;
    run_bench.step.dependOn(&up.step);
    b.step("bench", "Run the benchmark against the NATS servers").dependOn(&run_bench.step);
    const fast_bench = addBench(b, target, .fast);
    // Code generation too, not only analysis: the binary is asked for.
    _ = fast_bench.getEmittedBin();
    e2e_step.dependOn(&fast_bench.step);

    // The stress tests, in Debug and then in ReleaseSafe whatever
    // -Doptimize says: each mode gets zefir and zio built in it.
    const stress_step = b.step("stress", "Run the stress tests against the NATS servers, in Debug and in ReleaseSafe");
    var after_mode: *std.Build.Step = &up.step;
    for ([_]std.lang.Optimize{ .debug, .safe }) |mode| {
        const mode_zefir = b.dependency("zefir", .{ .target = target, .optimize = mode });
        const mode_zio = b.dependency("zio", .{ .target = target, .optimize = mode });
        const imports: []const std.Build.Module.Import = &.{
            .{ .name = "nats", .module = mode_zefir.module("zefir-nats") },
            .{ .name = "zio", .module = mode_zio.module("zio") },
        };
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
                    .{ .name = "e2e", .module = helpers },
                },
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const run_stress = b.addRunArtifact(stress);
        run_stress.stdio = .inherit;
        // One mode after the other: they share the servers and the CPU.
        run_stress.step.dependOn(after_mode);
        after_mode = &run_stress.step;
        stress_step.dependOn(&run_stress.step);
    }
}

/// The benchmark, with zefir and zio built in `mode` too.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget, mode: std.lang.Optimize) *std.Build.Step.Compile {
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = mode });
    const zio = b.dependency("zio", .{ .target = target, .optimize = mode });
    return b.addExecutable(.{
        .name = b.fmt("bench-{t}", .{mode}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nats", .module = zefir.module("zefir-nats") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
}

/// The example `name` of src/nats/examples, built with a root that exits
/// with code 3 on a panic instead of aborting.
fn addExample(
    b: *std.Build,
    zefir: *std.Build.Dependency,
    zio: *std.Build.Dependency,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const example = b.createModule(.{
        .root_source_file = zefir.path(b.fmt("src/nats/examples/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nats", .module = zefir.module("zefir-nats") },
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            .{ .name = "log", .module = zefir.module("zefir-log") },
            .{ .name = "core", .module = zefir.module("zefir-core") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("example_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "example", .module = example }},
        }),
    });
}

/// A run of `exe` with the settings of `example`: `.check` checks what it
/// prints, `.show` prints it.
fn runExample(b: *std.Build, exe: *std.Build.Step.Compile, example: Example, output: enum { check, show }) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    // The servers are outside the build graph: run every time.
    run.has_side_effects = true;
    for (example.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
    switch (output) {
        .check => {
            for (example.expect) |line| run.expectStdOutMatch(line);
            run.expectExitCode(example.exit_code);
        },
        .show => run.stdio = .inherit,
    }
    return run;
}

fn compose(b: *std.Build, file: std.Build.LazyPath, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "docker", "compose", "--file" });
    run.addFileArg(file);
    run.addArgs(args);
    run.has_side_effects = true;
    return run;
}
