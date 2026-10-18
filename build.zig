const std = @import("std");
const manifest = @import("build.zig.zon");
const validator_cases = @import("src/validator/testdata/cases.zig");
const rpc_guide = @import("src/rpc/examples/cases.zig");
const http_cases = @import("src/http/tests/cases.zig");
const http_guide = @import("src/http/examples/cases.zig");

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

    // nats sends the package version in CONNECT; build.zig.zon is its only source.
    const nats_options = b.addOptions();
    nats_options.addOption([]const u8, "version", manifest.version);
    const nats = b.addModule("zefir-nats", .{
        .root_source_file = b.path("src/nats/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
    });
    nats.addOptions("build_options", nats_options);

    // nats only for its adapter, rpc_nats.ZefirNats: Zig compiles that file
    // only for an application that uses it.
    const rpc_nats = b.addModule("zefir-rpc-nats", .{
        .root_source_file = b.path("src/rpc-nats/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "rpc", .module = rpc },
            .{ .name = "core", .module = core },
            .{ .name = "nats", .module = nats },
        },
    });

    // The access logs of rpc on zefir-log: a module of their own, so that
    // zefir-rpc does not depend on log.
    const rpc_log = b.addModule("zefir-rpc-log", .{
        .root_source_file = b.path("src/rpc-log/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "rpc", .module = rpc },
            .{ .name = "core", .module = core },
            .{ .name = "log", .module = log },
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

    // What every MongoDB driver of zefir shares, starting with BSON. It
    // imports no driver: drivers import it.
    const mongo = b.addModule("zefir-mongo", .{
        .root_source_file = b.path("src/mongo/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
    });

    const http = b.addModule("zefir-http", .{
        .root_source_file = b.path("src/http/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "validator", .module = validator },
        },
    });

    // Umbrella module: @import("zefir").core, .log, .confy, .validator, .rpc, .rpc_nats, .rpc_log, .orm, .mongo, .nats, .http
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
            .{ .name = "rpc-nats", .module = rpc_nats },
            .{ .name = "rpc-log", .module = rpc_log },
            .{ .name = "orm", .module = orm },
            .{ .name = "mongo", .module = mongo },
            .{ .name = "nats", .module = nats },
            .{ .name = "http", .module = http },
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
    const test_rpc_nats = addModuleTestStep(b, test_step, "rpc-nats");
    const test_rpc_log = addModuleTestStep(b, test_step, "rpc-log");
    const test_orm = addModuleTestStep(b, test_step, "orm");
    const test_mongo = addModuleTestStep(b, test_step, "mongo");
    const test_nats = addModuleTestStep(b, test_step, "nats");
    const test_http = addModuleTestStep(b, test_step, "http");
    const test_zefir = addModuleTestStep(b, test_step, "zefir");
    // Builds the validator's test binaries without running them, so that
    // `-Dtarget` may name another system: CI builds them for x86-linux-musl,
    // where usize has 32 bits.
    const validator_compile_step = b.step("compile-validator-tests", "Build the validator's test binaries for -Dtarget without running them");
    for (
        [_]*std.Build.Module{ core, log, confy, validator, rpc, rpc_nats, rpc_log, orm, mongo, nats, http, zefir },
        [_]*std.Build.Step{ test_core, test_log, test_confy, test_validator, test_rpc, test_rpc_nats, test_rpc_log, test_orm, test_mongo, test_nats, test_http, test_zefir },
    ) |module, module_test_step| {
        const tests = b.addTest(.{ .root_module = module });
        module_test_step.dependOn(&addRun(b, tests, tsan).step);
        if (module == validator) validator_compile_step.dependOn(&tests.step);
    }

    addValidatorTests(b, test_validator, validator_compile_step, validator, log, target, optimize, tsan);
    addHttpCompileChecks(b, test_http, http, validator, target, optimize);
    // The examples of the zefir-http guide: the middleware of an
    // application (authentication, CORS) and their tests. Like an
    // application, they may read settings with confy and log with log.
    const http_examples = b.addTest(.{
        .name = "http-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http/examples/middleware_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "validator", .module = validator },
                .{ .name = "confy", .module = confy },
                .{ .name = "log", .module = log },
                .{ .name = "http", .module = http },
            },
        }),
    });
    test_http.dependOn(&addRun(b, http_examples, tsan).step);
    addHttpGuide(b, test_http, .{ .core = core, .validator = validator, .confy = confy, .log = log, .http = http }, target, optimize, tsan);

    // `zig build fuzz-http` runs the fuzz test of zefir-http's HTTP/1.1
    // parser on its corpus, once, like `zig build test-http` does; with
    // `--fuzz` it runs the fuzzer on it (Linux: CI's fuzz.yml).
    const fuzz_http = b.step("fuzz-http", "Run the fuzz test of the zefir-http parser; with --fuzz, the fuzzer (Linux)");
    const http_fuzz_tests = b.addTest(.{
        .name = "fuzz-http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http/h1/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_http.dependOn(&b.addRunArtifact(http_fuzz_tests).step);

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

    // nats panic program: a client copied after connect() panics in safe
    // builds. The program must print the panic message and end in its own
    // panic handler, which exits with code 3 instead of aborting. It gets
    // its own Debug copy of nats, whatever -Doptimize says.
    const panic_nats = b.createModule(.{
        .root_source_file = b.path("src/nats/root.zig"),
        .target = target,
        .optimize = .Debug,
    });
    panic_nats.addOptions("build_options", nats_options);
    const moved_client = b.addExecutable(.{
        .name = "nats-panic-moved-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nats/testdata/panic/moved_client.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "nats", .module = panic_nats },
            },
        }),
    });
    const run_moved_client = b.addRunArtifact(moved_client);
    run_moved_client.expectStdErrMatch("panic: nats.Client moved after connect(): keep it where connect() ran (see the guide)");
    // expectStdErrMatch accepts any exit: only the panic handler exits
    // with 3, so a program that printed the text and returned fails.
    run_moved_client.expectExitCode(3);
    test_nats.dependOn(&run_moved_client.step);

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
        .{ "middleware function with an inferred error set", "rpc.Middleware.of: a middleware function is fn (ctx: *rpc.Context, next: *rpc.Next) anyerror!void, with anyerror written out, not inferred; got fn (*engine.Context.Context, *middleware.Next) @typeInfo(@typeInfo(@TypeOf(compile_errors.inferredLink)).@\"fn\".return_type.?).error_union.error_set!void" },
        .{ "middleware object behind a const pointer", "rpc.Middleware.of: the middleware must be mutable, declared with var; got *const compile_errors.Counter" },
        .{ "client middleware with the server's signature", "rpc.ClientMiddleware.of: compile_errors.test.client middleware with the server's signature.ServerSide.run has another signature; expected pub fn run(self: *@This(), ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void" },
        .{ "conformance harness by value", "rpc.testing.conformance.run: pass a pointer to the harness, e.g. &harness; got compile_errors.Harness" },
        .{ "conformance harness without tearDown", "rpc.testing.conformance.run: compile_errors.test.conformance harness without tearDown.NoTearDown has no method tearDown; expected pub fn tearDown(self: *@This(), io: std.Io, pair: rpc.testing.conformance.Pair) void" },
        .{ "conformance harness behind a const pointer", "rpc.testing.conformance.run: the harness must be mutable, declared with var; got *const compile_errors.Harness" },
        .{ "conformance harness without setUp", "rpc.testing.conformance.run: compile_errors.test.conformance harness without setUp.NoSetUp has no method setUp; expected pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair" },
        .{ "conformance hook with another signature", "rpc.testing.conformance.run: compile_errors.test.conformance hook with another signature.FailingBreak.breakLink has another signature; expected pub fn breakLink(self: *@This(), io: std.Io, pair: rpc.testing.conformance.Pair) void" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("rpc-compile-error-{d}", .{i}),
            .root_module = rpc_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .exact = b.allocator.dupe([]const u8, &.{ case[1], "note: called at comptime here" }) catch @panic("OOM") };
        test_rpc.dependOn(&compile.step);
    }

    // rpc compile errors of contracts, of rpc.implement and of the types of
    // requests and responses: one file each in src/rpc/tests/compile_errors/,
    // compiled as client code. Each must fail with exactly one error, the
    // message next to its name (the whole text after "error: "), and the
    // notes that lead to the user's code: those of a contract lead through
    // the return type of rpc.Contract, that of rpc.implement straight to the
    // call, that of rpc.Client.call through the type of its request. A type
    // declared in a file is named after the file.
    const contract_notes: []const []const u8 = &.{ "note: called at comptime here", "note: generic function instantiated here" };
    const implement_notes: []const []const u8 = &.{"note: called at comptime here"};
    const server_notes: []const []const u8 = &.{"note: called at comptime here"};
    const client_notes: []const []const u8 = &.{"note: called at comptime here"};
    const call_notes: []const []const u8 = &.{ "note: called at comptime here", "note: called at comptime here", "note: generic function instantiated here" };
    for ([_]struct { []const u8, []const u8, []const []const u8 }{
        .{ "contract_name", "rpc: contract \"user service\": the name must be 1 to 64 characters from [A-Za-z0-9_-]", contract_notes },
        .{ "contract_version", "rpc: contract \"users\": .version must be 1 to 65535, got 0", contract_notes },
        .{ "contract_no_methods", "rpc: users.v1: .methods is empty; a contract has at least one method", contract_notes },
        .{ "contract_plain_type", "rpc: users.v1.getUser: write rpc.method(Request, Response), got the type contract_plain_type.GetUserRequest", contract_notes },
        .{ "contract_request_not_struct", "rpc: users.v1.getUser: request must be a struct, got u64", contract_notes },
        .{ "contract_reserved_error", "rpc: users.v1: .errors.Unavailable: rpc maps Unavailable by itself, so a contract cannot list it; give the error another name", contract_notes },
        .{ "contract_unknown_code", "rpc: users.v1: .errors.UserNotFound.code must be one of core.ErrorCode, such as .not_found, got .notfound", contract_notes },
        .{ "contract_rpc_app_code", "rpc: users.v1: .errors.UserNotFound.app_code \"rpc.not_found\" starts with \"rpc.\", which belongs to the framework", contract_notes },
        .{ "contract_repeated_app_code", "rpc: users.v1: .errors.UserNotFound and .errors.NoUser share .app_code \"users.not_found\"; each error needs its own", contract_notes },
        .{ "dto_pointer", "rpc: users.v1.getUser: response dto_pointer.User.avatar has unsupported type *dto_pointer.File", contract_notes },
        .{ "dto_usize", "rpc: users.v1.listUsers: request dto_usize.ListUsersRequest.limit has unsupported type usize; its size depends on the target: use u64 or i64", contract_notes },
        .{ "dto_recursive", "rpc: tree.v1.get: response dto_recursive.Node.children[]: recursive types are not supported; dto_recursive.Node contains itself", contract_notes },
        .{ "dto_union", "rpc: canvas.v2.draw: request dto_union.DrawRequest.shape has unsupported type dto_union.Shape; unions are not supported", contract_notes },
        .{ "dto_too_large", "rpc: images.v1.getImage: response dto_too_large.Image.pixels takes 262144 bytes; a type in a DTO takes at most 16384 (16 KiB), since requests and responses live on the stack of a call: use a slice, []const u32", contract_notes },
        .{ "implement_not_contract", "rpc.implement: the first argument must be a contract made by rpc.Contract(...), got type", implement_notes },
        .{ "implement_timeout", "rpc.implement(users.v1): .defaults.timeout_ms must be 1 to 300000 ms, got 0", implement_notes },
        .{ "implement_auth", "rpc.implement(users.v1): .methods.getUser.auth must be .required or .optional, got .maybe", implement_notes },
        .{ "implement_unknown_setting", "rpc.implement(users.v1): unknown setting .default; the settings are .defaults, .middleware and .methods", implement_notes },
        .{ "server_no_rpc_handler", "rpc.Server.init: server_no_rpc_handler.UserHandler has no `pub const rpc_handler = rpc.implement(Api, ...)`; every handler must declare it (and it must be pub)", server_notes },
        .{ "server_rpc_handler_not_pub", "rpc.Server.init: server_rpc_handler_not_pub.UserHandler has no `pub const rpc_handler = rpc.implement(Api, ...)`; every handler must declare it (and it must be pub)", server_notes },
        .{ "server_rpc_handler_not_implement", "rpc.Server.init: server_rpc_handler_not_implement.UserHandler.rpc_handler must be built with rpc.implement(Api, ...)", server_notes },
        .{ "server_handler_by_value", "rpc.Server.init: .handlers[0] is server_handler_by_value.UserHandler; pass a pointer to a handler, e.g. &users", server_notes },
        .{ "server_method_missing", "rpc: server_method_missing.UserHandler implements users.v1 but has no pub fn deleteUser(self: *server_method_missing.UserHandler, ctx: *rpc.Context, req: server_method_missing.DeleteUserRequest) !void", server_notes },
        .{ "server_method_not_pub", "rpc: server_method_not_pub.UserHandler implements users.v1 but has no pub fn getUser(self: *server_method_not_pub.UserHandler, ctx: *rpc.Context, req: server_method_not_pub.GetUserRequest) !server_method_not_pub.User", server_notes },
        .{ "server_method_signature", "rpc: server_method_signature.UserHandler.getUser: expected fn (*server_method_signature.UserHandler, *rpc.Context, server_method_signature.GetUserRequest) !server_method_signature.User, found fn (*server_method_signature.UserHandler, server_method_signature.GetUserRequest) !server_method_signature.User", server_notes },
        .{ "server_unknown_method", "rpc: server_unknown_method.UserHandler.rpc_handler: getUsers is not a method of users.v1", server_notes },
        .{ "server_middleware_item", "rpc: server_middleware_item.UserHandler.getUser: middleware[1] must be fn (*rpc.Context, *rpc.Next) anyerror!void, or a field of server_middleware_item.UserHandler whose type has pub fn run(self, *rpc.Context, *rpc.Next) anyerror!void", server_notes },
        .{ "server_same_route", "rpc.Server.init: server_same_route.UserHandler and server_same_route.OtherUserHandler both serve users.v1", server_notes },
        .{ "server_auth_without_authenticator", "rpc.Server.init: server_auth_without_authenticator.UserHandler.getUser requires auth, but .authenticator is not set", server_notes },
        .{ "server_middleware", "rpc.Server.init: .middleware[1] must be fn (*rpc.Context, *rpc.Next) anyerror!void or a pointer to a type with pub fn run(self, *rpc.Context, *rpc.Next) anyerror!void", server_notes },
        .{ "client_unknown_option", "rpc.Client.init: unknown option .timeout; the options are .transport, .credentials, .middleware, .default_timeout, .max_pending and .max_response_bytes", client_notes },
        .{ "client_credentials_literal", "rpc.Client.init: .credentials = .bearer needs a value, such as .{ .bearer = token }; only .none stands alone", client_notes },
        .{ "client_not_a_method", "rpc.Client.call: the method must be a method of a contract, such as UserApi.getUser; got the contract users.v1 itself", call_notes },
    }) |case| {
        const compile = b.addTest(.{
            .name = b.fmt("rpc-compile-error-{s}", .{case[0]}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/rpc/tests/compile_errors/{s}.zig", .{case[0]})),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .imports = &.{.{ .name = "rpc", .module = rpc }},
            }),
        });
        const lines = std.mem.concat(b.allocator, []const u8, &.{ &.{b.fmt("error: {s}", .{case[1]})}, case[2] }) catch @panic("OOM");
        compile.expect_errors = .{ .exact = lines };
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

    // The same for an application that breaks the rules of rpc.RawClient.
    const client_panics = b.addExecutable(.{
        .name = "rpc-panic-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc/tests/panic/client.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "core", .module = panic_core },
                .{ .name = "rpc", .module = panic_rpc },
            },
        }),
    });
    for ([_][2][]const u8{
        .{ "provider_returns_provider", "rpc.RawClient: a CredentialsProvider returned .provider; return the credentials of the call" },
    }) |case| {
        const run = b.addRunArtifact(client_panics);
        run.addArg(case[0]);
        run.expectStdErrMatch(case[1]);
        run.expectExitCode(3);
        test_rpc.dependOn(&run.step);
    }

    // rpc-nats compile errors: adapters whose methods do not fit
    // rpc_nats.Conn, in the manner of the rpc ones above.
    const rpc_nats_compile_errors = b.createModule(.{
        .root_source_file = b.path("src/rpc-nats/tests/compile_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "rpc-nats", .module = rpc_nats },
        },
    });
    const next_signature = "pub fn next(self: *@This(), io: std.Io, sub: rpc_nats.Conn.Sub, timeout: std.Io.Timeout) rpc_nats.Conn.Error!?rpc_nats.Conn.InMsg";
    for ([_][2][]const u8{
        .{ "adapter without next", "rpc_nats.Conn.init: compile_errors.test.adapter without next.NoNext has no method next; expected " ++ next_signature },
        .{ "next with another signature", "rpc_nats.Conn.init: compile_errors.test.next with another signature.NextWithoutTimeout.next has another signature; expected " ++ next_signature },
        .{ "isConnected with another signature", "rpc_nats.Conn.init: compile_errors.test.isConnected with another signature.ConnectedWithIo.isConnected has another signature; expected pub fn isConnected(self: *@This()) bool" },
        .{ "init with a value", "rpc_nats.Conn.init: pass a pointer to the adapter, e.g. &adapter; got compile_errors.Adapter" },
        .{ "init with a pointer to a constant", "rpc_nats.Conn.init: the adapter must be mutable, declared with var; got *const compile_errors.Adapter" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("rpc-nats-compile-error-{d}", .{i}),
            .root_module = rpc_nats_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .exact = b.allocator.dupe([]const u8, &.{ case[1], "note: called at comptime here" }) catch @panic("OOM") };
        test_rpc_nats.dependOn(&compile.step);
    }

    // mongo compile errors: types that the BSON codec cannot write or read.
    // Each test of the file must fail to compile with the message next to
    // its name, which names the field; the filter compiles one test at a
    // time. A type declared in the file is named after the file.
    const mongo_compile_errors = b.createModule(.{
        .root_source_file = b.path("src/mongo/tests/compile_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "mongo", .module = mongo },
        },
    });
    for ([_][2][]const u8{
        .{ "u64", "bson.encode: field 'n' is u64, which BSON has no type for: its integers are signed; use i64" },
        .{ "usize", "bson.encode: field 'n' is usize, whose size depends on the target: use i64 or i32" },
        .{ "isize", "bson.decode: field 'n' is isize, whose size depends on the target: use i64 or i32" },
        .{ "c_int", "bson.encode: field 'n' is c_int, whose size depends on the target: use an integer of a fixed width, such as i32" },
        .{ "non-exhaustive enum", "bson.encode: field 'kind' is compile_errors.Open, a non-exhaustive enum: a value without a tag has no name to write; make the enum exhaustive" },
        .{ "union", "bson.decode: field 'shape' is compile_errors.Shape: unions are not supported; a field of any BSON type is a bson.Value" },
        .{ "pointer", "bson.encode: field 'owner' is *const compile_errors.User: pass the value itself, not a pointer to it" },
        .{ "many-item pointer", "bson.encode: field 'name' is [*]const u8, which has no length: pass a slice" },
        .{ "type that holds itself", "bson.encode: field 'children[]' is compile_errors.Node inside itself: a type that holds itself is not supported" },
        .{ "optional of an optional", "bson.encode: field 'n' is ??u32: BSON null cannot tell the two nulls apart" },
        .{ "path of a nested field", "bson.decode: field 'items[].owner.id' is u64, which BSON has no type for: its integers are signed; use i64" },
        .{ "put of a u64", "bson.Builder.put: the value is u64, which BSON has no type for: its integers are signed; use i64" },
        .{ "literal of a string that is not UTF-8", "bson.literal: the string of 'a' is not UTF-8" },
        .{ "integer literal beyond int64", "bson.encode: field 'n' is 9223372036854775808, which does not fit int64" },
        .{ "tuple as a document", "bson.encode: a tuple is an array, not a document: give its values names, such as .{ .a = x }" },
        .{ "number as a document", "bson.encode: a document is a struct with named fields, such as .{ .name = name }, or a bson.RawDocument; got u32" },
        .{ "deprecated type to encode", "bson.encode: field 'p' is bson.types.DbPointer, a deprecated type: it is read, never written" },
        .{ "tuple to decode", "bson.decode: field 'pair' is struct { i32, i32 }, a tuple: decode needs the names of fields; use a struct, or a slice for an array" },
        .{ "comptime field to decode", "bson.decode: field 'version' is a comptime field: decode fills only fields known at run time" },
        .{ "mutable slice to decode", "bson.decode: field 'name' is []u8: decode gives const slices; use []const u8" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("mongo-compile-error-{d}", .{i}),
            .root_module = mongo_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .contains = case[1] };
        test_mongo.dependOn(&compile.step);
    }

    // mongo compile errors of the contract: drivers and cursors whose
    // methods do not fit mongo.Client and mongo.Cursor. As with the
    // transports of rpc, each test must fail with exactly one error, the
    // message next to its name, and its note "called at comptime here" at
    // the check in zefir-mongo.
    const mongo_contract_errors = b.createModule(.{
        .root_source_file = b.path("src/mongo/tests/contract_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "mongo", .module = mongo },
        },
    });
    const run_command_signature = "pub fn runCommand(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!mongo.bson.OwnedDocument";
    const open_cursor_signature = "pub fn openCursor(self: *@This(), io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor";
    const write_signature = "pub fn write(self: *@This(), io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult";
    for ([_][2][]const u8{
        .{ "client init with a value", "mongo.Client.init: pass a pointer to the driver, e.g. &driver; got contract_errors.Driver" },
        .{ "client init with a pointer to a constant", "mongo.Client.init: the driver must be mutable, declared with var; got *const contract_errors.Driver" },
        .{ "driver without write", "mongo.Client.init: contract_errors.test.driver without write.NoWrite has no method write; expected " ++ write_signature },
        .{ "runCommand that takes the command by value", "mongo.Client.init: contract_errors.test.runCommand that takes the command by value.ByValue.runCommand has another signature; expected " ++ run_command_signature },
        .{ "openCursor with an inferred error set", "mongo.Client.init: contract_errors.test.openCursor with an inferred error set.Inferred.openCursor has another signature; expected " ++ open_cursor_signature },
        .{ "capabilities that take io", "mongo.Client.init: contract_errors.test.capabilities that take io.WithIo.capabilities has another signature; expected pub fn capabilities(self: *@This()) mongo.Capabilities" },
        .{ "cursor init with a value", "mongo.Cursor.init: pass a pointer to the cursor, e.g. &cursor; got contract_errors.Cursor" },
        .{ "cursor init with a pointer to a constant", "mongo.Cursor.init: the cursor must be mutable, declared with var; got *const contract_errors.Cursor" },
        .{ "cursor without close", "mongo.Cursor.init: contract_errors.test.cursor without close.NoClose has no method close; expected pub fn close(self: *@This(), io: std.Io) void" },
        .{ "next that gives an owned document", "mongo.Cursor.init: contract_errors.test.next that gives an owned document.Owned.next has another signature; expected pub fn next(self: *@This(), io: std.Io, op: mongo.OperationContext) mongo.Error!?mongo.bson.RawDocument" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("mongo-contract-error-{d}", .{i}),
            .root_module = mongo_contract_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .exact = b.allocator.dupe([]const u8, &.{ case[1], "note: called at comptime here" }) catch @panic("OOM") };
        test_mongo.dependOn(&compile.step);
    }

    // mongo compile errors of the conformance suite: harnesses whose
    // methods do not fit mongo.testing.conformance.run, checked as the
    // drivers above.
    const mongo_conformance_errors = b.createModule(.{
        .root_source_file = b.path("src/mongo/tests/conformance_errors.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "mongo", .module = mongo },
        },
    });
    for ([_][2][]const u8{
        .{ "harness by value", "mongo.testing.conformance.run: pass a pointer to the harness, e.g. &harness; got conformance_errors.Harness" },
        .{ "harness behind a const pointer", "mongo.testing.conformance.run: the harness must be mutable, declared with var; got *const conformance_errors.Harness" },
        .{ "harness without close", "mongo.testing.conformance.run: conformance_errors.test.harness without close.NoClose has no method close; expected pub fn close(self: *@This(), io: std.Io) void" },
        .{ "setUp without the target", "mongo.testing.conformance.run: conformance_errors.test.setUp without the target.NoTarget.setUp has another signature; expected pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator, target: mongo.testing.conformance.Target) !mongo.Client" },
        .{ "tearDown that may fail", "mongo.testing.conformance.run: conformance_errors.test.tearDown that may fail.Failing.tearDown has another signature; expected pub fn tearDown(self: *@This(), io: std.Io) void" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("mongo-conformance-error-{d}", .{i}),
            .root_module = mongo_conformance_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .exact = b.allocator.dupe([]const u8, &.{ case[1], "note: called at comptime here" }) catch @panic("OOM") };
        test_mongo.dependOn(&compile.step);
    }

    // rpc-nats panic program: a second conn() of one ZefirNats panics in
    // safe builds, since one adapter serves one transport. Like the rpc
    // ones above, it ends in its own panic handler with code 3 and gets
    // Debug copies of rpc-nats and its imports.
    const panic_rpc_nats = b.createModule(.{
        .root_source_file = b.path("src/rpc-nats/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "rpc", .module = panic_rpc },
            .{ .name = "core", .module = panic_core },
            .{ .name = "nats", .module = panic_nats },
        },
    });
    const second_conn = b.addExecutable(.{
        .name = "rpc-nats-panic-second-conn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc-nats/tests/panic/second_conn.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "nats", .module = panic_nats },
                .{ .name = "rpc-nats", .module = panic_rpc_nats },
            },
        }),
    });
    const run_second_conn = b.addRunArtifact(second_conn);
    run_second_conn.expectStdErrMatch("panic: rpc_nats.ZefirNats: conn() called twice; one adapter serves one transport: give each transport an adapter of its own");
    run_second_conn.expectExitCode(3);
    test_rpc_nats.dependOn(&run_second_conn.step);

    // The guide of rpc-nats shows its examples as they are. The examples
    // need NATS servers and zio: tests/rpc-nats builds and runs them.
    const rpc_nats_guide = b.addTest(.{
        .name = "rpc-nats-guide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc-nats/examples/readme_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "guide-check", .module = b.createModule(.{
                .root_source_file = b.path("src/rpc/examples/guide_check.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
            }) }},
        }),
    });
    // The tutorial of the guide, writing-a-transport.md, shows parts of the
    // files of src/rpc-nats/. A test embeds no file outside the directory
    // of its module, so the files come to it as anonymous imports, under
    // their names. A new file of src/rpc-nats/ goes into this list too.
    const rpc_nats_sources = [_][]const u8{ "Conn.zig", "Transport.zig", "ZefirNats.zig", "client.zig", "client_tests.zig", "conformance_tests.zig", "micro.zig", "micro_tests.zig", "root.zig", "server.zig", "server_tests.zig", "shared.zig", "subject.zig", "testing.zig", "wire.zig" };
    const rpc_nats_guide_options = b.addOptions();
    rpc_nats_guide_options.addOption([]const []const u8, "sources", &rpc_nats_sources);
    rpc_nats_guide.root_module.addOptions("readme_options", rpc_nats_guide_options);
    for (rpc_nats_sources) |name| {
        rpc_nats_guide.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("src/rpc-nats/{s}", .{name})) });
    }
    test_rpc_nats.dependOn(&addRun(b, rpc_nats_guide, tsan).step);

    addRpcGuide(b, test_rpc, test_rpc_log, .{
        .core = core,
        .validator = validator,
        .confy = confy,
        .log = log,
        .rpc = rpc,
        .rpc_log = rpc_log,
    }, target, optimize, tsan);

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

/// The modules that the examples of the rpc guide import.
const GuideModules = struct {
    core: *std.Build.Module,
    validator: *std.Build.Module,
    confy: *std.Build.Module,
    log: *std.Build.Module,
    rpc: *std.Build.Module,
    rpc_log: *std.Build.Module,
};

/// The examples of src/rpc/examples/README.md, the guide of rpc and
/// rpc-log, as cases.zig there lists them. Every program runs through
/// example_main.zig, which exits with code 3 on a panic instead of
/// aborting and with code 4 when the run takes longer than its time limit
/// (testdata/hang.zig checks that), and must exit with 0; readme_test.zig
/// then checks that README.md shows every file as it is and every run as
/// it printed. The programs of the access logs and their check belong to
/// `test_rpc_log`, the rest to `test_rpc`, so that the programs of
/// `test_rpc` never import zefir-rpc-log, which imports rpc.
fn addRpcGuide(
    b: *std.Build,
    test_rpc: *std.Build.Step,
    test_rpc_log: *std.Build.Step,
    m: GuideModules,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    tsan: bool,
) void {
    const dir = "src/rpc/examples/";
    // The packages of the contracts, which real services would fetch, with
    // the tests of their rules.
    var contracts: [2]*std.Build.Module = undefined;
    for ([_][]const u8{ "users_api", "orders_api" }, &contracts) |name, *contract| {
        contract.* = b.createModule(.{
            .root_source_file = b.path(b.fmt(dir ++ "{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "rpc", .module = m.rpc },
                .{ .name = "validator", .module = m.validator },
            },
        });
        test_rpc.dependOn(&addRun(b, b.addTest(.{ .name = name, .root_module = contract.* }), tsan).step);
    }
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = m.core },
        .{ .name = "confy", .module = m.confy },
        .{ .name = "log", .module = m.log },
        .{ .name = "rpc", .module = m.rpc },
        .{ .name = "users-api", .module = contracts[0] },
        .{ .name = "orders-api", .module = contracts[1] },
    };
    const access_log_imports = std.mem.concat(b.allocator, std.Build.Module.Import, &.{ imports, &.{.{ .name = "rpc-log", .module = m.rpc_log }} }) catch @panic("OOM");

    for (rpc_guide.tests) |name| {
        const tests = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt(dir ++ "{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .imports = imports,
            }),
        });
        test_rpc.dependOn(&addRun(b, tests, tsan).step);
    }

    // A program that hangs: the time limit of example_main.zig ends it.
    const hang = b.addExecutable(.{
        .name = "rpc-guide-hang",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "example_main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "example", .module = b.createModule(.{
                .root_source_file = b.path(dir ++ "testdata/hang.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
            }) }},
        }),
    });
    const run_hang = addRun(b, hang, tsan);
    run_hang.expectStdErrMatch("the run did not end within 1 s");
    run_hang.expectExitCode(4);
    test_rpc.dependOn(&run_hang.step);

    const cases = b.createModule(.{
        .root_source_file = b.path(dir ++ "cases.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (
        [_]bool{ false, true },
        [_][]const rpc_guide.Program{ &rpc_guide.programs, &rpc_guide.access_log_programs },
        [_]*std.Build.Step{ test_rpc, test_rpc_log },
    ) |access_log, programs, step| {
        const options = b.addOptions();
        options.addOption(bool, "access_log", access_log);
        const readme = b.createModule(.{
            .root_source_file = b.path(dir ++ "readme_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "cases", .module = cases },
                .{ .name = "readme_options", .module = options.createModule() },
            },
        });
        // "rpc in a minute" of the repository's README.md is a program of
        // the guide too.
        readme.addAnonymousImport("root_readme", .{ .root_source_file = b.path("README.md") });
        for (programs) |program| {
            const exe = b.addExecutable(.{
                .name = b.fmt("rpc-guide-{s}", .{program.name}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path(dir ++ "example_main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .sanitize_thread = tsan,
                    .imports = &.{.{ .name = "example", .module = b.createModule(.{
                        .root_source_file = b.path(b.fmt(dir ++ "{s}.zig", .{program.name})),
                        .target = target,
                        .optimize = optimize,
                        .sanitize_thread = tsan,
                        .imports = if (access_log) access_log_imports else imports,
                    }) }},
                }),
            });
            const run = addRun(b, exe, tsan);
            for (program.env) |pair| run.setEnvironmentVariable(pair[0], pair[1]);
            run.expectExitCode(0);
            readme.addAnonymousImport(b.fmt("{s}.out", .{program.name}), .{ .root_source_file = run.captureStdOut(.{}) });
        }
        step.dependOn(&addRun(b, b.addTest(.{ .name = "rpc-guide-readme", .root_module = readme }), tsan).step);
    }
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

/// The modules that the examples of the http guide import.
const HttpGuideModules = struct {
    core: *std.Build.Module,
    validator: *std.Build.Module,
    confy: *std.Build.Module,
    log: *std.Build.Module,
    http: *std.Build.Module,
};

/// The examples of src/http/examples/README.md, the guide of zefir-http,
/// as cases.zig there lists them: the tests of the example app, and the
/// programs that run on the backend in memory, each through
/// example_main.zig, which exits with code 3 on a panic instead of
/// aborting and with code 4 past its time limit; it must exit with 0.
/// readme_test.zig then checks that README.md shows every file as it is
/// and every run as it printed. The service, main.zig, imports zio: only
/// tests/http builds and runs it.
fn addHttpGuide(
    b: *std.Build,
    test_http: *std.Build.Step,
    m: HttpGuideModules,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    tsan: bool,
) void {
    const dir = "src/http/examples/";
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "core", .module = m.core },
        .{ .name = "validator", .module = m.validator },
        .{ .name = "confy", .module = m.confy },
        .{ .name = "log", .module = m.log },
        .{ .name = "http", .module = m.http },
    };
    const todos_test = b.addTest(.{
        .name = "http-todos-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "todos_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = imports,
        }),
    });
    test_http.dependOn(&addRun(b, todos_test, tsan).step);

    const readme = b.createModule(.{
        .root_source_file = b.path(dir ++ "readme_test.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
    });
    // "http in a minute" of the repository's README.md is a program of the
    // guide too.
    readme.addAnonymousImport("root_readme", .{ .root_source_file = b.path("README.md") });
    for (http_guide.programs) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("http-guide-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(dir ++ "example_main.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = tsan,
                .imports = &.{.{ .name = "example", .module = b.createModule(.{
                    .root_source_file = b.path(b.fmt(dir ++ "{s}.zig", .{name})),
                    .target = target,
                    .optimize = optimize,
                    .sanitize_thread = tsan,
                    .imports = imports,
                }) }},
            }),
        });
        const run = addRun(b, exe, tsan);
        run.expectExitCode(0);
        readme.addAnonymousImport(b.fmt("{s}.out", .{name}), .{ .root_source_file = run.captureStdOut(.{}) });
    }
    test_http.dependOn(&addRun(b, b.addTest(.{ .name = "http-guide-readme", .root_module = readme }), tsan).step);
}

/// The compile checks of zefir-http, from the lists in
/// src/http/tests/cases.zig: client code that must fail to compile with
/// its message, and client code that must compile. Each file imports
/// "http" and "validator".
fn addHttpCompileChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    http: *std.Build.Module,
    validator: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "http", .module = http },
        .{ .name = "validator", .module = validator },
    };
    // Each fixture is compiled (never run) and passes only when the
    // compilation fails with an error whose message is `expect`.
    // `.contains` matches the end of an error line, so `error: ` in front
    // makes `expect` the whole message, from its start.
    for (http_cases.compile_errors) |fixture| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(fixture.file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(fixture.file),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        t.expect_errors = .{ .contains = b.fmt("error: {s}", .{fixture.expect}) };
        test_step.dependOn(&t.step);
    }
    // Built and not run: they only have to compile.
    for (http_cases.must_compile) |file| {
        const t = b.addTest(.{
            .name = std.fs.path.stem(file),
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        test_step.dependOn(&t.step);
    }
    // A large application, which gen_big_app writes into the build cache:
    // ten controllers of thirty routes, middleware on every level and forty
    // errors of its own; and one route that returns 200 errors of long
    // names. Each must compile without an eval branch quota of its own. The
    // generator is built for the host, so it also runs when -Dtarget names
    // another system.
    const gen_big_app = b.addExecutable(.{
        .name = "gen_big_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http/tests/gen_big_app.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_gen = b.addRunArtifact(gen_big_app);
    for ([_][]const u8{ "big_app", "long_names_app" }) |name| {
        const app = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = run_gen.addOutputFileArg(b.fmt("{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        test_step.dependOn(&app.step);
    }
}
