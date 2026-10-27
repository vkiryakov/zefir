//! README.md, the guide of zefir-validator, shows every example of
//! `cases.examples` and rules.zig as they are, and a run of every example
//! program; README.md and the other pages of the guide show no Zig code that
//! is not a part of their examples: an example that changes without its copy
//! in the guide fails this test. README.md may show parts of the examples
//! and of fragments_test.zig, and the pages parts of pages_test.zig and of
//! strings.zig of the validator (the options of v.strongPassword). A test
//! embeds no file outside the directory of its module, so build.zig hands
//! strings.zig to this test as an anonymous import, under its name.

const std = @import("std");
const cases = @import("cases");
const check = @import("guide_check.zig");

const readme = @embedFile("README.md");

/// The pages of the guide besides README.md: the rule pages, and the page
/// for readers who know class-validator.
const pages = .{ "common.md", "numbers.md", "strings.md", "formats.md", "encodings.md", "identifiers.md", "dates.md", "lists.md", "class_validator.md" };

/// The files whose parts README.md may show.
const readme_files = files: {
    var files: []const []const u8 = &.{ @embedFile("fragments_test.zig"), @embedFile("rules.zig") };
    for (cases.examples) |example| files = files ++ &[_][]const u8{@embedFile(example.name ++ ".zig")};
    break :files files;
};

/// The files whose parts the pages may show.
const page_files: []const []const u8 = &.{ @embedFile("pages_test.zig"), @embedFile("strings.zig") };

/// Fails unless README.md shows a run of a program that logs `records`: a
/// ```text block of `$ zig build run` and then the lines of `records`, in
/// order, each after a timestamp and a space. The timestamps of a run are
/// its own, so the block may show any.
fn expectRunInReadme(records: []const u8) !void {
    const gpa = std.testing.allocator;
    const doc = try std.mem.replaceOwned(u8, gpa, readme, "\r\n", "\n");
    defer gpa.free(doc);
    const start = "```text\n$ zig build run\n";
    var rest: []const u8 = doc;
    while (std.mem.find(u8, rest, start)) |at| {
        const body = rest[at + start.len ..];
        const end = std.mem.find(u8, body, "```\n") orelse break;
        if (check.showsRecords(body[0..end], records)) return;
        rest = body[end..];
    }
    std.debug.print("README.md shows no run that logs these records, each after a timestamp:\n{s}\n", .{records});
    return error.TestRunNotInReadme;
}

test "README.md shows every example file and rules.zig as they are" {
    inline for (cases.examples) |example| {
        try check.expectFile("README.md", readme, "zig", @embedFile(example.name ++ ".zig"));
    }
    try check.expectFile("README.md", readme, "zig", @embedFile("rules.zig"));
}

test "README.md shows a run of every example program" {
    inline for (cases.examples) |example| {
        if (example.records) |records| try expectRunInReadme(records);
    }
}

test "every Zig block of README.md but its build.zig and the code that must not compile is a part of an example" {
    try check.expectZigFromExamples("README.md", readme, readme_files);
}

test "every page shows an example, and every Zig block of a page is a part of pages_test.zig or of strings.zig" {
    inline for (pages) |page| {
        const doc = @embedFile(page);
        if (std.mem.find(u8, doc, "```zig") == null) {
            std.debug.print("{s} shows no example\n", .{page});
            return error.TestPageWithoutExample;
        }
        try check.expectZigFromExamples(page, doc, page_files);
    }
}

test {
    _ = check;
}
