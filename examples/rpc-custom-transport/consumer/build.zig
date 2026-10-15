//! An application of the mailbox transport, built as section 13 of the rpc
//! specification says: the transport's module gets zefir-rpc and
//! zefir-core from the application's zefir. CI runs it.
//!
//!   zig build test   the conformance suite on the transport, and
//!                    rpc.Server and rpc.Client over it

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const mailbox = b.dependency("rpc_mailbox", .{ .target = target, .optimize = optimize });

    // One zefir in the build: the transport takes the application's.
    const mailbox_module = mailbox.module("rpc-mailbox");
    mailbox_module.addImport("zefir-rpc", zefir.module("zefir-rpc"));
    mailbox_module.addImport("zefir-core", zefir.module("zefir-core"));

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefir-rpc", .module = zefir.module("zefir-rpc") },
                .{ .name = "rpc-mailbox", .module = mailbox_module },
            },
        }),
    });
    b.step("test", "Run the tests of the transport as an application builds it").dependOn(&b.addRunArtifact(tests).step);
}
