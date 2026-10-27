//! Checks of the guide of zefir-nats against its examples: that the guide
//! shows a file as it is, a run of a program as it printed, after the
//! program, and no Zig code that is not a part of its examples.
//! readme_test.zig runs them without a server, and guide_test.zig of
//! tests/nats checks the runs against its servers. Every function compares
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

/// Fails unless the document `name`, `doc`, shows a run of the program
/// `file` that printed `output`: the first ```text block of `command`
/// after the ```zig block of the whole `file`, with the lines of `output`.
/// The timestamps of zefir-log may have other values there (see `mask`).
pub fn expectRun(name: []const u8, doc: []const u8, file: []const u8, command: []const u8, output: []const u8) !void {
    if (try showsRun(doc, file, command, output)) return;
    const expected = try maskedLines(output);
    defer testing.allocator.free(expected);
    std.debug.print("{s} shows no run like this one after its program; the parts in <> may vary:\n```text\n{s}\n{s}```\n", .{ name, command, expected });
    return error.TestRunNotInGuide;
}

/// Whether the first run of `command` that `doc` shows after the program
/// `file` printed `output`.
fn showsRun(doc: []const u8, file: []const u8, command: []const u8, output: []const u8) !bool {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const program = try unixLines(file);
    defer testing.allocator.free(program);
    const shown_file = try std.mem.concat(testing.allocator, u8, &.{ "```zig\n", program, "```\n" });
    defer testing.allocator.free(shown_file);
    const file_at = std.mem.find(u8, text, shown_file) orelse return false;
    const after = text[file_at + shown_file.len ..];
    const start = try std.mem.concat(testing.allocator, u8, &.{ "```text\n", command, "\n" });
    defer testing.allocator.free(start);
    const at = std.mem.find(u8, after, start) orelse return false;
    const body = after[at + start.len ..];
    const end = closingFence(body) orelse return false;
    return sameMasked(body[0..end], output);
}

/// Where the block that `body` begins closes: at the first line that
/// starts with "```", as in Markdown. A "```" inside a line, such as in a
/// doc comment of a file shown whole, does not close it.
fn closingFence(body: []const u8) ?usize {
    if (std.mem.startsWith(u8, body, "```")) return 0;
    const at = std.mem.find(u8, body, "\n```") orelse return null;
    return at + 1;
}

/// Whether `shown` and `output` are the same once masked, their blank
/// lines at the end aside.
fn sameMasked(shown: []const u8, output: []const u8) !bool {
    const a = try maskedLines(shown);
    defer testing.allocator.free(a);
    const b = try maskedLines(output);
    defer testing.allocator.free(b);
    return std.mem.eql(u8, a, b);
}

/// `text` with "\n" for "\r\n", masked, without blank lines at the end,
/// and with one "\n" after its last line.
fn maskedLines(text: []const u8) ![]u8 {
    const lines = try unixLines(text);
    defer testing.allocator.free(lines);
    const masked = try mask(std.mem.trimEnd(u8, lines, "\n"));
    defer testing.allocator.free(masked);
    return std.mem.concat(testing.allocator, u8, &.{ masked, "\n" });
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
        const end = closingFence(body) orelse return error.TestUnclosedBlock;
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

/// The fields of a record of zefir-log, as text, whose values a program
/// measures, so that they change from run to run: a run in the guide may
/// show them with values of its own, as the timestamp at the start of
/// every line.
pub const varying_fields = [_][]const u8{"rtt_us"};

/// `text` with the parts of a run that change from run to run replaced:
/// the timestamp of zefir-log at the start of a line, by `<timestamp>`,
/// and the value of each of `varying_fields`, by `<…>`.
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
            if (varyingAt(rest[i..])) |key| {
                const value = rest[i + key ..];
                try out.appendSlice(testing.allocator, rest[i..][0..key]);
                try out.appendSlice(testing.allocator, "<…>");
                i += key + (std.mem.findScalar(u8, value, ' ') orelse value.len);
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

/// The length of the key, ` name=`, of one of `varying_fields` that `s`
/// starts with; null when it starts with none.
fn varyingAt(s: []const u8) ?usize {
    inline for (varying_fields) |name| {
        const key = " " ++ name ++ "=";
        if (std.mem.startsWith(u8, s, key)) return key.len;
    }
    return null;
}

/// The form of a zefir-log timestamp, such as 2026-10-16T09:41:07.415Z; `d`
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

test "a timestamp of zefir-log at the start of a line and a measured value are masked, and nothing else" {
    const text = "2026-10-13T18:08:29.061Z INFO  Connected user=alice\n" ++
        "2026-10-13T18:08:29.062Z INFO  Server reached rtt_us=829\n" ++
        "info: orders.created: {\"id\":1001}\n" ++
        "issued 2026-10-13T18:08:29.061Z";
    const masked = try mask(text);
    defer testing.allocator.free(masked);
    try testing.expectEqualStrings("<timestamp> INFO  Connected user=alice\n" ++
        "<timestamp> INFO  Server reached rtt_us=<…>\n" ++
        "info: orders.created: {\"id\":1001}\n" ++
        "issued 2026-10-13T18:08:29.061Z", masked);
    // Almost a timestamp is no timestamp; a measured value ends at a
    // space, and another field of a similar name is kept.
    for ([_][2][]const u8{
        .{ "2026-10-13T18:08:29Z INFO", "2026-10-13T18:08:29Z INFO" },
        .{ "a rtt_us=829 b=1", "a rtt_us=<…> b=1" },
        .{ "a rtt_us=", "a rtt_us=<…>" },
        .{ "a max_rtt_us=829", "a max_rtt_us=829" },
    }) |case| {
        const kept = try mask(case[0]);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings(case[1], kept);
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
    try testing.expect(!try showsRun("```text\n$ zig build run\nA\n```\n\n```zig\n" ++ a ++ "```\n", a, "$ zig build run", "A\n"));
}

test "a block closes at a line that starts with its fence" {
    const file = "//! ```zig\n//! const a = 1;\n//! ```\nconst b = 2;\n";
    const doc = "```zig\n" ++ file ++ "```\n";
    try expectZigFromExamples("doc", doc, &.{file});
}

test "a guide passes when it shows the file, the run and only parts of the file" {
    const file = "const x = 1;\nconst y = 2;\n";
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\n2026-10-13T18:07:20.508Z INFO  [checkout] Cart priced items=3\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "2026-10-27T09:00:00.000Z INFO  [checkout] Cart priced items=3\n");
    try expectZigFromExamples("doc", doc, &.{file});
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
