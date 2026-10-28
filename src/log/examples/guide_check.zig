//! Checks of the guide of zefir-log against its examples: that the guide
//! shows a file as it is, a run of a program as it printed, after the
//! program, and no Zig code that is not a part of its examples.
//! readme_test.zig runs them. Every function compares texts with "\r\n"
//! turned into "\n", since Git may check files out with CRLF on Windows.

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

/// Fails unless the document `name`, `doc`, shows a run of the program
/// `file` that printed `output`: the first ```text block of `command`
/// after the ```zig block of the whole `file`, with the lines of `output`.
/// So the run stands next to its program, and programs with the same
/// command cannot swap their runs. The times of the records may have other
/// values there (see `mask`).
pub fn expectRun(name: []const u8, doc: []const u8, file: []const u8, command: []const u8, output: []const u8) !void {
    const printed = try unixLines(output);
    defer testing.allocator.free(printed);
    const expected = try mask(printed);
    defer testing.allocator.free(expected);
    const shown = try shownRun(doc, file, command);
    defer if (shown) |run| testing.allocator.free(run);
    if (shown) |run| if (std.mem.eql(u8, run, expected)) return;
    std.debug.print("{s} shows no run like this one after its program; the parts in <> may vary:\n```text\n{s}\n{s}```\n", .{ name, command, expected });
    if (shown) |run| {
        std.debug.print("It shows this one:\n```text\n{s}\n{s}```\n", .{ command, run });
    } else std.debug.print("It shows no run of `{s}` after the program, or not the program.\n", .{command});
    return error.TestRunNotInGuide;
}

/// Whether the first run of `command` that `doc` shows after the program
/// `file` printed `output`.
fn showsRun(doc: []const u8, file: []const u8, command: []const u8, output: []const u8) !bool {
    const printed = try unixLines(output);
    defer testing.allocator.free(printed);
    const expected = try mask(printed);
    defer testing.allocator.free(expected);
    const shown = (try shownRun(doc, file, command)) orelse return false;
    defer testing.allocator.free(shown);
    return std.mem.eql(u8, shown, expected);
}

/// The first run of `command` that `doc` shows after the program `file`,
/// masked, as a copy; null when `doc` shows no such run, or not the
/// program.
fn shownRun(doc: []const u8, file: []const u8, command: []const u8) !?[]u8 {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const program = try unixLines(file);
    defer testing.allocator.free(program);
    const shown_file = try std.mem.concat(testing.allocator, u8, &.{ "```zig\n", program, "```\n" });
    defer testing.allocator.free(shown_file);
    const file_at = std.mem.find(u8, text, shown_file) orelse return null;
    const after = text[file_at + shown_file.len ..];
    const start = try std.mem.concat(testing.allocator, u8, &.{ "```text\n", command, "\n" });
    defer testing.allocator.free(start);
    const at = std.mem.find(u8, after, start) orelse return null;
    const body = after[at + start.len ..];
    const end = closingFence(body) orelse return null;
    return try mask(body[0..end]);
}

/// Where the block that `body` begins closes: at the first line that
/// starts with "```", as in Markdown. A "```" inside a line, such as in a
/// string of a program shown whole, does not close it.
fn closingFence(body: []const u8) ?usize {
    if (std.mem.startsWith(u8, body, "```")) return 0;
    const at = std.mem.find(u8, body, "\n```") orelse return null;
    return at + 1;
}

/// Fails unless every ```zig block of the document `name`, `doc`, is a part
/// of one of `files` (see `isPartOf`), but a block that starts with the
/// comment `// build.zig`, a build script of the guide, and a block whose
/// every line is marked `// compile error:`, code that must not compile,
/// which readme_test.zig checks against the build's compile checks.
pub fn expectZigFromExamples(name: []const u8, doc: []const u8, files: []const []const u8) !void {
    if (try foreignZig(doc, files)) |block| {
        defer testing.allocator.free(block);
        std.debug.print("{s} shows Zig code that is not a part of an example:\n{s}\n", .{ name, block });
        return error.TestBlockNotFromExamples;
    }
}

/// The first ```zig block of `doc` that is not a part of `files`, a build
/// script or code that must not compile, as a copy; null when there is
/// none.
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

/// Whether every line of `block` is marked as code that must not compile.
fn mustNotCompile(block: []const u8) bool {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, block, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "// compile error:") == null) return false;
    }
    return true;
}

/// `text` with the one part of a run that changes from run to run, the
/// time of a record, replaced by `<timestamp>`: at the start of a line, as
/// a record in text has it, and as the value of `"timestamp"`, as a record
/// in JSON has it. The programs of the guide print no other time, no id
/// and no address of their own, so nothing else varies.
pub fn mask(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(testing.allocator, '\n');
        first = false;
        var rest = line;
        if (rest.len >= timestamp_form.len and isTimestamp(rest[0..timestamp_form.len])) {
            try out.appendSlice(testing.allocator, "<timestamp>");
            rest = rest[timestamp_form.len..];
        }
        var i: usize = 0;
        while (i < rest.len) {
            if (jsonTimestampAt(rest, i)) {
                try out.appendSlice(testing.allocator, json_time ++ "<timestamp>\"");
                i += json_time.len + timestamp_form.len + 1;
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

/// How a record in JSON begins its time.
const json_time = "\"timestamp\":\"";

/// Whether `s[i..]` begins with `"timestamp":"`, a timestamp and the quote
/// that ends it.
fn jsonTimestampAt(s: []const u8, i: usize) bool {
    const rest = s[i..];
    if (!std.mem.startsWith(u8, rest, json_time)) return false;
    if (rest.len < json_time.len + timestamp_form.len + 1) return false;
    return isTimestamp(rest[json_time.len..][0..timestamp_form.len]) and rest[json_time.len + timestamp_form.len] == '"';
}

/// The form of a zefir-log timestamp, such as 2026-10-12T09:41:07.415Z; `d`
/// stands for a digit.
const timestamp_form = "dddd-dd-ddTdd:dd:dd.dddZ";

fn isTimestamp(s: []const u8) bool {
    if (s.len != timestamp_form.len) return false;
    for (s, timestamp_form) |c, f| {
        if (if (f == 'd') !std.ascii.isDigit(c) else c != f) return false;
    }
    return true;
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

test "the time of a record is masked, at the start of a line in text and as the value of timestamp in JSON, and nothing else" {
    for ([_][2][]const u8{
        .{ "2026-10-12T09:41:07.415Z INFO  [users] User created user_id=42", "<timestamp> INFO  [users] User created user_id=42" },
        .{
            "{\"timestamp\":\"2026-10-12T09:41:07.415Z\",\"level\":\"info\",\"message\":\"User created\",\"user_id\":42}",
            "{\"timestamp\":\"<timestamp>\",\"level\":\"info\",\"message\":\"User created\",\"user_id\":42}",
        },
        // Two lines, each with its time.
        .{
            "{\"timestamp\":\"2026-10-12T09:41:07.415Z\"}\n{\"timestamp\":\"2026-10-12T09:41:07.416Z\"}",
            "{\"timestamp\":\"<timestamp>\"}\n{\"timestamp\":\"<timestamp>\"}",
        },
        // Almost a time is no time: without milliseconds, without the
        // closing quote, under another key, or inside a line of text.
        .{ "2026-10-12T09:41:07Z INFO", "2026-10-12T09:41:07Z INFO" },
        .{ "{\"timestamp\":\"2026-10-12T09:41:07.415Z", "{\"timestamp\":\"2026-10-12T09:41:07.415Z" },
        .{ "{\"issued\":\"2026-10-12T09:41:07.415Z\"}", "{\"issued\":\"2026-10-12T09:41:07.415Z\"}" },
        .{ "INFO  issued 2026-10-12T09:41:07.415Z", "INFO  issued 2026-10-12T09:41:07.415Z" },
        .{ "accepted 10000, written 10000", "accepted 10000, written 10000" },
    }) |case| {
        const got = try mask(case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
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

test "a run is the first one after its program, so two programs of one command cannot swap their runs" {
    const a = "const a = 1;\n";
    const b = "const b = 2;\n";
    const swapped = "```zig\n" ++ a ++ "```\n\n```text\n$ zig build run\nB\n```\n\n```zig\n" ++ b ++ "```\n\n```text\n$ zig build run\nA\n```\n";
    try testing.expect(!try showsRun(swapped, a, "$ zig build run", "A\n"));
    try testing.expect(!try showsRun(swapped, b, "$ zig build run", "B\n"));
    const in_place = "```zig\n" ++ a ++ "```\n\n```text\n$ zig build run\nA\n```\n\n```zig\n" ++ b ++ "```\n\n```text\n$ zig build run\nB\n```\n";
    try testing.expect(try showsRun(in_place, a, "$ zig build run", "A\n"));
    try testing.expect(try showsRun(in_place, b, "$ zig build run", "B\n"));
    // A run before its program, or a program the guide does not show.
    try testing.expect(!try showsRun("```text\n$ zig build run\nA\n```\n\n```zig\n" ++ a ++ "```\n", a, "$ zig build run", "A\n"));
    try testing.expect(!try showsRun(in_place, "const c = 3;\n", "$ zig build run", "A\n"));
}

test "a block closes at a line that starts with its fence, not at one inside a line" {
    const file = "const text = \"```{s}```\";\nconst b = 2;\n";
    const doc = "```zig\n" ++ file ++ "```\n";
    try expectZigFromExamples("doc", doc, &.{file});
    try expectFile("doc", doc, "zig", file);
}

test "a block of code that must not compile is left to its own check, and only such a block" {
    const file = "const x = 1;\n";
    const wrong = "```zig\nlogger.info(\"m\", .{x}); // compile error: a field without a name\nlogger.info(\"m\", .{ .level = 3 }); // compile error: a reserved name\n```\n";
    try expectZigFromExamples("doc", wrong, &.{file});
    // One line without the mark makes the block code like any other.
    const mixed = "```zig\nconst y = 2;\nlogger.info(\"m\", .{x}); // compile error: a field without a name\n```\n";
    const foreign = (try foreignZig(mixed, &.{file})) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const y = 2;\nlogger.info(\"m\", .{x}); // compile error: a field without a name\n", foreign);
}

test "a guide passes when it shows the file, the run and only parts of the file" {
    const file = "const x = 1;\nconst y = 2;\n";
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\n{\"timestamp\":\"2026-10-12T09:41:07.415Z\",\"level\":\"info\",\"message\":\"Started\"}\n2026-10-12T09:41:07.416Z INFO  Started\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "{\"timestamp\":\"2026-10-27T10:00:00.000Z\",\"level\":\"info\",\"message\":\"Started\"}\n2026-10-27T10:00:00.001Z INFO  Started\n");
    try expectZigFromExamples("doc", doc, &.{file});
    // Another output, another command, code from elsewhere.
    try testing.expect(!try showsRun(doc, file, "$ zig build run", "{\"timestamp\":\"2026-10-27T10:00:00.000Z\",\"level\":\"info\",\"message\":\"Other\"}\n"));
    try testing.expect(!try showsRun(doc, file, "$ zig build run-other", "{\"timestamp\":\"2026-10-27T10:00:00.000Z\",\"level\":\"info\",\"message\":\"Started\"}\n2026-10-27T10:00:00.001Z INFO  Started\n"));
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
