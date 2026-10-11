const std = @import("std");
const validator_cases = @import("src/validator/testdata/cases.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Framework modules. Public names ("zefir-*") are used by consumers
    // via dep.module("..."); internal names in .imports via @import("...").

    const core = b.addModule("zefir-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const logger = b.addModule("zefir-logger", .{
        .root_source_file = b.path("src/logger/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const confy = b.addModule("zefir-confy", .{
        .root_source_file = b.path("src/confy/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "logger", .module = logger },
        },
    });

    const validator = b.addModule("zefir-validator", .{
        .root_source_file = b.path("src/validator/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rpc = b.addModule("zefir-rpc", .{
        .root_source_file = b.path("src/rpc/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "logger", .module = logger },
            .{ .name = "confy", .module = confy },
        },
    });

    const orm = b.addModule("zefir-orm", .{
        .root_source_file = b.path("src/orm/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "logger", .module = logger },
        },
    });

    // Umbrella module: @import("zefir").core, .logger, .confy, .validator, .rpc, .orm
    const zefir = b.addModule("zefir", .{
        .root_source_file = b.path("src/zefir.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "logger", .module = logger },
            .{ .name = "confy", .module = confy },
            .{ .name = "validator", .module = validator },
            .{ .name = "rpc", .module = rpc },
            .{ .name = "orm", .module = orm },
        },
    });

    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ core, logger, confy, validator, rpc, orm, zefir }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    addValidatorTests(b, test_step, validator, target, optimize);

    // core examples: `zig build test` builds and runs them; an example that
    // exits with an error fails the step.
    for ([_][]const u8{ "http_handler", "rpc_handler", "services" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/core/examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "core", .module = core },
                },
            }),
        });
        const run = b.addRunArtifact(example);
        run.expectExitCode(0);
        test_step.dependOn(&run.step);
    }

    // core benchmarks: `zig build test` only compiles them, `zig build bench`
    // runs them. They get their own ReleaseFast copy of core, since the
    // `core` module above is built in the mode the user asked for.
    const bench = b.addExecutable(.{
        .name = "core-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "core", .module = b.createModule(.{
                    .root_source_file = b.path("src/core/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                }) },
            },
        }),
    });
    test_step.dependOn(&bench.step);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);
}

/// The validator tests that use only its public API, compiled as client code
/// from the lists in src/validator/testdata/cases.zig.
fn addValidatorTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    validator: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const vtest = b.createModule(.{
        .root_source_file = b.path("src/validator/testdata/helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "validator", .module = validator }},
    });
    for (validator_cases.test_files) |file| {
        const tests = b.addTest(.{
            .name = std.fs.path.stem(file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "validator", .module = validator },
                    .{ .name = "vtest", .module = vtest },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // Compile-error fixtures: each one is compiled (never run) and passes only
    // when the compilation fails with an error line that ends in `expect`.
    for (validator_cases.compile_errors) |fixture| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(fixture.file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(fixture.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "validator", .module = validator }},
            }),
        });
        t.expect_errors = .{ .contains = fixture.expect };
        test_step.dependOn(&t.step);
    }

    // A malformed validateSelf result is reported as validation.invalid
    // outside Debug. These files get their own ReleaseSafe copy of the
    // module, whatever -Doptimize says.
    const validator_safe = b.createModule(.{
        .root_source_file = b.path("src/validator/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    for (validator_cases.release_test_files) |file| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "validator", .module = validator_safe }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // In Debug, a malformed validateSelf result panics: each program must
    // print the panic message and end in its own panic handler, which exits
    // with code 3 instead of aborting (see the programs in panic/).
    const validator_debug = b.createModule(.{
        .root_source_file = b.path("src/validator/root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    for (validator_cases.panic_runs) |entry| {
        const exe = b.addExecutable(.{
            .name = std.fs.path.stem(entry.file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry.file),
                .target = target,
                .optimize = .Debug,
                .imports = &.{.{ .name = "validator", .module = validator_debug }},
            }),
        });
        const run = b.addRunArtifact(exe);
        run.expectStdErrMatch(entry.stderr);
        // expectStdErrMatch accepts any exit: only the panic handler exits
        // with 3, so a program that printed the text and returned fails.
        run.expectExitCode(3);
        test_step.dependOn(&run.step);
    }

    // Golden vectors: vector_gen turns each JSON file of `vector_files` into
    // a test file in the build cache, one test per record. It is built for
    // the host, so it also runs when -Dtarget names another system.
    const gen_module = b.createModule(.{
        .root_source_file = b.path("src/validator/testdata/vector_gen.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gen = b.addExecutable(.{ .name = "vector_gen", .root_module = gen_module });
    const gen_tests = b.addTest(.{ .name = "vector_gen", .root_module = gen_module });
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);
    const harness = b.createModule(.{
        .root_source_file = b.path("src/validator/testdata/vector_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "validator", .module = validator }},
    });
    const harness_tests = b.addTest(.{ .name = "vector_harness", .root_module = harness });
    test_step.dependOn(&b.addRunArtifact(harness_tests).step);
    for (validator_cases.vector_files) |name| {
        const run_gen = b.addRunArtifact(gen);
        run_gen.addFileArg(b.path(b.fmt("src/validator/testdata/vectors/{s}.json", .{name})));
        const generated = run_gen.addOutputFileArg(b.fmt("{s}_vectors_test.zig", .{name}));
        const vector_tests = b.addTest(.{
            .name = b.fmt("{s}_vectors", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = generated,
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "validator", .module = validator },
                    .{ .name = "harness", .module = harness },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(vector_tests).step);
    }

    // The examples of src/validator/examples/README.md: a program must print
    // exactly its `stdout`, a test must pass, and readme_test.zig checks that
    // README.md shows every example and output verbatim.
    for (validator_cases.examples) |example| {
        const example_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/validator/examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "validator", .module = validator }},
        });
        if (example.stdout) |stdout| {
            const example_run = b.addRunArtifact(b.addExecutable(.{ .name = example.name, .root_module = example_module }));
            example_run.expectStdOutEqual(stdout);
            test_step.dependOn(&example_run.step);
        } else {
            const example_test = b.addTest(.{ .name = example.name, .root_module = example_module });
            test_step.dependOn(&b.addRunArtifact(example_test).step);
        }
    }
    const readme_test = b.addTest(.{
        .name = "readme_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/validator/examples/readme_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cases", .module = b.createModule(.{
                .root_source_file = b.path("src/validator/testdata/cases.zig"),
                .target = target,
                .optimize = optimize,
            }) }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(readme_test).step);
}
