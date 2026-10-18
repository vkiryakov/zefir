//! Checks of a guide against its examples, for the tests of the guides of
//! rpc and rpc-nats: that the guide shows a file as it is, a run of a
//! program as it printed, after the program, and no Zig code that is not a
//! part of its examples. Every function compares texts with "\r\n" turned
//! into "\n", since Git may check files out with CRLF on Windows.

const std = @import("std");

const testing = std.testing;

/// The fields of a record of zefir-log whose values change from run to
/// run, and that a run in a guide may show with values of its own, as the
/// timestamp at the start of every line: in text ` name=value`, in JSON
/// `"name":value` with the last part of a dotted name.
pub const varying_fields = [_][]const u8{ "rpc.request_id", "rpc.duration_ms", "span_id" };

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
    if (try showsRun(doc, file, command, output)) return;
    const printed = try unixLines(output);
    defer testing.allocator.free(printed);
    const expected = try mask(printed);
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
    const printed = try unixLines(output);
    defer testing.allocator.free(printed);
    const expected = try mask(printed);
    defer testing.allocator.free(expected);
    const shown_file = try std.mem.concat(testing.allocator, u8, &.{ "```zig\n", program, "```\n" });
    defer testing.allocator.free(shown_file);
    const file_at = std.mem.find(u8, text, shown_file) orelse return false;
    const after = text[file_at + shown_file.len ..];
    const start = try std.mem.concat(testing.allocator, u8, &.{ "```text\n", command, "\n" });
    defer testing.allocator.free(start);
    const at = std.mem.find(u8, after, start) orelse return false;
    const body = after[at + start.len ..];
    const end = std.mem.find(u8, body, "```\n") orelse return false;
    const shown = try mask(body[0..end]);
    defer testing.allocator.free(shown);
    return std.mem.eql(u8, shown, expected);
}

/// Fails unless every ```zig block of the document `name`, `doc`, is a part
/// of one of `files` (see `isPartOf`), but a block that starts with the
/// comment `// build.zig`: the build scripts of the guide.
pub fn expectZigFromExamples(name: []const u8, doc: []const u8, files: []const []const u8) !void {
    return expectZigFrom(name, doc, files, "an example");
}

/// `expectZigFromExamples` for `files` that `what` names in the message of
/// a failure, such as "a file of src/rpc-nats/".
pub fn expectZigFrom(name: []const u8, doc: []const u8, files: []const []const u8, what: []const u8) !void {
    if (try foreignZig(doc, files)) |block| {
        defer testing.allocator.free(block);
        std.debug.print("{s} shows Zig code that is not a part of {s}:\n{s}\n", .{ name, what, block });
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

/// `text` with the parts that change from run to run replaced by `<…>`:
/// a timestamp at the start of a line, the values of `varying_fields`, the
/// timestamp of a JSON record, and the random token of a NATS inbox, as
/// in `_INBOX.l5pmxezLu3fuZWIqNL90cE.*`.
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
            if (varyingAt(rest[i..])) |found| {
                try out.appendSlice(testing.allocator, rest[i..][0..found.key]);
                try out.appendSlice(testing.allocator, "<…>");
                i += found.key + found.value;
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

const Varying = struct {
    /// The length of the key, with its ` ` and `=` in text, its quotes
    /// and `:` in JSON.
    key: usize,
    /// The length of the value after it.
    value: usize,
};

fn varyingAt(s: []const u8) ?Varying {
    inline for (varying_fields) |name| {
        const text_key = " " ++ name ++ "=";
        if (std.mem.startsWith(u8, s, text_key)) {
            const value = s[text_key.len..];
            return .{ .key = text_key.len, .value = std.mem.findScalar(u8, value, ' ') orelse value.len };
        }
        const last = comptime if (std.mem.findScalarLast(u8, name, '.')) |dot| name[dot + 1 ..] else name;
        const json_key = "\"" ++ last ++ "\":";
        if (std.mem.startsWith(u8, s, json_key)) {
            return .{ .key = json_key.len, .value = jsonValueLength(s[json_key.len..]) };
        }
    }
    const json_timestamp = "\"timestamp\":";
    if (std.mem.startsWith(u8, s, json_timestamp)) {
        return .{ .key = json_timestamp.len, .value = jsonValueLength(s[json_timestamp.len..]) };
    }
    // An inbox, _INBOX or _INBOX_<name>, then a dot and its token.
    if (std.mem.startsWith(u8, s, "_INBOX")) {
        var dot: usize = "_INBOX".len;
        while (dot < s.len and (std.ascii.isAlphanumeric(s[dot]) or s[dot] == '_' or s[dot] == '-')) dot += 1;
        if (dot < s.len and s[dot] == '.') {
            var end = dot + 1;
            while (end < s.len and std.ascii.isAlphanumeric(s[end])) end += 1;
            if (end > dot + 1) return .{ .key = dot + 1, .value = end - dot - 1 };
        }
    }
    return null;
}

/// The length of the JSON value at the start of `s`: a string up to its
/// closing quote, anything else up to the next `,` or `}`.
fn jsonValueLength(s: []const u8) usize {
    if (s.len > 0 and s[0] == '"') {
        const close = std.mem.findScalar(u8, s[1..], '"') orelse return s.len;
        return close + 2;
    }
    return std.mem.findAny(u8, s, ",}") orelse s.len;
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

test "the parts of a run that vary are masked, in text and in JSON" {
    const text = "2026-10-16T09:41:07.415Z INFO  [rpc] RPC call served rpc.code=ok rpc.request_id=6f1e rpc.duration_ms=12 trace_id=4bf9 span_id=00f0\n";
    const masked_text = try mask(text);
    defer testing.allocator.free(masked_text);
    try testing.expectEqualStrings("<timestamp> INFO  [rpc] RPC call served rpc.code=ok rpc.request_id=<…> rpc.duration_ms=<…> trace_id=4bf9 span_id=<…>\n", masked_text);

    const json = "{\"timestamp\":\"2026-10-16T09:41:07.415Z\",\"trace_id\":\"4bf9\",\"rpc\":{\"code\":\"ok\",\"request_id\":\"6f1e\",\"duration_ms\":12}}";
    const masked_json = try mask(json);
    defer testing.allocator.free(masked_json);
    try testing.expectEqualStrings("{\"timestamp\":<…>,\"trace_id\":\"4bf9\",\"rpc\":{\"code\":\"ok\",\"request_id\":<…>,\"duration_ms\":<…>}}", masked_json);

    // A value that is the end of the line, a lone key, an unclosed string;
    // the tokens of inboxes, and what is no token.
    for ([_][2][]const u8{
        .{ "a rpc.request_id=", "a rpc.request_id=<…>" },
        .{ "\"span_id\":\"", "\"span_id\":<…>" },
        .{ "\"span_id\":", "\"span_id\":<…>" },
        .{ "2026-10-16T09:41:07.415", "2026-10-16T09:41:07.415" },
        .{ "to \\\"_INBOX.l5pmxezLu3fuZWIqNL90cE.*\\\"", "to \\\"_INBOX.<…>.*\\\"" },
        .{ "_INBOX_orders.k3Jd9.17", "_INBOX_orders.<…>.17" },
        .{ "inbox=_INBOX reason=AccessDenied", "inbox=_INBOX reason=AccessDenied" },
        .{ "_INBOX.", "_INBOX." },
    }) |case| {
        const masked = try mask(case[0]);
        defer testing.allocator.free(masked);
        try testing.expectEqualStrings(case[1], masked);
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
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\n2026-10-16T09:41:07.415Z INFO  Done\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "2026-10-16T10:00:00.000Z INFO  Done\n");
    try expectZigFromExamples("doc", doc, &.{file});
    // Another output, another command, code from elsewhere.
    try testing.expect(!try showsRun(doc, file, "$ zig build run", "2026-10-16T10:00:00.000Z INFO  Other\n"));
    try testing.expect(!try showsRun(doc, file, "$ zig build run-other", "2026-10-16T10:00:00.000Z INFO  Done\n"));
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})).?;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
