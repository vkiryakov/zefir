const std = @import("std");
const validator_cases = @import("src/validator/testdata/cases.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // `-Dtsan=true` builds the modules, tests and examples with
    // ThreadSanitizer (Linux and macOS); the CI job `tsan` runs the tests so.
    const tsan = b.option(bool, "tsan", "Build with ThreadSanitizer") orelse false;

    // Framework modules. Public names ("zefir-*") are used by consumers
    // via dep.module("..."); internal names in .imports via @import("...").

    const core = b.addModule("zefir-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
    });

    const log = b.addModule("zefir-log", .{
        .root_source_file = b.path("src/log/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });

    const confy = b.addModule("zefir-confy", .{
        .root_source_file = b.path("src/confy/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "log", .module = log },
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
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "validator", .module = validator },
        },
    });

    const orm = b.addModule("zefir-orm", .{
        .root_source_file = b.path("src/orm/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "log", .module = log },
        },
    });

    // Umbrella module: @import("zefir").core, .log, .confy, .validator, .rpc, .orm
    const zefir = b.addModule("zefir", .{
        .root_source_file = b.path("src/zefir.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "log", .module = log },
            .{ .name = "confy", .module = confy },
            .{ .name = "validator", .module = validator },
            .{ .name = "rpc", .module = rpc },
            .{ .name = "orm", .module = orm },
        },
    });

    const test_step = b.step("test", "Run all tests");
    // `zig build test-<name>` runs the part of `zig build test` that checks
    // one module: its tests and, further down, its examples, panic programs,
    // compile-error checks and benchmark builds. CI runs only the steps of
    // the modules a change affects; see .github/scripts/affected-modules.sh.
    const test_core = addModuleTestStep(b, test_step, "core");
    const test_log = addModuleTestStep(b, test_step, "log");
    const test_confy = addModuleTestStep(b, test_step, "confy");
    const test_validator = addModuleTestStep(b, test_step, "validator");
    const test_rpc = addModuleTestStep(b, test_step, "rpc");
    const test_orm = addModuleTestStep(b, test_step, "orm");
    const test_zefir = addModuleTestStep(b, test_step, "zefir");
    // Builds the validator's test binaries without running them, so that
    // `-Dtarget` may name another system: CI builds them for x86-linux-musl,
    // where usize has 32 bits.
    const validator_compile_step = b.step("compile-validator-tests", "Build the validator's test binaries for -Dtarget without running them");
    for (
        [_]*std.Build.Module{ core, log, confy, validator, rpc, orm, zefir },
        [_]*std.Build.Step{ test_core, test_log, test_confy, test_validator, test_rpc, test_orm, test_zefir },
    ) |module, module_test_step| {
        const tests = b.addTest(.{ .root_module = module });
        module_test_step.dependOn(&addRun(b, tests, tsan).step);
        if (module == validator) validator_compile_step.dependOn(&tests.step);
    }

    addValidatorTests(b, test_validator, validator_compile_step, validator, log, target, optimize, tsan);

    // core examples: `zig build test` builds and runs them; an example that
    // exits with an error fails the step.
    for ([_][]const u8{ "http_handler", "rpc_handler", "services" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/core/examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .imports = &.{
                    .{ .name = "core", .module = core },
                },
            }),
        });
        const run = addRun(b, example, tsan);
        run.expectExitCode(0);
        test_core.dependOn(&run.step);
    }

    // log examples: `zig build test` builds and runs them, like the core ones.
    for ([_][]const u8{ "service", "config", "alerts" }) |name| {
        const example = b.addExecutable(.{
            .name = b.fmt("log-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/log/examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .imports = &.{
                    .{ .name = "core", .module = core },
                    .{ .name = "log", .module = log },
                },
            }),
        });
        const run = addRun(b, example, tsan);
        run.expectExitCode(0);
        test_log.dependOn(&run.step);
    }

    // log panic programs: `flush`, `shutdown` or `unsubscribe` called from a
    // handler or the writer thread panics in safe builds. Each program must
    // print the panic message and end in its own panic handler, which exits
    // with code 3 instead of aborting (see the programs in
    // src/log/tests/panic/). They get their own Debug copies of log and
    // core, whatever -Doptimize says.
    const panic_core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const panic_log = b.createModule(.{
        .root_source_file = b.path("src/log/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "core", .module = panic_core },
        },
    });
    const flush_refused = "zefir.log: flush or shutdown called from one of the logger's threads could wait for itself";
    const unsubscribe_refused = "zefir.log: unsubscribe called from one of the logger's threads could wait for itself";
    for ([_][2][]const u8{
        .{ "handler_flush", flush_refused },
        .{ "handler_shutdown", flush_refused },
        .{ "handler_unsubscribe", unsubscribe_refused },
        .{ "writer_flush", flush_refused },
        .{ "writer_unsubscribe", unsubscribe_refused },
    }) |case| {
        const exe = b.addExecutable(.{
            .name = b.fmt("log-panic-{s}", .{case[0]}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/log/tests/panic/{s}.zig", .{case[0]})),
                .target = target,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "log", .module = panic_log },
                },
            }),
        });
        const run = b.addRunArtifact(exe);
        run.expectStdErrMatch(case[1]);
        // expectStdErrMatch accepts any exit: only the panic handler exits
        // with 3, so a program that printed the text and returned fails.
        run.expectExitCode(3);
        test_log.dependOn(&run.step);
    }

    // log compile errors: each test of the file must fail to compile with
    // the message next to its name. The filter compiles one test at a time;
    // the message must be the end of an error line.
    const log_compile_errors = b.createModule(.{
        .root_source_file = b.path("src/log/tests/compile_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "log", .module = log },
        },
    });
    for ([_][2][]const u8{
        .{ "fields that are not a struct", "zefir.log: fields must be a struct literal such as .{ .user_id = id }, got 'comptime_int'" },
        .{ "positional fields", "zefir.log: fields need names: write .{ .user_id = id }, not .{ id }" },
        .{ "reserved field name", "zefir.log: field name 'level' is reserved for record metadata; rename it, e.g. 'user_level'" },
        .{ "dotted service field", "zefir.log: field name 'service.name' is reserved for record metadata; rename it, e.g. 'user_service.name'" },
        .{ "subfield of the source object", "zefir.log: field name 'source.file' is reserved for record metadata; rename it, e.g. 'user_source.file'" },
        .{ "field name with a space", "zefir.log: field name 'user id' may contain only [A-Za-z0-9_.-]" },
        .{ "src of the wrong type", "zefir.log: field 'src' is the call site and must be a std.lang.SourceLocation; pass .src = @src()" },
        .{ "error union value", "zefir.log: field 'value': cannot log error union 'anyerror!u8'; handle it with try or catch first, then log the payload or the error" },
        .{ "void value", "zefir.log: field 'nothing': cannot log 'void'; remove the field" },
        .{ "undefined value", "zefir.log: field 'x' is undefined; give it a value" },
        // Type names depend on the file, so these check only the end of the line.
        .{ "untagged union", "': its active field is unknown; use union(enum) or log one of its fields" },
        .{ "many-item pointer to u8", "zefir.log: field 'p': cannot log many-item pointer '[*]const u8': it has no length; log a slice, ptr[0..len]" },
        .{ "C pointer", "zefir.log: field 'p': cannot log C pointer '[*c]const u8'; convert it to a slice or log the address as an integer" },
        .{ "pointer to an opaque type", "zefir.log: field 'p': cannot log '*anyopaque': an opaque type has no value to log" },
        .{ "function pointer", "zefir.log: field 'f': cannot log function '*const fn () void'" },
        .{ "reserved name on the flat path through a struct", "zefir.log: field 'service.name' is reserved for record metadata; rename 'service', e.g. 'user_service'" },
        .{ "nested name with a space", "zefir.log: field name 's.a b' may contain only [A-Za-z0-9_.-]" },
        .{ "nested error union", "zefir.log: field 'cfg.r': cannot log error union 'anyerror!u8'; handle it with try or catch first, then log the payload or the error" },
        .{ "sensitive marker of the wrong type", ".zefir_sensitive' must be a bool: pub const zefir_sensitive = true;" },
        .{ "logValue that returns its own type", "' itself; return another type, such as a struct of the fields to log" },
        .{ "sensitive type as the fields", "' is sensitive and cannot be the fields; log it as one field: .{ .key = key }" },
        .{ "type with its own logged form as the fields", "' has its own logged form; log it as one field: .{ .value = value }" },
        .{ "format of another form", ".format' has another form than the one {f} uses; write pub fn format(self: @This(), w: *std.Io.Writer) !void" },
        .{ "logValue with a mutable self", ".logValue' has another form; write pub fn logValue(self: @This()) U, taking self by value or by *const" },
        .{ "logValue that returns an error union", ".logValue' returns an error union; return a value, since logging cannot fail" },
        .{ "reserved name on the flat path through an array", "zefir.log: field 'service[].name' is reserved for record metadata; rename 'service', e.g. 'user_service'" },
        .{ "subfield of the call site", "zefir.log: field name 'src.function' is reserved for record metadata; rename it, e.g. 'user_src.function'" },
        .{ "function value", "zefir.log: field 'f': cannot log function 'fn () void'" },
        .{ "many-item pointer to u16 with a sentinel", "zefir.log: field 'p': cannot log many-item pointer '[*:0]const u16': it has no length; log a slice, ptr[0..len]" },
        .{ "packed union", "': its active field is unknown; use union(enum) or log one of its fields" },
        .{ "optional void", "zefir.log: field 'x': cannot log 'void'; remove the field" },
        .{ "context as a field", "zefir.log: field 'ctx': bind a core.Context with logger.withContext(ctx), not as a field" },
        .{ "context as the fields", "zefir.log: a core.Context is not the fields; bind it with logger.withContext(ctx)" },
        .{ "context inside a field", "zefir.log: field 'request.ctx': bind a core.Context with logger.withContext(ctx), not as a field" },
        .{ "call site under the name source", "zefir.log: field name 'source' is reserved for record metadata; the call site goes in .src = @src()" },
        .{ "logValue without self", ".logValue' has another form; write pub fn logValue(self: @This()) U, taking self by value or by *const" },
        .{ "format with a foreign self", ".format' has another form than the one {f} uses; write pub fn format(self: @This(), w: *std.Io.Writer) !void" },
        .{ "format that can return another error", ".format' can return error.TooBig; {f} lets it return only std.Io.Writer.Error" },
        .{ "format that returns anyerror", ".format' returns anyerror; {f} lets it return only std.Io.Writer.Error" },
        .{ "format that returns void", ".format' returns void; write pub fn format(self: @This(), w: *std.Io.Writer) !void" },
        .{ "format of an opaque type with a mutable self", ".format' has another form than the one {f} uses; write pub fn format(self: *const @This(), w: *std.Io.Writer) !void" },
        // A type declared in a test is named after the file and the test, so
        // these can name it in full.
        .{ "a format error names the nested field", "zefir.log: field 'req.x': 'compile_errors.test.a format error names the nested field.Other.format' has another form than the one {f} uses; write pub fn format(self: @This(), w: *std.Io.Writer) !void" },
        .{ "a logValue error names the nested field", "zefir.log: field 'req.m': 'compile_errors.test.a logValue error names the nested field.Mutable.logValue' has another form; write pub fn logValue(self: @This()) U, taking self by value or by *const" },
        .{ "a marker error names the nested field", "zefir.log: field 'req.k': 'compile_errors.test.a marker error names the nested field.Key.zefir_sensitive' must be a bool: pub const zefir_sensitive = true;" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("log-compile-error-{d}", .{i}),
            .root_module = log_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .contains = case[1] };
        test_log.dependOn(&compile.step);
    }

    // rpc compile errors: transports whose methods do not fit the
    // interfaces. Each test must fail with exactly one error, the message
    // next to its name, and its note "called at comptime here" that points
    // at the check in rpc: the check stops the build before Zig reports
    // anything inside rpc. A type declared in a test is named after the file
    // and the test.
    const rpc_compile_errors = b.createModule(.{
        .root_source_file = b.path("src/rpc/tests/compile_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "rpc", .module = rpc },
        },
    });
    const call_signature = "pub fn call(self: *@This(), io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response";
    const authenticate_signature = "pub fn authenticate(self: *@This(), ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView";
    const run_signature = "pub fn run(self: *@This(), ctx: *rpc.Context, next: *rpc.Next) anyerror!void";
    for ([_][2][]const u8{
        .{ "client transport without call", "rpc.ClientTransport.init: compile_errors.test.client transport without call.NoCall has no method call; expected " ++ call_signature },
        .{ "call with another response type", "rpc.ClientTransport.init: compile_errors.test.call with another response type.WrongResponse.call has another signature; expected " ++ call_signature },
        .{ "client transport without info", "rpc.ClientTransport.init: compile_errors.test.client transport without info.NoInfo has no method info; expected pub fn info(self: *@This()) rpc.transport.Info" },
        .{ "server transport without drain", "rpc.ServerTransport.init: compile_errors.test.server transport without drain.NoDrain has no method drain; expected pub fn drain(self: *@This(), io: std.Io) void" },
        .{ "isReady with another signature", "rpc.ServerTransport.init: compile_errors.test.isReady with another signature.ReadyWithIo.isReady has another signature; expected pub fn isReady(self: *@This()) bool" },
        .{ "release with another signature", "rpc.transport.Reply.init: compile_errors.test.release with another signature.ReleaseWithoutDisposition.release has another signature; expected pub fn release(self: *@This(), io: std.Io, disposition: rpc.transport.Reply.Disposition) void" },
        .{ "init with a value", "rpc.ClientTransport.init: pass a pointer to the transport, e.g. &transport; got compile_errors.Echo" },
        .{ "init with a pointer to a constant", "rpc.ClientTransport.init: the transport must be mutable, declared with var; got *const compile_errors.Echo" },
        .{ "init with a pointer to a number", "rpc.ServerTransport.init: pass a pointer to the transport, e.g. &transport; got *u8" },
        .{ "authenticator without authenticate", "rpc.Authenticator.init: compile_errors.test.authenticator without authenticate.NoAuthenticate has no method authenticate; expected " ++ authenticate_signature },
        .{ "authenticate with an inferred error set", "rpc.Authenticator.init: compile_errors.test.authenticate with an inferred error set.Inferred.authenticate has another signature; expected " ++ authenticate_signature },
        .{ "middleware object without run", "rpc.Middleware.of: compile_errors.test.middleware object without run.NoRun has no method run; expected " ++ run_signature },
        .{ "middleware object by value", "rpc.Middleware.of: expected fn (ctx: *rpc.Context, next: *rpc.Next) anyerror!void, or a pointer to a type with " ++ run_signature ++ "; got compile_errors.Counter" },
        .{ "middleware run with an inferred error set", "rpc.Middleware.of: compile_errors.test.middleware run with an inferred error set.Inferred.run has another signature; expected " ++ run_signature },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("rpc-compile-error-{d}", .{i}),
            .root_module = rpc_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .exact = b.allocator.dupe([]const u8, &.{ case[1], "note: called at comptime here" }) catch @panic("OOM") };
        test_rpc.dependOn(&compile.step);
    }

    // rpc panic programs: a transport that breaks the rules of
    // rpc.transport.Pending gets a panic that names the rule. The program
    // runs once per case and, like the log ones, ends in its own panic
    // handler with code 3; it gets Debug copies of rpc and its imports.
    const panic_rpc = b.createModule(.{
        .root_source_file = b.path("src/rpc/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "core", .module = panic_core },
            .{ .name = "validator", .module = b.createModule(.{
                .root_source_file = b.path("src/validator/root.zig"),
                .target = target,
                .optimize = .Debug,
            }) },
        },
    });
    const pending_panics = b.addExecutable(.{
        .name = "rpc-panic-pending",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc/tests/panic/pending.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = panic_core },
                .{ .name = "rpc", .module = panic_rpc },
            },
        }),
    });
    for ([_][2][]const u8{
        .{ "release_twice", "rpc.transport.Pending: release of a slot that is not acquired; release each slot once" },
        .{ "wait_after_release", "rpc.transport.Pending: wait on a slot that is not acquired; wait before release" },
        .{ "wait_twice", "rpc.transport.Pending: wait called twice for one slot" },
        .{ "deinit_in_use", "rpc.transport.Pending: deinit with slots still acquired; release every slot first" },
    }) |case| {
        const run = b.addRunArtifact(pending_panics);
        run.addArg(case[0]);
        run.expectStdErrMatch(case[1]);
        // expectStdErrMatch accepts any exit: only the panic handler exits
        // with 3, so a program that printed the text and returned fails.
        run.expectExitCode(3);
        test_rpc.dependOn(&run.step);
    }

    // The same for an engine that breaks the rules of rpc.transport.Reply
    // on rpc.testing.MemoryTransport.
    const memory_panics = b.addExecutable(.{
        .name = "rpc-panic-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc/tests/panic/memory.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = panic_core },
                .{ .name = "rpc", .module = panic_rpc },
            },
        }),
    });
    for ([_][2][]const u8{
        .{ "release_twice", "rpc.testing.MemoryTransport: release called twice for one call; release each call once" },
        .{ "release_twice_after_return", "rpc.testing.MemoryTransport: release called twice for one call; release each call once" },
        .{ "send_twice", "rpc.testing.MemoryTransport: send called again for one call; send at most once, or once more after ResponseTooLarge" },
        .{ "send_after_release", "rpc.testing.MemoryTransport: send called after release; release is the last call of a Reply" },
        .{ "release_after_failed_start", "rpc.testing.MemoryTransport: Reply called after start returned a failure; no Reply call follows a failed start" },
        .{ "another_io", "rpc.testing.MemoryTransport: call with another std.Io than the server's; pass the io the server started on" },
        .{ "deinit_in_use", "rpc.testing.MemoryTransport: deinit with calls not released; deinit the server and let every call return first" },
    }) |case| {
        const run = b.addRunArtifact(memory_panics);
        run.addArg(case[0]);
        run.expectStdErrMatch(case[1]);
        run.expectExitCode(3);
        test_rpc.dependOn(&run.step);
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
    test_core.dependOn(&bench.step);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // log benchmarks, the same way: ReleaseFast copies of log and core.
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const log_bench = b.addExecutable(.{
        .name = "log-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/log/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "core", .module = bench_core },
                .{ .name = "log", .module = b.createModule(.{
                    .root_source_file = b.path("src/log/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{
                        .{ .name = "core", .module = bench_core },
                    },
                }) },
            },
        }),
    });
    test_log.dependOn(&log_bench.step);
    bench_step.dependOn(&b.addRunArtifact(log_bench).step);
}

/// Adds the step `test-<name>` for the checks of one module and makes
/// `test_step` depend on it.
fn addModuleTestStep(b: *std.Build, test_step: *std.Build.Step, name: []const u8) *std.Build.Step {
    const step = b.step(b.fmt("test-{s}", .{name}), b.fmt("Run the tests of the {s} module", .{name}));
    test_step.dependOn(step);
    return step;
}

/// Runs `artifact`. Under ThreadSanitizer the first report fails the run at
/// once, with an exit code rather than an abort and its crash report.
fn addRun(b: *std.Build, artifact: *std.Build.Step.Compile, tsan: bool) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    if (tsan) run.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1:abort_on_error=0");
    return run;
}

/// The validator tests that use only its public API, compiled as client code
/// from the lists in src/validator/testdata/cases.zig. `test_step` runs them
/// and checks the compile-error fixtures; `compile_step` only builds the test
/// binaries for `target`. `log` is for the examples of the guide, which log
/// the violations they find; the validator itself imports nothing.
fn addValidatorTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    compile_step: *std.Build.Step,
    validator: *std.Build.Module,
    log: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    tsan: bool,
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
        compile_step.dependOn(&tests.step);
    }

    // Compile-error fixtures: each one is compiled (never run) and passes only
    // when the compilation fails with an error whose message is `expect`.
    // `.contains` matches the end of an error line, so `error: ` in front
    // makes `expect` the whole message, from its start.
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
        t.expect_errors = .{ .contains = b.fmt("error: {s}", .{fixture.expect}) };
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
        compile_step.dependOn(&t.step);
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
        compile_step.dependOn(&exe.step);
    }

    // Golden vectors: vector_gen turns each JSON file of `vector_files` into
    // a test file in the build cache, one test per record, and checks it
    // against the rules of its entry. It is built for the host, so it also
    // runs when -Dtarget names another system.
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
    compile_step.dependOn(&harness_tests.step);
    for (validator_cases.vector_files) |file| {
        const run_gen = b.addRunArtifact(gen);
        run_gen.addFileArg(b.path(b.fmt("src/validator/testdata/vectors/{s}.json", .{file.name})));
        // A record may cite only a deviation that this table has a row for.
        run_gen.addFileArg(b.path("src/validator/examples/class_validator.md"));
        const generated = run_gen.addOutputFileArg(b.fmt("{s}_vectors_test.zig", .{file.name}));
        for (file.rules) |rule| run_gen.addArg(rule);
        const vector_tests = b.addTest(.{
            .name = b.fmt("{s}_vectors", .{file.name}),
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
        compile_step.dependOn(&vector_tests.step);
    }
    // A JSON file in vectors/ that `vector_files` does not list would never
    // run. The build system does not see a file added to a directory
    // argument, so this check runs on every build.
    const check_list = b.addRunArtifact(gen);
    check_list.addArg("--check-list");
    check_list.addDirectoryArg2(b.path("src/validator/testdata/vectors"), .{});
    for (validator_cases.vector_files) |file| check_list.addArg(file.name);
    check_list.has_side_effects = true;
    check_list.expectExitCode(0);
    test_step.dependOn(&check_list.step);

    // The examples of src/validator/examples/README.md: a test must pass, and
    // a program must exit with 0 and log each line of its `records`. Each
    // record starts with a timestamp, the only part that changes from run to
    // run, so a line must follow the "Z" that ends a timestamp. readme_test.zig
    // checks that README.md shows every example and a run of every program.
    // The programs are not part of `compile_step`: zefir-log uses 64-bit
    // atomics, which Zig does not support on x86-linux-musl, the 32-bit
    // target of CI.
    for (validator_cases.examples) |example| {
        const example_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/validator/examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "validator", .module = validator },
                .{ .name = "log", .module = log },
            },
        });
        if (example.records) |records| {
            const example_exe = b.addExecutable(.{ .name = example.name, .root_module = example_module });
            const example_run = addRun(b, example_exe, tsan);
            var lines = std.mem.splitScalar(u8, records, '\n');
            while (lines.next()) |line| {
                if (line.len > 0) example_run.expectStdOutMatch(b.fmt("Z {s}\n", .{line}));
            }
            test_step.dependOn(&example_run.step);
        } else {
            const example_test = b.addTest(.{ .name = example.name, .root_module = example_module });
            test_step.dependOn(&b.addRunArtifact(example_test).step);
            compile_step.dependOn(&example_test.step);
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
    compile_step.dependOn(&readme_test.step);
}
