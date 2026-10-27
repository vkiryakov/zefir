//! The pages of the confy guide show every file of the examples as it is,
//! a run of every program as it printed, after the program, every problem
//! and compile error as confy and the compiler write them, and no Zig code
//! that is not a part of these files: a file that changes without its copy
//! in a page, or a program that prints something else, fails this test.
//! build.zig embeds what each run of a program printed as
//! `<name>.<run>.err`, and README.md of the repository as `root_readme`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide_check.zig");

const testing = std.testing;

/// The files whose parts the pages may show: the programs, the tests and
/// the code that must not compile.
const example_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.programs) |program| files = files ++ &[_][]const u8{@embedFile(program.name ++ ".zig")};
    for (cases.tests) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    for (cases.compile_errors) |code| files = files ++ &[_][]const u8{@embedFile("compile_errors/" ++ code.name ++ ".zig")};
    break :files files;
};

test "every Zig block of the pages but those of build.zig is a part of an example" {
    inline for (cases.pages) |page| try check.expectZigFromExamples(page, @embedFile(page), example_files);
}

test "every program is shown whole, with the files it reads, and each run after it as it printed" {
    inline for (cases.programs) |program| try expectProgram(program.page, @embedFile(program.page), program);
}

test "README.md of the repository shows its programs, their files and their runs" {
    inline for (cases.root_readme) |name| {
        const program = comptime for (cases.programs) |program| {
            if (std.mem.eql(u8, program.name, name)) break program;
        } else unreachable;
        try expectProgram("README.md of the repository", @embedFile("root_readme"), program);
    }
}

/// Fails unless the document `name`, `doc`, shows `program` whole, each
/// file it reads whole, and a run of each of its runs after it.
fn expectProgram(name: []const u8, doc: []const u8, comptime program: cases.Program) !void {
    const file = @embedFile(program.name ++ ".zig");
    try check.expectFile(name, doc, "zig", file);
    inline for (program.files) |path| {
        const dir = program.dir orelse @compileError(program.name ++ " reads files but has no directory");
        try check.expectFile(name, doc, cases.language(path), @embedFile("testdata/" ++ dir ++ "/" ++ path));
    }
    inline for (program.runs, 0..) |run, i| {
        const output = @embedFile(std.fmt.comptimePrint("{s}.{d}.err", .{ program.name, i }));
        try check.expectRun(name, doc, file, cases.command(run), output);
    }
}

test "every file that a test loads is shown whole on its page" {
    inline for (cases.fixtures) |fixture| {
        try check.expectFile(fixture.page, @embedFile(fixture.page), cases.language(fixture.path), @embedFile("testdata/" ++ fixture.path));
    }
}

test "every page shows its problems as confy writes them" {
    inline for (cases.shown_problems) |problems| {
        const block = "```text\n" ++ (if (problems.logged) "error(confy): " else "") ++ problems.text ++ "\n```\n";
        try check.expectBlock(problems.page, @embedFile(problems.page), block);
    }
}

test "every page shows the message of its code that must not compile" {
    inline for (cases.compile_errors) |code| {
        try check.expectBlock(code.page, @embedFile(code.page), "```text\nerror: " ++ code.expect ++ "\n```\n");
    }
}

test "the tests that copy the Config of a program hold it as the program does" {
    inline for (cases.config_copies) |pair| {
        const copy = try configOf(@embedFile(pair[0] ++ ".zig"));
        const original = try configOf(@embedFile(pair[1] ++ ".zig"));
        testing.expectEqualStrings(original, copy) catch |err| {
            std.debug.print("the Config of {s}.zig is not the one of {s}.zig\n", .{ pair[0], pair[1] });
            return err;
        };
    }
}

/// The declaration of `Config` in `file`, from its first line to the line
/// that closes it.
fn configOf(file: []const u8) ![]const u8 {
    const start = std.mem.find(u8, file, "\nconst Config = struct {") orelse return error.TestNoConfig;
    const end = std.mem.findPos(u8, file, start, "\n};") orelse return error.TestNoConfig;
    return file[start + 1 .. end + 3];
}

test {
    _ = check;
}
