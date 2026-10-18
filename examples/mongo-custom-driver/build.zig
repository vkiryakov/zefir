//! minidriver: a MongoDB driver for zefir-mongo in a package of its own.
//!
//!   zig build test   the conformance suite of zefir-mongo on the driver,
//!                    with the zefir that build.zig.zon pins (fetched the
//!                    first time); until it pins a release with
//!                    zefir-mongo, the step says so and fails
//!
//! The module `mongo-minidriver` imports `zefir-mongo` and `zefir-core`, and
//! the application gives them from its own zefir dependency (README.md).
//! consumer/ is such an application, against this checkout.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No imports here: they come from the application.
    const minidriver = b.addModule("mongo-minidriver", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The package's own tests, only when it is built by itself: an
    // application that depends on it never fetches the zefir below.
    const test_step = b.step("test", "Run the conformance suite on the driver");
    if (!b.isRoot()) return;
    const zefir = b.lazyDependency("zefir", .{ .target = target, .optimize = optimize }) orelse return;
    // A release of zefir before zefir-mongo has no such module, and
    // `module` would stop the build with a panic: fail the step with what
    // to do instead.
    const mongo = zefir.builder.modules.get("zefir-mongo") orelse {
        const missing = b.addFail("the zefir that build.zig.zon pins has no zefir-mongo, which came after that release: " ++
            "run `zig build test` in consumer/, against the zefir around this package, or pin a release with zefir-mongo");
        test_step.dependOn(&missing.step);
        return;
    };
    minidriver.addImport("zefir-mongo", mongo);
    minidriver.addImport("zefir-core", zefir.module("zefir-core"));
    const tests = b.addTest(.{ .root_module = minidriver });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
