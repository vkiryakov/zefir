//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, and no Zig code that is not a
//! part of these files: a file that changes without its copy in README.md,
//! or a program that prints something else, fails this test. build.zig
//! embeds what each program printed as `<name>.out`, and README.md of the
//! repository as `root_readme`.

const std = @import("std");
const cases = @import("cases");
const check = @import("guide_check.zig");

const guide = @embedFile("README.md");

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.programs) |program| files = files ++ &[_][]const u8{@embedFile(program.name ++ ".zig")};
    for (cases.files) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

test "README.md shows every file of the examples as it is" {
    inline for (cases.programs) |program| try check.expectFile("README.md", guide, "zig", @embedFile(program.name ++ ".zig"));
    inline for (cases.files) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "README.md shows a run of every program as it printed, after the program" {
    inline for (cases.programs) |program| {
        try check.expectRun("README.md", guide, @embedFile(program.name ++ ".zig"), cases.command(program), @embedFile(program.name ++ ".out"));
    }
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test "README.md of the repository shows its examples of rpc and their runs" {
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| {
        try check.expectFile("README.md of the repository", root, "zig", @embedFile(name ++ ".zig"));
        const program = comptime for (cases.programs) |program| {
            if (std.mem.eql(u8, program.name, name)) break program;
        } else unreachable;
        try check.expectRun("README.md of the repository", root, @embedFile(name ++ ".zig"), cases.command(program), @embedFile(name ++ ".out"));
    }
}

test {
    _ = check;
}
