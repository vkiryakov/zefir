//! README.md, the guide of zefir-openapi, against what it shows: every file
//! of the small application as it is, and its openapi.json; Zig code only
//! from those files and from the service of the guide of zefir-http; JSON
//! only from their documents and from the golden documents of the tests;
//! and of an error of the compiler, only a message that a probe of
//! zefir-openapi or zefir-http expects. A file, a document or a message that
//! changes without its copy in README.md fails this test. build.zig gives
//! what lives elsewhere as modules: the files of the http guide as
//! `http-<name>`, its document as `http-openapi.json`, the golden documents
//! as `golden-<name>`, the lists of probes as `openapi-cases` and
//! `http-cases`, and the checks of the http guide as `guide-check`.

const std = @import("std");
const cases = @import("cases.zig");
const check = @import("guide-check");
const openapi_cases = @import("openapi-cases");
const http_cases = @import("http-cases");

const testing = std.testing;
const guide = @embedFile("README.md");

/// The Zig files that README.md may show parts of.
const zig_files = files: {
    var files: []const []const u8 = &.{};
    for (cases.files) |name| files = files ++ &[_][]const u8{@embedFile(name ++ ".zig")};
    for (cases.http_files) |name| files = files ++ &[_][]const u8{@embedFile("http-" ++ name)};
    break :files files;
};

/// The documents that README.md may show parts of.
const documents = docs: {
    var docs: []const []const u8 = &.{ @embedFile("openapi.json"), @embedFile("http-openapi.json") };
    for (cases.golden) |name| docs = docs ++ &[_][]const u8{@embedFile("golden-" ++ name)};
    break :docs docs;
};

test "README.md shows every file of the application, and its openapi.json, as they are" {
    inline for (cases.files) |name| try check.expectFile("README.md", guide, "zig", @embedFile(name ++ ".zig"));
    try check.expectFile("README.md", guide, "json", @embedFile("openapi.json"));
}

test "every Zig block of README.md but those of build.zig is a part of the application or of the http guide's service" {
    try check.expectZigFromExamples("README.md", guide, zig_files);
}

test "every JSON block of README.md is a part of a document it shows" {
    const text = try unixLines(guide);
    defer testing.allocator.free(text);
    var shown: usize = 0;
    var blocks = Blocks{ .rest = text, .open = "```json\n" };
    while (try blocks.next()) |block| {
        shown += 1;
        for (documents) |doc| {
            const lines = try unixLines(doc);
            defer testing.allocator.free(lines);
            if (try check.isPartOf(lines, block)) break;
        } else {
            std.debug.print("README.md shows JSON that is not a part of a document, its lines in order:\n{s}\n", .{block});
            return error.TestBlockNotFromDocuments;
        }
    }
    try testing.expect(shown > 0);
}

test "every error of the compiler that README.md shows is the message of a probe" {
    const text = try unixLines(guide);
    defer testing.allocator.free(text);
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const message = compileError(line) orelse continue;
        shown += 1;
        if (isProbed(message)) continue;
        std.debug.print("README.md shows an error that no probe of src/openapi/tests/cases.zig or src/http/tests/cases.zig expects:\n{s}\n", .{message});
        return error.TestErrorNotProbed;
    }
    try testing.expect(shown > 0);
}

/// The message of an error of the compiler on `line`: after `error: ` of
/// `<file>.zig:<line>:<column>: error: `, or of `error: zefir.`, an error of
/// zefir's own checks, which the compiler shows at a line of zefir. Null for
/// any other line, such as the `error: …` of a test that failed.
fn compileError(line: []const u8) ?[]const u8 {
    const marker = "error: ";
    if (std.mem.startsWith(u8, line, marker ++ "zefir.")) return line[marker.len..];
    const at = std.mem.find(u8, line, ": " ++ marker) orelse return null;
    // `<file>.zig:<line>:<column>` before it.
    var parts = std.mem.splitBackwardsScalar(u8, line[0..at], ':');
    const column = parts.next() orelse return null;
    const number = parts.next() orelse return null;
    const file = parts.rest();
    if (!std.mem.endsWith(u8, file, ".zig") or !allDigits(column) or !allDigits(number)) return null;
    return line[at + 2 + marker.len ..];
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Whether a probe of zefir-openapi or zefir-http expects `message`.
fn isProbed(message: []const u8) bool {
    for (openapi_cases.compile_errors) |probe| {
        if (std.mem.eql(u8, probe.expect, message)) return true;
    }
    for (http_cases.compile_errors) |probe| {
        if (std.mem.eql(u8, probe.expect, message)) return true;
    }
    return false;
}

/// The blocks of one language of a Markdown text, each without its fences.
const Blocks = struct {
    rest: []const u8,
    open: []const u8,

    fn next(b: *Blocks) !?[]const u8 {
        const at = std.mem.find(u8, b.rest, b.open) orelse return null;
        const body = b.rest[at + b.open.len ..];
        // A block closes at the first line that starts with its fence.
        const end = if (std.mem.startsWith(u8, body, "```")) 0 else (std.mem.find(u8, body, "\n```") orelse return error.TestUnclosedBlock) + 1;
        b.rest = body[end..];
        return body[0..end];
    }
};

/// `text` with "\n" for "\r\n": Git may check files out with CRLF on Windows.
fn unixLines(text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, testing.allocator, text, "\r\n", "\n");
}

test "an error of the compiler is one at a line of a Zig file, or one of zefir's checks" {
    try testing.expectEqualDeep(@as(?[]const u8, "missing struct field: summary"), compileError("src/TodosController.zig:25:26: error: missing struct field: summary"));
    try testing.expectEqualDeep(@as(?[]const u8, "zefir.openapi: x"), compileError("error: zefir.openapi: x"));
    try testing.expectEqual(null, compileError("error: openapi.json is out of date; run `zig build openapi`"));
    try testing.expectEqual(null, compileError("src/Service.zig:28:60: note: called at comptime here"));
    try testing.expectEqual(null, compileError("a line that says error: something"));
}
