//! rpc-mailbox: a transport of zefir-rpc in a package of its own.
//!
//!   zig build test   the conformance suite of rpc on the transport, with
//!                    the zefir that build.zig.zon pins (fetched the first
//!                    time)
//!
//! The module `rpc-mailbox` imports `zefir-rpc` and `zefir-core`, and the
//! application gives them from its own zefir dependency (README.md).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No imports here: they come from the application.
    const mailbox = b.addModule("rpc-mailbox", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The package's own tests, only when it is built by itself: an
    // application that depends on it never fetches the zefir below.
    const test_step = b.step("test", "Run the conformance suite on the transport");
    if (!b.isRoot()) return;
    const zefir = b.lazyDependency("zefir", .{ .target = target, .optimize = optimize }) orelse return;
    mailbox.addImport("zefir-rpc", zefir.module("zefir-rpc"));
    mailbox.addImport("zefir-core", zefir.module("zefir-core"));
    const tests = b.addTest(.{ .root_module = mailbox });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
