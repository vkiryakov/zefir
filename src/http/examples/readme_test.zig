//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, and no Zig code that is not a
//! part of these files: a file that changes without its copy in README.md,
//! or a program that prints something else, fails this test. build.zig
//! embeds what each program printed in this build as `<name>.out`, and
//! README.md of the repository as `root_readme`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");

const guide = @embedFile("README.md");

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.programs ++ cases.files) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

test "README.md shows every file of the examples as it is" {
    inline for (cases.programs ++ cases.files) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
    inline for (cases.other_files) |file| try check.expectFile("README.md", guide, file[1], @embedFile(file[0]));
}

test "README.md shows a run of every program as it printed, after the program" {
    inline for (cases.programs) |name| {
        try check.expectRun("README.md", guide, @embedFile(name ++ ".zig"), cases.command, @embedFile(name ++ ".out"));
    }
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test "README.md of the repository shows http in a minute and its run" {
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| {
        try check.expectFile("README.md of the repository", root, "zig", @embedFile(name ++ ".zig"));
        try check.expectRun("README.md of the repository", root, @embedFile(name ++ ".zig"), cases.command, @embedFile(name ++ ".out"));
    }
}

test {
    _ = check;
}
