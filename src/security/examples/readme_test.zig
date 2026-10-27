//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, the messages of the claims
//! that must not compile, and no Zig code that is not a part of these
//! files: a file that changes without its copy in README.md, or a program
//! that prints something else, fails this test. build.zig embeds what each
//! program printed in this build as `<name>.out`.

const std = @import("std");
const cases = @import("cases.zig");
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

test "README.md shows the messages of the claims that do not compile" {
    comptime var block: []const u8 = "```text\n";
    inline for (cases.compile_errors) |e| block = block ++ "error: " ++ e.expect ++ "\n";
    try check.expectBlock("README.md", guide, block ++ "```\n");
}

test {
    _ = check;
}
