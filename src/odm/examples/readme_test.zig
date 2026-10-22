//! README.md shows every file of the examples as it is, a run of every
//! program without a server as it printed, after the program, no Zig code
//! that is not a part of these files, and each compile error of odm that
//! it quotes as a compile check of odm gives it: a file that changes
//! without its copy in README.md, a program that prints something else,
//! or a message of odm that changes, fails this test. build.zig embeds
//! what each program printed in this build as `<name>.out`, and the
//! compile checks of odm as `odm-cases`. tests/odm checks the runs of the
//! programs that need mongod.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");
const odm_cases = @import("odm-cases");

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

test "README.md shows each compile error of odm that it quotes, as its compile check gives it" {
    inline for (odm_cases.guide_errors) |e| {
        if (std.mem.find(u8, guide, "error: " ++ e.text) == null) {
            std.debug.print("README.md does not show this error of the compile check \"{s}\":\nerror: {s}\n", .{ e.name, e.text });
            return error.TestErrorNotInGuide;
        }
    }
    // And every one that it quotes has its check.
    var lines = std.mem.splitScalar(u8, guide, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, text, "error: odm")) continue;
        inline for (odm_cases.guide_errors) |e| {
            if (std.mem.eql(u8, text, "error: " ++ e.text)) break;
        } else {
            std.debug.print("README.md quotes an error that no compile check of odm gives:\n{s}\n", .{text});
            return error.TestErrorWithoutCheck;
        }
    }
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    try check.expectZigFromExamples("README.md", guide, example_files);
}

test {
    _ = check;
}
