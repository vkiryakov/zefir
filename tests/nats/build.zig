//! The end-to-end tests, examples, stress tests and benchmark of
//! zefir-nats against real NATS servers, on zio, and the check that the
//! guide, src/nats/examples/README.md, and "nats in a minute" of the
//! repository's README.md show the runs of their programs as they
//! printed. The servers are those of docker-compose.yml at the repository
//! root.
//!
//!   zig build e2e              start the servers, run the tests and the
//!                              examples, then the runs of the guide and
//!                              its check
//!   zig build examples         start the servers, run the examples
//!   zig build example-<name>   start the servers, run one example, such as
//!                              example-pub_sub
//!   zig build stress           start the servers, run the stress tests in
//!                              Debug and in ReleaseSafe; see below for what
//!                              they need
//!   zig build bench            start the servers, run the benchmark,
//!                              built with ReleaseFast unless
//!                              -Dbench-optimize says otherwise
//!   zig build check            build the tests, the examples and the
//!                              benchmark without running them (not the
//!                              check of the guide, which embeds what the
//!                              runs print); no servers needed, so CI runs
//!                              it on every system
//!   zig build up               only start the servers
//!   zig build down             stop the servers; it also resets them after a run
//!                              that died while a test held one paused

const std = @import("std");

/// A run of an example of src/nats/examples, and what it must print.
const Example = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The name of the run: `zig build example-<run>` shows it, unless it
    /// must fail, which only `e2e` and `examples` check.
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

/// A run of a program of src/nats/examples that the guide, or README.md of
/// the repository, shows as it printed: guide_test.zig checks it.
const GuideRun = struct {
    /// The file, without `.zig`.
    program: []const u8,
    /// The name of the run: what it printed goes to the check as
    /// `<name>.out`.
    name: []const u8,
    /// The settings of its run here, against the servers of
    /// docker-compose.yml.
    env: []const [2][]const u8,
    /// The run as the document shows it: what a reader types, against a
    /// server of their own.
    command: []const u8,
    /// Where it prints what the document shows: the records of zefir-log
    /// go to stdout, those of std.log, confy's report of the settings
    /// among them, to stderr.
    output: enum { stdout, stderr } = .stdout,
    exit_code: u8 = 0,
    /// The document that shows it: `guide` or `root_readme`.
    doc: []const u8 = "guide",
};

/// The runs, in the order of the documents: the programs of `root_readme`
/// and `server_programs` of src/nats/examples/cases.zig, which
/// guide_test.zig checks.
const guide_runs = [_]GuideRun{
    .{ .program = "minute", .name = "minute", .env = &.{.{ "APP_NATS_URL", plain }}, .command = "$ zig build run", .output = .stderr, .doc = "root_readme" },
    .{ .program = "pub_sub", .name = "pub_sub", .env = &.{.{ "APP_NATS_URL", plain }}, .command = "$ zig build run" },
    .{ .program = "request_reply", .name = "request_reply", .env = &.{.{ "APP_NATS_URL", plain }}, .command = "$ zig build run" },
    .{ .program = "scatter_gather", .name = "scatter_gather", .env = &.{.{ "APP_NATS_URL", plain }}, .command = "$ zig build run" },
    .{
        .program = "user_password_auth",
        .name = "user_password_auth",
        .env = &.{ .{ "APP_NATS_URL", auth }, .{ "APP_NATS_USER", "alice" }, .{ "APP_NATS_PASSWORD", "secret" } },
        .command = "$ APP_NATS_URL=" ++ auth ++ " APP_NATS_USER=alice APP_NATS_PASSWORD=secret zig build run",
    },
    .{
        .program = "user_password_auth",
        .name = "user_password_auth-refused",
        .env = &.{ .{ "APP_NATS_URL", auth }, .{ "APP_NATS_USER", "alice" }, .{ "APP_NATS_PASSWORD", "wrong" } },
        .command = "$ APP_NATS_URL=" ++ auth ++ " APP_NATS_USER=alice APP_NATS_PASSWORD=wrong zig build run",
        .exit_code = 1,
    },
    .{
        .program = "user_password_auth",
        .name = "user_password_auth-missing",
        .env = &.{ .{ "APP_NATS_URL", auth }, .{ "APP_NATS_USER", "alice" } },
        .command = "$ APP_NATS_URL=" ++ auth ++ " APP_NATS_USER=alice zig build run",
        .output = .stderr,
        .exit_code = 1,
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

    // The runs that the guide and the repository's README.md show: `e2e`
    // runs them after the examples, one after another, and what each
    // prints goes to the check of the guide, which runs last.
    const guide = addGuideCheck(b, zefir, target, optimize);
    var embedded: std.StringHashMapUnmanaged(void) = .empty;
    for (guide_runs) |guide_run| {
        const exe = built.get(guide_run.program) orelse exe: {
            const exe = addExample(b, zefir, zio, guide_run.program, target, optimize);
            built.put(b.allocator, guide_run.program, exe) catch @panic("OOM");
            break :exe exe;
        };
        const checked = b.addRunArtifact(exe);
        // The servers are outside the build graph: run every time.
        checked.has_side_effects = true;
        for (guide_run.env) |pair| checked.setEnvironmentVariable(pair[0], pair[1]);
        checked.expectExitCode(guide_run.exit_code);
        checked.step.dependOn(&up.step);
        checked.step.dependOn(after_tests);
        after_tests = &checked.step;
        // A run with side effects keeps what it printed in a directory
        // named by its arguments, its environment and this name, and runs
        // may share their environment: the name keeps them apart.
        const basename = b.fmt("{s}.out", .{guide_run.name});
        const out = switch (guide_run.output) {
            .stdout => checked.captureStdOut(.{ .basename = basename }),
            .stderr => checked.captureStdErr(.{ .basename = basename }),
        };
        guide.root_module.addAnonymousImport(basename, .{ .root_source_file = out });
        if (embedded.contains(guide_run.program)) continue;
        embedded.put(b.allocator, guide_run.program, {}) catch @panic("OOM");
        guide.root_module.addAnonymousImport(b.fmt("{s}.zig", .{guide_run.program}), .{
            .root_source_file = zefir.path(b.fmt("src/nats/examples/{s}.zig", .{guide_run.program})),
        });
    }
    const run_guide = b.addRunArtifact(guide);
    run_guide.stdio = .inherit;
    run_guide.has_side_effects = true;
    run_guide.step.dependOn(after_tests);
    e2e_step.dependOn(&run_guide.step);

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
    // -Doptimize says: each mode gets zefir and zio built in it. They need
    // room: 50,000 zio tasks at once take about 1.7 GB of memory in Debug
    // and 0.8 GB in ReleaseSafe, and their stacks about 100,000 memory
    // mappings, more than the 65,530 Linux allows a process by default:
    // raise it first, `sudo sysctl vm.max_map_count=262144`.
    const stress_step = b.step("stress", "Run the stress tests against the NATS servers, in Debug and in ReleaseSafe");
    // One mode after the other, as they share the servers and the CPU, and
    // ReleaseSafe runs even when Debug fails.
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
    var stress_builds: [2]*std.Build.Step.Compile = undefined;
    for ([_]std.lang.Optimize{ .debug, .safe }, &stress_builds) |mode, *build_of_mode| {
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
        run_stress.addArtifactArg(stress);
        build_of_mode.* = stress;
    }

    // Everything above built and nothing run: no servers needed.
    const check_step = b.step("check", "Build the tests, the examples and the benchmark without running them");
    check_step.dependOn(&e2e.step);
    var built_examples = built.valueIterator();
    while (built_examples.next()) |exe| check_step.dependOn(&exe.*.step);
    for (stress_builds) |stress| check_step.dependOn(&stress.step);
    check_step.dependOn(&fast_bench.step);
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
/// with code 3 on a panic instead of aborting, and with code 4 after 120 s.
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

/// The check of the guide, guide_test.zig, without what the runs printed:
/// the caller embeds each program as `<program>.zig` and what each run
/// printed as `<name>.out`.
fn addGuideCheck(b: *std.Build, zefir: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const options = b.addOptions();
    var programs: [guide_runs.len][]const u8 = undefined;
    var names: [guide_runs.len][]const u8 = undefined;
    var commands: [guide_runs.len][]const u8 = undefined;
    var docs: [guide_runs.len][]const u8 = undefined;
    for (guide_runs, &programs, &names, &commands, &docs) |guide_run, *program, *name, *command, *doc| {
        program.* = guide_run.program;
        name.* = guide_run.name;
        command.* = guide_run.command;
        doc.* = guide_run.doc;
    }
    options.addOption([]const []const u8, "programs", &programs);
    options.addOption([]const []const u8, "names", &names);
    options.addOption([]const []const u8, "commands", &commands);
    options.addOption([]const []const u8, "docs", &docs);
    const guide = b.addTest(.{
        .name = "guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guide_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guide-check", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/nats/examples/guide_check.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "cases", .module = b.createModule(.{
                    .root_source_file = zefir.path("src/nats/examples/cases.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "guide_runs", .module = options.createModule() },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    guide.root_module.addAnonymousImport("guide", .{ .root_source_file = zefir.path("src/nats/examples/README.md") });
    guide.root_module.addAnonymousImport("root_readme", .{ .root_source_file = zefir.path("README.md") });
    return guide;
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
