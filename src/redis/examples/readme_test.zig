//! README.md shows every file of the examples as it is, and no Zig code
//! that is not a part of these files: a file that changes without its copy
//! in README.md fails this test. tests/redis checks the runs of the
//! programs, which need a server.

const cases = @import("cases.zig");
const check = @import("guide_check.zig");

const guide = @embedFile("README.md");

const all = cases.server_programs ++ cases.tests ++ cases.files;

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (all) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

test "README.md shows every file of the examples as it is" {
    inline for (all) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test {
    _ = check;
}
