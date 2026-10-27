//! An application of the mailbox transport, built as section 13 of the rpc
//! specification says: the transport's module gets zefir-rpc and
//! zefir-core from the application's zefir. CI runs it.
//!
//!   zig build test   the conformance suite on the transport, its own
//!                    checks, rpc.Server and rpc.Client over it, the tests
//!                    of the transport's package itself, and the check of
//!                    the package's README.md

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
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zefir-core", .module = zefir.module("zefir-core") },
        .{ .name = "zefir-rpc", .module = zefir.module("zefir-rpc") },
        .{ .name = "rpc-mailbox", .module = mailbox_module },
    };

    const test_step = b.step("test", "Run the tests of the transport as an application builds it");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The tests in the transport's own files, against this zefir: those of
    // another module do not run with the tests above.
    const package_tests = b.addTest(.{ .name = "rpc-mailbox", .root_module = mailbox_module });
    test_step.dependOn(&b.addRunArtifact(package_tests).step);

    // README.md of the transport's package shows parts of this build.zig,
    // of the tests above and of the transport, and the report of the
    // conformance suite. A test embeds no file outside the directory of its
    // module, so those files come to it as anonymous imports, under their
    // names; the checks come from the guide of rpc in zefir.
    const readme = b.addTest(.{
        .name = "readme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/readme_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    readme.root_module.addImport("guide-check", b.createModule(.{
        .root_source_file = zefir.path("src/rpc/examples/guide_check.zig"),
        .target = target,
        .optimize = optimize,
    }));
    readme.root_module.addAnonymousImport("README.md", .{ .root_source_file = mailbox.path("README.md") });
    readme.root_module.addAnonymousImport("build.zig", .{ .root_source_file = b.path("build.zig") });
    readme.root_module.addAnonymousImport("root.zig", .{ .root_source_file = mailbox.path("src/root.zig") });
    test_step.dependOn(&b.addRunArtifact(readme).step);

    // A safe build checks that a call comes on the std.Io of connect: on
    // another, it panics. The program ends in its own panic handler, which
    // exits with 3 instead of aborting.
    if (optimize == .debug or optimize == .safe) {
        const another_io = b.addExecutable(.{
            .name = "another-io",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/another_io.zig"),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        const run = b.addRunArtifact(another_io);
        run.expectStdErrMatch("panic: rpc-mailbox: Client.call with another std.Io than connect's; pass the io the client connected on");
        // expectStdErrMatch accepts any exit: only the panic handler exits
        // with 3, so a program that printed the text and returned fails.
        run.expectExitCode(3);
        test_step.dependOn(&run.step);
    }
}
