const std = @import("std");

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

    const rpc = b.addModule("zefir-rpc", .{
        .root_source_file = b.path("src/rpc/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "confy", .module = confy },
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

    // Umbrella module: @import("zefir").core, .log, .confy, .rpc, .orm
    const zefir = b.addModule("zefir", .{
        .root_source_file = b.path("src/zefir.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "log", .module = log },
            .{ .name = "confy", .module = confy },
            .{ .name = "rpc", .module = rpc },
            .{ .name = "orm", .module = orm },
        },
    });

    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ core, log, confy, rpc, orm, zefir }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&addRun(b, tests, tsan).step);
    }

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
        test_step.dependOn(&run.step);
    }

    // log examples: `zig build test` builds and runs them, like the core ones.
    for ([_][]const u8{ "service", "config" }) |name| {
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
        test_step.dependOn(&run.step);
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
            .{ .name = "log", .module = log },
        },
    });
    for ([_][2][]const u8{
        .{ "fields that are not a struct", "zefir.log: fields must be a struct literal such as .{ .user_id = id }, got 'comptime_int'" },
        .{ "positional fields", "zefir.log: fields need names: write .{ .user_id = id }, not .{ id }" },
        .{ "reserved field name", "zefir.log: field name 'level' is reserved for record metadata; rename it, e.g. 'user_level'" },
        .{ "dotted service field", "zefir.log: field name 'service.name' is reserved for record metadata; rename it, e.g. 'user_service.name'" },
        .{ "subfield of the source object", "zefir.log: field name 'source.file' is reserved for record metadata; rename it, e.g. 'user_source.file'" },
        .{ "name with a space", "zefir.log: field name 'user id' may contain only [A-Za-z0-9_.-]" },
        .{ "src of the wrong type", "zefir.log: field 'src' is the call site and must be a std.lang.SourceLocation; pass .src = @src()" },
        .{ "error union value", "zefir.log: field 'value': cannot log error union 'anyerror!u8'; handle it with try or catch first, then log the payload or the error" },
        .{ "void value", "zefir.log: field 'nothing': cannot log 'void'; remove the field" },
        .{ "value of a type that has no loggable form", "zefir.log: cannot log type '@TypeOf(undefined)' in field 'x'; give it a format or logValue method, or log one of its fields" },
        // Type names depend on the file, so these check only the end of the line.
        .{ "untagged union", "': its active field is unknown; use union(enum) or log one of its fields" },
        .{ "many-item pointer", "zefir.log: field 'p': cannot log many-item pointer '[*]const u8': it has no length; log a slice, ptr[0..len]" },
        .{ "C pointer", "zefir.log: field 'p': cannot log C pointer '[*c]const u8'; convert it to a slice or log the address as an integer" },
        .{ "pointer to an opaque type", "zefir.log: field 'p': cannot log '*anyopaque': an opaque type has no value to log" },
        .{ "function pointer", "zefir.log: field 'f': cannot log function '*const fn () void'" },
        .{ "reserved name on the flat path", "zefir.log: field 'service.name' is reserved for record metadata; rename 'service', e.g. 'user_service'" },
        .{ "nested name with a space", "zefir.log: field name 's.a b' may contain only [A-Za-z0-9_.-]" },
        .{ "nested error union", "zefir.log: field 'cfg.r': cannot log error union 'anyerror!u8'; handle it with try or catch first, then log the payload or the error" },
        .{ "sensitive marker of the wrong type", ".zefir_sensitive must be a bool: pub const zefir_sensitive = true;" },
        .{ "logValue that returns its own type", " itself; return another type, such as a struct of the fields to log" },
        .{ "sensitive type as the fields", "' is sensitive and cannot be the fields; log it as one field: .{ .key = key }" },
        .{ "type with its own logged form as the fields", "' has its own logged form; log it as one field: .{ .value = value }" },
        .{ "format of another form", ".format has another form than the one {f} uses; write pub fn format(self, w: *std.Io.Writer) !void" },
        .{ "logValue with a mutable self", ".logValue has another form; write pub fn logValue(self) U, taking self by value or by *const" },
        .{ "logValue that returns an error union", ".logValue returns an error union; return a value, since logging cannot fail" },
        .{ "reserved name on the flat path through an array", "zefir.log: field 'service[].name' is reserved for record metadata; rename 'service', e.g. 'user_service'" },
        .{ "subfield of the call site", "zefir.log: field name 'src.function' is reserved for record metadata; rename it, e.g. 'user_src.function'" },
        .{ "function value", "zefir.log: field 'f': cannot log function 'fn () void'" },
        .{ "many-item pointer to u16 with a sentinel", "zefir.log: field 'p': cannot log many-item pointer '[*:0]const u16': it has no length; log a slice, ptr[0..len]" },
        .{ "packed union", "': its active field is unknown; use union(enum) or log one of its fields" },
        .{ "optional void", "zefir.log: field 'x': cannot log 'void'; remove the field" },
    }, 0..) |case, i| {
        const compile = b.addTest(.{
            .name = b.fmt("log-compile-error-{d}", .{i}),
            .root_module = log_compile_errors,
            .filters = &.{case[0]},
        });
        compile.expect_errors = .{ .contains = case[1] };
        test_step.dependOn(&compile.step);
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

/// Runs `artifact`. Under ThreadSanitizer the first report fails the run at
/// once, with an exit code rather than an abort and its crash report.
fn addRun(b: *std.Build, artifact: *std.Build.Step.Compile, tsan: bool) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    if (tsan) run.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1:abort_on_error=0");
    return run;
}
