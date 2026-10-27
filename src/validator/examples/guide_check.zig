//! Checks of the guide of zefir-validator against its examples: that a page
//! of the guide shows a file as it is, and no Zig code that is not a part
//! of its examples. readme_test.zig runs them. Every function compares
//! texts with "\r\n" turned into "\n", since Git may check files out with
//! CRLF on Windows.

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
/// a block of code that must not compile, whose wrong lines carry the
/// comment `// compile error: …` (see `mustNotCompile`).
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

/// Whether `block` is code that the guide shows as wrong: some line of it
/// ends with the comment `// compile error: …`, which says what the
/// compiler reports there. Such code is no part of a file that compiles.
fn mustNotCompile(block: []const u8) bool {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "// compile error: ") orelse continue;
        if (std.mem.trim(u8, line[0..at], " ").len > 0) return true;
    }
    return false;
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

test "code that must not compile is a block of its own, marked on a line of code" {
    const file = "const x = 1;\n";
    const wrong = "```zig\n// a rule after a transform\n.email = .{ v.email, v.trim }, // compile error: transforms must come first\n```\n";
    try expectZigFromExamples("doc", wrong, &.{file});
    // A marker in a comment of its own marks nothing: the block is checked.
    const comment_only = "```zig\n// compile error: none\nconst z = 3;\n```\n";
    const foreign = (try foreignZig(comment_only, &.{file})) orelse return error.TestExpectedForeignBlock;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("// compile error: none\nconst z = 3;\n", foreign);
}
