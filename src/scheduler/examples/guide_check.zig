//! Checks of the guide of zefir-scheduler against its examples: that the
//! guide shows a file as it is, a run of a program as it printed, after
//! the program, and no Zig code that is not a part of its examples.
//! readme_test.zig runs them for the programs that need no server,
//! tests/scheduler/guide_test.zig for the runs of the programs against
//! mongod. Every function compares texts with "\r\n" turned into "\n",
//! since Git may check files out with CRLF on Windows. A copy of the
//! checks of the guide of zefir-odm, with masks of its own: the instances
//! of workers and the lives of records, in hex, and the times inside a
//! line.

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
/// command cannot swap their runs. The parts that change from run to run
/// may have other values there (see `mask`).
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
    const end = std.mem.find(u8, body, "```\n") orelse return null;
    return try mask(body[0..end]);
}

/// Fails unless every ```zig block of the document `name`, `doc`, is a part
/// of one of `files` (see `isPartOf`), but a block that starts with the
/// comment `// build.zig`: the build scripts of the guide.
pub fn expectZigFromExamples(name: []const u8, doc: []const u8, files: []const []const u8) !void {
    if (try foreignZig(doc, files)) |block| {
        defer testing.allocator.free(block);
        std.debug.print("{s} shows Zig code that is not a part of an example:\n{s}\n", .{ name, block });
        return error.TestBlockNotFromExamples;
    }
}

/// The first ```zig block of `doc` that is not a part of `files` and not
/// a build script, as a copy; null when there is none.
fn foreignZig(doc: []const u8, files: []const []const u8) !?[]u8 {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const open = "```zig\n";
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, open)) |at| {
        const body = rest[at + open.len ..];
        const end = std.mem.find(u8, body, "```") orelse return error.TestUnclosedBlock;
        const block = body[0..end];
        rest = body[end + 3 ..];
        if (std.mem.startsWith(u8, block, "// build.zig")) continue;
        for (files) |file| {
            const lines = try unixLines(file);
            defer testing.allocator.free(lines);
            if (try isPartOf(lines, block)) break;
        } else return try testing.allocator.dupe(u8, block);
    }
    return null;
}

/// `text` with the parts that change from run to run replaced: the
/// timestamp of zefir-log at the start of a line by `<timestamp>`, and by
/// `<…>` a time inside a line, such as the `scheduled_at` of a run, and 32
/// hex digits, the random part of the name of a worker's instance, as in
/// `shop/7f3a9c…`, or the life of a record.
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
            if (varyingAt(rest, i)) |len| {
                try out.appendSlice(testing.allocator, "<…>");
                i += len;
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

/// The length of the part that varies at `s[i..]`, if one starts there.
fn varyingAt(s: []const u8, i: usize) ?usize {
    // Neither part starts right after a letter or a digit.
    if (i > 0 and std.ascii.isAlphanumeric(s[i - 1])) return null;
    if (timeAt(s[i..])) |len| return len;
    // 32 hex digits, with no letter or digit after them.
    const hex_len = 32;
    if (s.len - i < hex_len) return null;
    for (s[i..][0..hex_len]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    if (s.len > i + hex_len and std.ascii.isAlphanumeric(s[i + hex_len])) return null;
    return hex_len;
}

/// The form of a zefir-log timestamp, such as 2026-10-27T09:41:07.415Z; `d`
/// stands for a digit.
const timestamp_form = "dddd-dd-ddTdd:dd:dd.dddZ";

fn isTimestamp(s: []const u8) bool {
    if (s.len != timestamp_form.len) return false;
    return fits(s, timestamp_form);
}

/// Whether `s` has the form `form`, where `d` stands for a digit.
fn fits(s: []const u8, form: []const u8) bool {
    for (s, form) |c, f| {
        if (if (f == 'd') !std.ascii.isDigit(c) else c != f) return false;
    }
    return true;
}

/// The length of the time that `s` starts with, as `scheduler.Instant`
/// writes it, with milliseconds: 2026-10-27T14:05:09.123Z; null when it
/// starts with none.
fn timeAt(s: []const u8) ?usize {
    return if (s.len >= timestamp_form.len and fits(s[0..timestamp_form.len], timestamp_form)) timestamp_form.len else null;
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

test "the parts of a run that vary are masked: the timestamp, the times, the instances and the lives" {
    const line = "2026-10-27T09:41:07.415Z INFO  [scheduler] 1 job type, 10 workers, instance shop/7f3a9c0e5b2d41a8c6e9f0b1d2a3c4e5\n";
    const masked = try mask(line);
    defer testing.allocator.free(masked);
    try testing.expectEqualStrings("<timestamp> INFO  [scheduler] 1 job type, 10 workers, instance shop/<…>\n", masked);

    for ([_][2][]const u8{
        .{ "Run outcome=succeeded instance=shop/0123456789abcdef0123456789abcdef scheduled_at=2026-10-27T09:41:08.415Z", "Run outcome=succeeded instance=shop/<…> scheduled_at=<…>" },
        .{ "life=9f1c0e5b2d41a8c6e9f0b1d2a3c4e5f6 fence=2", "life=<…> fence=2" },
        // Not 32 hex digits: 31 or 33 of them, capitals, a letter next to them.
        .{ "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcde" },
        .{ "0123456789abcdef0123456789abcdef0", "0123456789abcdef0123456789abcdef0" },
        .{ "0123456789ABCDEF0123456789ABCDEF", "0123456789ABCDEF0123456789ABCDEF" },
        .{ "x0123456789abcdef0123456789abcdef", "x0123456789abcdef0123456789abcdef" },
        // Not a time: no milliseconds, no Z, or a digit before it.
        .{ "2026-10-27T14:05:09Z", "2026-10-27T14:05:09Z" },
        .{ "2026-10-27T14:05:09.123", "2026-10-27T14:05:09.123" },
        .{ "12026-10-27T14:05:09.123Z", "12026-10-27T14:05:09.123Z" },
        // A time of the calendar as a program writes it, without T and Z.
        .{ "Sat 2026-10-24 00:04:00", "Sat 2026-10-24 00:04:00" },
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

test "a guide passes when it shows the file, the run and only parts of the file" {
    const file = "const x = 1;\nconst y = 2;\n";
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\n2026-10-27T09:41:07.415Z INFO  Done by shop/0123456789abcdef0123456789abcdef\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "2026-10-27T10:00:00.000Z INFO  Done by shop/fedcba9876543210fedcba9876543210\n");
    try expectZigFromExamples("doc", doc, &.{file});
    // Another output, another command, code from elsewhere.
    try testing.expect(!try showsRun(doc, file, "$ zig build run", "2026-10-27T10:00:00.000Z INFO  Other\n"));
    try testing.expect(!try showsRun(doc, file, "$ zig build run-other", "2026-10-27T10:00:00.000Z INFO  Done by shop/fedcba9876543210fedcba9876543210\n"));
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
