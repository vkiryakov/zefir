//! The probe of the compile-time cost of zefir-openapi (design 1.2,
//! section 16), on the real generator: a synthetic application of N routes
//! (gen_app.py) with the typed declarations of zefir.openapi, and two
//! programs that build its server: without a document (baseline), and with
//! the document of zefir.openapi.document (real).
//!
//! The measurement runs on CI only, in .github/workflows/openapi-probe.yml:
//! measure.sh times one `zig build-exe` of each program by hand, with fresh
//! caches, so that the time and the memory are those of one compiler.
//! This file builds the same programs:
//!
//!   zig build -Droutes=N          build the programs
//!   zig build smoke -Droutes=N    run them; the real one must write its document
//!
//! Every program is built with LLVM, the backend of a Debug build on a Mac:
//! on x86_64 Linux Zig would take its own.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const routes = b.option(u32, "routes", "Routes of the synthetic application (default 2)") orelse 2;
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const http = zefir.module("zefir-http");
    const validator = zefir.module("zefir-validator");
    const openapi = zefir.module("zefir-openapi");

    const gen = b.addSystemCommand(&.{"python3"});
    gen.addFileArg(b.path("gen_app.py"));
    gen.addArg(b.fmt("{d}", .{routes}));
    const app_source = gen.addOutputFileArg("app.zig");

    const app = b.createModule(.{
        .root_source_file = app_source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
            .{ .name = "validator", .module = validator },
            .{ .name = "openapi", .module = openapi },
        },
    });

    const smoke = b.step("smoke", "Run the programs; the real one must write its document");
    for ([_][]const u8{ "baseline", "real" }) |variant| {
        const exe = b.addExecutable(.{
            .name = b.fmt("probe-{s}", .{variant}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("main_{s}.zig", .{variant})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "http", .module = http },
                    .{ .name = "app", .module = app },
                    .{ .name = "openapi", .module = openapi },
                },
            }),
            .use_llvm = true,
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        if (std.mem.eql(u8, variant, "real")) {
            // The document, parsed as JSON by the host's Python.
            const document = run.addOutputFileArg("real.json");
            const parse = b.addSystemCommand(&.{ "python3", "-I", "-c", "import json, sys; json.load(open(sys.argv[1]))" });
            parse.addFileArg(document);
            smoke.dependOn(&parse.step);
        } else smoke.dependOn(&run.step);
    }
}
