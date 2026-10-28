//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, no Zig code that is not a
//! part of these files, of an error of the compiler only
//! a message that a probe of zefir-http expects, and of the Debug check
//! only a line that a test of its check.zig makes: a file that changes
//! without its copy in README.md, a program that prints something else, or
//! a message or a line that changes, fails this test. build.zig embeds
//! what each program printed in this build as `<name>.out`, and README.md
//! of the repository as `root_readme`, and gives the list of probes of
//! zefir-http as `http-cases` and the lines of its Debug check as
//! `http-check-lines`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");
const http_cases = @import("http-cases");
const check_lines = @import("http-check-lines");

const testing = std.testing;
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

test "every error of the compiler that README.md shows is the message of a probe" {
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, guide, '\n');
    while (lines.next()) |raw| {
        // Git may check files out with CRLF on Windows.
        const line = std.mem.trimEnd(u8, raw, "\r");
        const message = check.compileError(line) orelse continue;
        shown += 1;
        if (isProbed(message)) continue;
        std.debug.print("README.md shows an error that no probe of src/http/tests/cases.zig expects:\n{s}\n", .{message});
        return error.TestErrorNotProbed;
    }
    try testing.expect(shown > 0);
}

/// Whether a probe of zefir-http expects `message`.
fn isProbed(message: []const u8) bool {
    for (http_cases.compile_errors) |probe| {
        if (std.mem.eql(u8, probe.expect, message)) return true;
    }
    return false;
}

test "every line of the Debug check that README.md shows is one that a test of check.zig makes" {
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, guide, '\n');
    while (lines.next()) |raw| {
        // Git may check files out with CRLF on Windows.
        const line = std.mem.trimEnd(u8, raw, "\r");
        // Every line that holds a line of the check, at its start or not,
        // but an error of the compiler, which the test above checks.
        if (std.mem.find(u8, line, "zefir.http: ") == null or check.compileError(line) != null) continue;
        shown += 1;
        if (isCheckLine(line)) continue;
        std.debug.print("README.md shows a line of the Debug check that src/http/tests/check_lines.zig does not hold, so no test of check.zig makes it:\n{s}\n", .{line});
        return error.TestLineNotChecked;
    }
    try testing.expect(shown > 0);
}

/// Whether `line` is one of the lines that a test of check.zig makes.
fn isCheckLine(line: []const u8) bool {
    for (check_lines.lines) |made| {
        if (std.mem.eql(u8, made.text, line)) return true;
    }
    return false;
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
