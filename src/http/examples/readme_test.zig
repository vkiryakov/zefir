//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, after the program, no Zig code that is not a
//! part of these files, and of an error of zefir's checks at compile time
//! only a message that a probe of zefir-http expects: a file that changes
//! without its copy in README.md, a program that prints something else, or
//! a message that changes, fails this test. build.zig embeds what each
//! program printed in this build as `<name>.out`, and README.md of the
//! repository as `root_readme`, and gives the list of probes of zefir-http
//! as `http-cases`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");
const http_cases = @import("http-cases");

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

test "every error of zefir's checks that README.md shows is the message of a probe" {
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, guide, '\n');
    while (lines.next()) |raw| {
        // Git may check files out with CRLF on Windows.
        const line = std.mem.trimEnd(u8, raw, "\r");
        // The compiler shows an error of zefir's checks at a line of
        // zefir: `error: zefir.http: …`.
        const marker = "error: ";
        if (!std.mem.startsWith(u8, line, marker ++ "zefir.")) continue;
        const message = line[marker.len..];
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
