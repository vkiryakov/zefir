//! An application of minidriver, built the way an application of zefir
//! builds a driver of its own: the driver's module gets zefir-mongo and
//! zefir-core from the application's zefir, here this checkout. CI runs it.
//!
//!   zig build test                  the conformance suite of zefir-mongo on
//!                                   the driver (layer S), the code of the
//!                                   application on mongo.testing.FakeDriver,
//!                                   and the tests of the driver's package
//!   zig build test -Dlive-uri=mongodb://127.0.0.1:27117
//!                                   besides, against that mongod: layer L
//!                                   with fail points, so the mongod runs
//!                                   with enableTestCommands=1, the code of
//!                                   the application and the scenarios of
//!                                   the collection API on minidriver

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const live_uri = b.option([]const u8, "live-uri", "A mongod for the tests against a live server, started with enableTestCommands=1: mongodb://host:port");
    const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
    const minidriver = b.dependency("mongo_minidriver", .{ .target = target, .optimize = optimize });

    // One zefir in the build: the driver takes the application's.
    const core = zefir.module("zefir-core");
    const mongo = zefir.module("zefir-mongo");
    const minidriver_module = minidriver.module("mongo-minidriver");
    minidriver_module.addImport("zefir-mongo", mongo);
    minidriver_module.addImport("zefir-core", core);
    const options = b.addOptions();
    options.addOption(?[]const u8, "live_uri", live_uri);
    // The scenarios of the collection API that every driver of zefir runs,
    // from the end-to-end tests of this checkout.
    const crud_scenarios = b.createModule(.{
        .root_source_file = zefir.path("tests/mongo/e2e/crud_scenarios.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "mongo", .module = mongo },
        },
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zefir-core", .module = core },
        .{ .name = "zefir-mongo", .module = mongo },
        .{ .name = "mongo-minidriver", .module = minidriver_module },
        .{ .name = "build_options", .module = options.createModule() },
        .{ .name = "crud-scenarios", .module = crud_scenarios },
    };

    const test_step = b.step("test", "Run the tests of the driver as an application builds it");
    // The tests that may talk to the live mongod run one after another:
    // L7–L10 configure fail points, which a command of another test would
    // trip.
    var previous: ?*std.Build.Step = null;
    for ([_][]const u8{ "src/conformance_test.zig", "src/users_test.zig", "src/crud_test.zig" }) |path| {
        const tests = b.addTest(.{
            .name = std.fs.path.stem(path),
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        const run = b.addRunArtifact(tests);
        // The server is outside the build graph: with one, run every time.
        run.has_side_effects = live_uri != null;
        if (previous) |step| run.step.dependOn(step);
        previous = &run.step;
        test_step.dependOn(&run.step);
    }
    // The tests in the driver's own file, against this zefir: those of
    // another module do not run with the tests above.
    const package_tests = b.addTest(.{ .name = "mongo-minidriver", .root_module = minidriver_module });
    test_step.dependOn(&b.addRunArtifact(package_tests).step);

    // A safe build checks that a call comes on the std.Io of init: on
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
        run.expectStdErrMatch("panic: minidriver: a call with another std.Io than the client's; pass the io that init got");
        // expectStdErrMatch accepts any exit: only the panic handler exits
        // with 3, so a program that printed the text and returned fails.
        run.expectExitCode(3);
        test_step.dependOn(&run.step);
    }
}
