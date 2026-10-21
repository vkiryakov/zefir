//! The probe of the compile-time cost of zefir-openapi (design 1.2,
//! section 16): a synthetic application of N routes (gen_app.py), and four
//! programs that build its server, each with the document its own way
//! (openapi.zig): none (baseline), the JSON at compile time (a), the model
//! at compile time and the JSON at run time (b), the JSON at compile time
//! by `++` (naive).
//!
//! The measurement runs on CI only, in .github/workflows/openapi-probe.yml:
//! measure.sh times one `zig build-exe` of each program by hand, with fresh
//! caches, so that the time and the memory are those of one compiler.
//! This file builds the same programs:
//!
//!   zig build -Droutes=N          build the four programs
//!   zig build smoke -Droutes=N    run them; A and B must write one document
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

    const gen = b.addSystemCommand(&.{"python3"});
    gen.addFileArg(b.path("gen_app.py"));
    gen.addArg(b.fmt("{d}", .{routes}));
    const app_source = gen.addOutputFileArg("app.zig");

    const openapi = b.createModule(.{
        .root_source_file = b.path("openapi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http", .module = http },
            .{ .name = "validator", .module = validator },
        },
    });
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

    const smoke = b.step("smoke", "Run every program; A and B must write the same document");
    const compare = b.addSystemCommand(&.{"cmp"});
    smoke.dependOn(&compare.step);
    for ([_][]const u8{ "baseline", "a", "b", "naive" }) |variant| {
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
        if (std.mem.eql(u8, variant, "baseline")) {
            smoke.dependOn(&run.step);
            continue;
        }
        const document = run.addOutputFileArg(b.fmt("{s}.json", .{variant}));
        if (std.mem.eql(u8, variant, "naive")) {
            smoke.dependOn(&run.step);
        } else {
            compare.addFileArg(document);
        }
    }
}
