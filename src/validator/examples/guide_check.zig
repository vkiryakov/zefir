//! Checks of the guide of zefir-validator against its examples: that a page
//! of the guide shows a file as it is, and no Zig code that is not a part
//! of its examples, and that a run shows the records of a program and
//! nothing else. readme_test.zig and runs_test.zig run them. The checks of
//! a page compare texts with "\r\n" turned into "\n", since Git may check
//! files out with CRLF on Windows; `showsRecords` takes lines that end with
//! "\n" only.

const std = @import("std");

const testing = std.testing;

fn unixLines(text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, testing.allocator, text, "\r\n", "\n");
}

/// Fails unless the document `name`, `doc`, contains `block`.
pub fn expectBlock(name: []const u8, doc: []const u8, block: []const u8) !void {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const wanted = try unixLines(block);
    defer testing.allocator.free(wanted);
    if (std.mem.find(u8, text, wanted) == null) {
        std.debug.print("{s} does not contain this block:\n{s}\n", .{ name, wanted });
        return error.TestBlockNotInGuide;
    }
}

/// Fails unless the document `name`, `doc`, shows `file` whole, as a
/// ```<language> block.
pub fn expectFile(name: []const u8, doc: []const u8, language: []const u8, file: []const u8) !void {
    const block = try std.mem.concat(testing.allocator, u8, &.{ "```", language, "\n", file, "```\n" });
    defer testing.allocator.free(block);
    return expectBlock(name, doc, block);
}

/// Where the block that `body` begins closes: at the first line that
/// starts with "```", as in Markdown. A "```" inside a line, such as in a
/// doc comment of a file shown whole, does not close it.
fn closingFence(body: []const u8) ?usize {
    if (std.mem.startsWith(u8, body, "```")) return 0;
    const at = std.mem.find(u8, body, "\n```") orelse return null;
    return at + 1;
}

/// Fails unless every ```zig block of the document `name`, `doc`, is a part
/// of one of `files` (see `isPartOf`), but a block that starts with the
/// comment `// build.zig`, the build script of the reader's project, and
/// a block of code that must not compile, whose every line of code carries
/// the comment `// compile error: …` (see `mustNotCompile`).
pub fn expectZigFromExamples(name: []const u8, doc: []const u8, files: []const []const u8) !void {
    if (try foreignZig(doc, files)) |block| {
        defer testing.allocator.free(block);
        std.debug.print("{s} shows Zig code that is not a part of an example:\n{s}\n", .{ name, block });
        return error.TestBlockNotFromExamples;
    }
}

/// The first ```zig block of `doc` that is not a part of `files`, not a
/// build script and not code that must not compile, as a copy; null when
/// there is none.
fn foreignZig(doc: []const u8, files: []const []const u8) !?[]u8 {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const open = "```zig\n";
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, open)) |at| {
        const body = rest[at + open.len ..];
        const end = closingFence(body) orelse return error.TestUnclosedBlock;
        const block = body[0..end];
        rest = body[end + 3 ..];
        if (std.mem.startsWith(u8, block, "// build.zig")) continue;
        if (mustNotCompile(block)) continue;
        for (files) |file| {
            const lines = try unixLines(file);
            defer testing.allocator.free(lines);
            if (try isPartOf(lines, block)) break;
        } else return try testing.allocator.dupe(u8, block);
    }
    return null;
}

/// Whether `block` is code that the guide shows as wrong: it has a line of
/// code, and every line of code ends with the comment
/// `// compile error: …`, which says what the compiler reports there; blank
/// lines and comments on lines of their own are no code. Such code is no
/// part of a file that compiles.
fn mustNotCompile(block: []const u8) bool {
    var marked = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    while (lines.next()) |line| {
        const code = std.mem.trim(u8, line, " ");
        if (code.len == 0 or std.mem.startsWith(u8, code, "//")) continue;
        if (std.mem.find(u8, code, "// compile error: ") == null) return false;
        marked = true;
    }
    return marked;
}

/// Whether the lines of `block`, without their leading spaces, are lines
/// of `file` that follow each other, without theirs: a part of the file,
/// shown at another indentation.
pub fn isPartOf(file: []const u8, block: []const u8) !bool {
    var file_lines: std.ArrayList([]const u8) = .empty;
    defer file_lines.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, file, '\n');
    while (it.next()) |line| try file_lines.append(testing.allocator, std.mem.trimStart(u8, line, " "));
    var block_lines: std.ArrayList([]const u8) = .empty;
    defer block_lines.deinit(testing.allocator);
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    while (parts.next()) |line| try block_lines.append(testing.allocator, std.mem.trimStart(u8, line, " "));
    const lines = file_lines.items;
    const wanted = block_lines.items;
    if (wanted.len > lines.len) return false;
    var first: usize = 0;
    while (first + wanted.len <= lines.len) : (first += 1) {
        for (wanted, lines[first..][0..wanted.len]) |a, b| {
            if (!std.mem.eql(u8, a, b)) break;
        } else return true;
    }
    return false;
}

/// Whether the lines of `shown` are the lines of `records`, each after a
/// timestamp and a space.
pub fn showsRecords(shown: []const u8, records: []const u8) bool {
    var shown_lines = std.mem.splitScalar(u8, shown, '\n');
    var record_lines = std.mem.splitScalar(u8, records, '\n');
    while (record_lines.next()) |record| {
        const line = shown_lines.next() orelse return false;
        if (record.len == 0) {
            if (line.len != 0) return false;
            continue;
        }
        if (line.len != timestamp_form.len + 1 + record.len) return false;
        if (!isTimestamp(line[0..timestamp_form.len]) or line[timestamp_form.len] != ' ') return false;
        if (!std.mem.eql(u8, line[timestamp_form.len + 1 ..], record)) return false;
    }
    return shown_lines.next() == null;
}

/// The form of a zefir-log timestamp, such as 2026-10-13T09:41:07.415Z; `d`
/// stands for a digit.
const timestamp_form = "dddd-dd-ddTdd:dd:dd.dddZ";

fn isTimestamp(s: []const u8) bool {
    if (s.len != timestamp_form.len) return false;
    for (s, timestamp_form) |c, f| {
        if (if (f == 'd') !std.ascii.isDigit(c) else c != f) return false;
    }
    return true;
}

test "a run shows the records in order, each after a timestamp, and nothing else" {
    const records = "WARN  a\nWARN  b\n";
    try testing.expect(showsRecords("2026-10-13T09:41:07.415Z WARN  a\n2026-10-13T09:41:07.416Z WARN  b\n", records));
    try testing.expect(!showsRecords("2026-10-13T09:41:07.415Z WARN  a\n", records));
    try testing.expect(!showsRecords("2026-10-13T09:41:07.415Z WARN  a\n2026-10-13T09:41:07.416Z WARN  b\n2026-10-13T09:41:07.416Z WARN  c\n", records));
    try testing.expect(!showsRecords("2026-10-13T09:41:07.416Z WARN  b\n2026-10-13T09:41:07.415Z WARN  a\n", records));
    try testing.expect(!showsRecords("WARN  a\nWARN  b\n", records));
}

test "a block is a part of a file at any indentation, and nothing else is" {
    const file = "fn f() void {\n    const a = 1;\n    _ = a;\n}\n";
    try testing.expect(try isPartOf(file, "const a = 1;\n_ = a;\n"));
    try testing.expect(try isPartOf(file, "        const a = 1;\n"));
    try testing.expect(try isPartOf(file, file));
    try testing.expect(!try isPartOf(file, "const a = 2;\n"));
    try testing.expect(!try isPartOf(file, "_ = a;\nconst a = 1;\n"));
    try testing.expect(!try isPartOf(file, file ++ "extra\n"));
}

test "a block closes at a line that starts with its fence" {
    const file = "//! ```zig\n//! const a = 1;\n//! ```\nconst b = 2;\n";
    const doc = "```zig\n" ++ file ++ "```\n";
    try expectZigFromExamples("doc", doc, &.{file});
}

test "a guide passes when it shows the file and only parts of the file" {
    const file = "const x = 1;\nconst y = 2;\n";
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectZigFromExamples("doc", doc, &.{file});
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})) orelse return error.TestExpectedForeignBlock;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}

test "code that must not compile is a block of its own, marked on every line of code" {
    const file = "const x = 1;\n";
    const wrong = "```zig\n// a rule after a transform\n.email = .{ v.email, v.trim }, // compile error: transforms must come first\n```\n";
    try expectZigFromExamples("doc", wrong, &.{file});
    // A marker in a comment of its own marks nothing: the block is checked.
    const comment_only = "```zig\n// compile error: none\nconst z = 3;\n```\n";
    const foreign = (try foreignZig(comment_only, &.{file})) orelse return error.TestExpectedForeignBlock;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("// compile error: none\nconst z = 3;\n", foreign);
    // A line of code without the marker: the block is checked.
    const half = "```zig\n.a = v.rename(\"x\"),\n.b = v.rename(\"x\"), // compile error: both are named \"x\" outside\n```\n";
    const unmarked = (try foreignZig(half, &.{file})) orelse return error.TestExpectedForeignBlock;
    defer testing.allocator.free(unmarked);
    try testing.expectEqualStrings(".a = v.rename(\"x\"),\n.b = v.rename(\"x\"), // compile error: both are named \"x\" outside\n", unmarked);
    // Comments alone are no code that must not compile: the block is checked.
    const comments = "```zig\n// compile error: none\n```\n";
    const no_code = (try foreignZig(comments, &.{file})) orelse return error.TestExpectedForeignBlock;
    defer testing.allocator.free(no_code);
    try testing.expectEqualStrings("// compile error: none\n", no_code);
}
