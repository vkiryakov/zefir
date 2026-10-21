//! The probe of the compile-time cost of zefir-openapi (design 1.2,
//! section 16): a synthetic application of N routes (gen_app.py), and
//! programs that build its server, each with the document its own way
//! (openapi.zig): none (baseline); the model at compile time and the JSON
//! at run time (b); the JSON at compile time by pure functions (a), by
//! counting and filling one array (afill), by `++` per piece (naive).
//!
//! The measurement runs on CI only, in .github/workflows/openapi-probe.yml:
//! measure.sh times one `zig build-exe` of each program by hand, with fresh
//! caches, so that the time and the memory are those of one compiler.
//! This file builds the same programs:
//!
//!   zig build -Droutes=N          build the programs
//!   zig build smoke -Droutes=N    run them; each must write the document of B
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

    const smoke = b.step("smoke", "Run every program; each must write the document of B");
    var document_of_b: ?std.Build.LazyPath = null;
    var others: [3]std.Build.LazyPath = undefined;
    var count: usize = 0;
    for ([_][]const u8{ "baseline", "b", "a", "afill", "naive" }) |variant| {
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
        if (std.mem.eql(u8, variant, "b")) {
            document_of_b = document;
        } else {
            others[count] = document;
            count += 1;
        }
    }
    for (others[0..count]) |document| {
        const compare = b.addSystemCommand(&.{"cmp"});
        compare.addFileArg(document_of_b.?);
        compare.addFileArg(document);
        smoke.dependOn(&compare.step);
    }
}
