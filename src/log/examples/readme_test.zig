//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, the calls that must not
//! compile with the errors the build gives for them, and no other Zig code
//! that is not a part of these files: a file that changes without its copy
//! in README.md, or a program that prints something else, fails this test.
//! build.zig embeds what each program printed in this build, on stdout as
//! `<name>.out` and on stderr as `<name>.err`, and README.md of the
//! repository as `root_readme`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");

const guide = @embedFile("README.md");

/// The files of the examples: README.md may show any part of them.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.programs ++ cases.compiled) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    break :files files;
};

/// What the program `name` printed, as a terminal shows it: its records on
/// stdout, then what it printed on stderr. Every program prints to stderr
/// only once its records are out, so this is their order on the screen.
fn printed(comptime name: []const u8) []const u8 {
    return @embedFile(name ++ ".out") ++ @embedFile(name ++ ".err");
}

test "README.md shows every file of the examples as it is" {
    inline for (cases.programs ++ cases.compiled) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "README.md shows a run of every program as it printed, after the program" {
    inline for (cases.programs) |name| {
        try check.expectRun("README.md", guide, @embedFile(name ++ ".zig"), cases.command, printed(name));
    }
}

test "the emergency record goes to stderr, and stdout gets nothing" {
    try std.testing.expectEqualStrings("", @embedFile("emergency.out"));
}

test "README.md shows the lines of the run of config.zig that it quotes as the run printed them" {
    const masked_guide = try check.mask(guide);
    defer std.testing.allocator.free(masked_guide);
    var run: [4][]const u8 = undefined;
    var lines = std.mem.splitScalar(u8, @embedFile("config.out"), '\n');
    for (&run) |*line| line.* = lines.next() orelse return error.TestUnexpectedResult;
    // The record of std.log, the configuration and the paid invoice; the
    // keys of the vault are shown formatted.
    for ([_][]const u8{ run[0], run[1], run[3] }) |line| {
        const record = try check.mask(line);
        defer std.testing.allocator.free(record);
        const block = try std.mem.concat(std.testing.allocator, u8, &.{ "```json\n", record, "\n```\n" });
        defer std.testing.allocator.free(block);
        try check.expectBlock("README.md", masked_guide, block);
    }
}

test "every Zig block of README.md but those of build.zig and the calls that do not compile is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test "README.md shows the calls that do not compile as compile_errors.zig has them, and the errors the build gives" {
    const fixtures = @embedFile("compile_errors.zig");
    comptime var code: []const u8 = "```zig\n";
    comptime var errors: []const u8 = "```text\n";
    inline for (cases.compile_errors) |e| {
        if (!try check.isPartOf(fixtures, e.line)) {
            std.debug.print("compile_errors.zig has no line\n{s}\n", .{e.line});
            return error.TestLineNotInFixtures;
        }
        code = code ++ e.line ++ "\n";
        errors = errors ++ "error: " ++ e.text ++ "\n";
    }
    try check.expectBlock("README.md", guide, code ++ "```\n");
    try check.expectBlock("README.md", guide, errors ++ "```\n");
}

test "README.md of the repository shows log in a minute and its run" {
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| {
        try check.expectFile("README.md of the repository", root, "zig", @embedFile(name ++ ".zig"));
        try check.expectRun("README.md of the repository", root, @embedFile(name ++ ".zig"), cases.command, printed(name));
    }
}

test {
    _ = check;
}
