//! Checks of the guide of zefir-mongo against its examples: that the guide
//! shows a file as it is, a run of a program as it printed, after the
//! program, and no Zig code that is not a part of its examples.
//! readme_test.zig runs them for the programs that need no server,
//! tests/mongo/guide_test.zig for the runs of the programs against mongod.
//! Every function compares texts with "\r\n" turned into "\n", since Git
//! may check files out with CRLF on Windows.

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
/// `<…>` the ObjectIds that inserts make, 24 hex digits, and the port of a
/// server on loopback, the digits after `127.0.0.1:`, since the guide's
/// commands name mongod's own port and tests/mongo runs them against the
/// servers of docker-compose.yml.
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
            if (varyingAt(rest, i)) |found| {
                try out.appendSlice(testing.allocator, rest[i..][0..found.keep]);
                try out.appendSlice(testing.allocator, "<…>");
                i += found.keep + found.value;
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

const Varying = struct {
    /// The length of what stays before the value, such as `127.0.0.1:`.
    keep: usize,
    /// The length of the value.
    value: usize,
};

/// The part that varies at `s[i..]`, if one starts there.
fn varyingAt(s: []const u8, i: usize) ?Varying {
    const loopback = "127.0.0.1:";
    if (std.mem.startsWith(u8, s[i..], loopback)) {
        var end = i + loopback.len;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        if (end > i + loopback.len) return .{ .keep = loopback.len, .value = end - i - loopback.len };
    }
    // An ObjectId: 24 hex digits, with no letter or digit next to them.
    const object_id_len = 24;
    if (i > 0 and std.ascii.isAlphanumeric(s[i - 1])) return null;
    if (s.len - i < object_id_len) return null;
    for (s[i..][0..object_id_len]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    if (s.len > i + object_id_len and std.ascii.isAlphanumeric(s[i + object_id_len])) return null;
    return .{ .keep = 0, .value = object_id_len };
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

test "the parts of a run that vary are masked: the timestamp, the ObjectIds and the port on loopback" {
    const line = "2026-10-19T09:41:07.415Z INFO  [app] Signed up name=Ann _id=6713a1f0c2e94b0e7d000001\n";
    const masked = try mask(line);
    defer testing.allocator.free(masked);
    try testing.expectEqualStrings("<timestamp> INFO  [app] Signed up name=Ann _id=<…>\n", masked);

    for ([_][2][]const u8{
        .{ "WARN  [mongo] 127.0.0.1:27118 refused a connection", "WARN  [mongo] 127.0.0.1:<…> refused a connection" },
        .{ "{\"_id\":{\"$oid\":\"65f0c0ffee0000000000a001\"}}", "{\"_id\":{\"$oid\":\"<…>\"}}" },
        // Not an ObjectId: 23 or 25 digits, capitals, a letter next to them.
        .{ "6713a1f0c2e94b0e7d00000", "6713a1f0c2e94b0e7d00000" },
        .{ "6713a1f0c2e94b0e7d0000012", "6713a1f0c2e94b0e7d0000012" },
        .{ "6713A1F0C2E94B0E7D000001", "6713A1F0C2E94B0E7D000001" },
        .{ "x6713a1f0c2e94b0e7d000001", "x6713a1f0c2e94b0e7d000001" },
        // A host that is not on loopback, and loopback without a port.
        .{ "db.example.com:27017", "db.example.com:27017" },
        .{ "127.0.0.1: none", "127.0.0.1: none" },
        .{ "2026-10-19T09:41:07.415", "2026-10-19T09:41:07.415" },
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
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\n2026-10-19T09:41:07.415Z INFO  Done at 127.0.0.1:27017\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "2026-10-19T10:00:00.000Z INFO  Done at 127.0.0.1:27117\n");
    try expectZigFromExamples("doc", doc, &.{file});
    // Another output, another command, code from elsewhere.
    try testing.expect(!try showsRun(doc, file, "$ zig build run", "2026-10-19T10:00:00.000Z INFO  Other\n"));
    try testing.expect(!try showsRun(doc, file, "$ zig build run-other", "2026-10-19T10:00:00.000Z INFO  Done at 127.0.0.1:27117\n"));
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})).?;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
