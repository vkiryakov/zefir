const std = @import("std");

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

    // Umbrella module: @import("zefir").core, .logger, .confy, .rpc, .orm
    const zefir = b.addModule("zefir", .{
        .root_source_file = b.path("src/zefir.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "logger", .module = logger },
            .{ .name = "confy", .module = confy },
            .{ .name = "rpc", .module = rpc },
            .{ .name = "orm", .module = orm },
        },
    });

    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ core, logger, confy, rpc, orm, zefir }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // core examples: `zig build test` builds and runs them; an example that
    // exits with an error fails the step.
    for ([_][]const u8{ "http_handler", "rpc_handler" }) |name| {
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
}
