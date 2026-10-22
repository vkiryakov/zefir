//! README.md, the guide of zefir.App, shows every file of the shop as it
//! is, the run of stuck.zig as it printed, each compile check of App it
//! names with the message App gives, and no Zig code that is not a part of
//! these files: a file that changes without its copy in README.md, or a
//! message of App that changes, fails this test. build.zig gives it the
//! checks of the guides (`guide-check`), the list of App's compile checks
//! (`app-cases`), the files of those it shows (`fixture-<name>`), and what
//! stuck.zig printed (`stuck.err`).

const std = @import("std");
const check = @import("guide-check");
const app_cases = @import("app-cases");
const cases = @import("cases.zig");

const testing = std.testing;
const guide = @embedFile("README.md");

/// The files whose parts README.md may show.
const shown_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.files) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    for (cases.fixtures) |name| files = files ++ &[_][]const u8{@embedFile("fixture-" ++ name)};
    break :files files;
};

test "README.md shows every file of the shop as it is" {
    inline for (cases.files) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
}

test "README.md shows the run of stuck.zig as it printed, after the program" {
    try check.expectRun("README.md", guide, @embedFile("stuck.zig"), cases.stuck_command, @embedFile("stuck.err"));
}

test "README.md shows each compile check it names, and the message App gives it right after" {
    inline for (cases.fixtures) |name| {
        const file = @embedFile("fixture-" ++ name);
        try check.expectFile("README.md", guide, "zig", file);
        try expectMessageAfter(file, comptime messageOf(name));
    }
    inline for (cases.messages) |name| try check.expectBlock("README.md", guide, comptime messageBlock(messageOf(name)));
}

test "every Zig block of README.md but those of build.zig is a part of a file of the shop or of a check it shows" {
    try check.expectZigFromExamples("README.md", guide, shown_files);
}

/// The message that App's compile check `name` fails with, as
/// src/core/app/tests/cases.zig holds it.
fn messageOf(comptime name: []const u8) []const u8 {
    for (app_cases.compile_errors) |fixture| {
        if (std.mem.endsWith(u8, fixture.file, "/" ++ name ++ ".zig")) return fixture.expect;
    }
    @compileError("no compile check " ++ name ++ " in src/core/app/tests/cases.zig");
}

/// The block README.md shows a message in, as the compiler prints it.
fn messageBlock(comptime message: []const u8) []const u8 {
    return "```text\nerror: " ++ message ++ "\n```\n";
}

/// Fails unless the block right after the one that shows `file` whole is
/// `message`.
fn expectMessageAfter(file: []const u8, comptime message: []const u8) !void {
    const text = try std.mem.replaceOwned(u8, testing.allocator, guide, "\r\n", "\n");
    defer testing.allocator.free(text);
    const program = try std.mem.replaceOwned(u8, testing.allocator, file, "\r\n", "\n");
    defer testing.allocator.free(program);
    const shown = try std.mem.concat(testing.allocator, u8, &.{ "```zig\n", program, "```\n\n" });
    defer testing.allocator.free(shown);
    const at = std.mem.find(u8, text, shown) orelse return error.TestFileNotInGuide;
    if (!std.mem.startsWith(u8, text[at + shown.len ..], messageBlock(message))) {
        std.debug.print("README.md does not show this message right after its check:\n{s}", .{messageBlock(message)});
        return error.TestMessageNotInGuide;
    }
}
