//! README.md shows every file of the examples as it is, a run of every
//! program without a server as it printed, after the program, no Zig code
//! that is not a part of these files, and each compile error of the
//! scheduler that it quotes as a compile check of the scheduler gives it:
//! a file that changes without its copy in README.md, a program that
//! prints something else, or a message of the scheduler that changes,
//! fails this test. build.zig embeds what each program printed in this
//! build as `<name>.out`, the compile checks of the scheduler as
//! `scheduler-cases`, and README.md of the repository, whose "scheduler in
//! a minute" is the quick start, as `root_readme`. tests/scheduler checks
//! the runs of the programs that need mongod.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");
const scheduler_cases = @import("scheduler-cases");

const guide = @embedFile("README.md");

const all = cases.programs ++ cases.server_programs ++ cases.tests ++ cases.files;

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (all) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

test "README.md shows every file of the examples as it is" {
    inline for (all) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "README.md shows a run of every program without a server as it printed, after the program" {
    inline for (cases.programs) |name| {
        try check.expectRun("README.md", guide, @embedFile(name ++ ".zig"), cases.command, @embedFile(name ++ ".out"));
    }
}

test "every compile error of the scheduler that README.md quotes is one that a compile check gives" {
    var lines = std.mem.splitScalar(u8, guide, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, text, "error: scheduler")) continue;
        for (scheduler_cases.compile_errors) |fixture| {
            if (std.mem.eql(u8, text["error: ".len..], fixture.expect)) break;
        } else {
            std.debug.print("README.md quotes an error that no compile check of the scheduler gives:\n{s}\n", .{text});
            return error.TestErrorWithoutCheck;
        }
    }
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test "README.md of the repository shows scheduler in a minute and its run" {
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| {
        try check.expectFile("README.md of the repository", root, "zig", @embedFile(name ++ ".zig"));
        try check.expectRun("README.md of the repository", root, @embedFile(name ++ ".zig"), cases.command, @embedFile(name ++ ".out"));
    }
}

test {
    _ = check;
}
