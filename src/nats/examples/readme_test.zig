//! README.md shows every program of the examples as it is, and no Zig code
//! that is not a part of the examples: a file that changes without its
//! copy in README.md fails this test. README.md of the repository, which
//! build.zig embeds as `root_readme`, shows its "nats in a minute" as it
//! is. The programs need a NATS server: tests/nats runs them, and checks
//! that both show their runs as they printed.

const cases = @import("cases.zig");
const check = @import("guide_check.zig");

const guide = @embedFile("README.md");

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.programs) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    for (cases.files) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

test "README.md shows every program of the examples as it is" {
    inline for (cases.programs) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test "README.md of the repository shows nats in a minute as it is" {
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| try check.expectFile("README.md of the repository", root, "zig", @embedFile(name ++ ".zig"));
}

test {
    _ = check;
}
