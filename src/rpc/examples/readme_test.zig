//! README.md shows every file of the examples as it is, a run of every
//! program as it printed, and no Zig code that is not a part of these
//! files: a file that changes without its copy in README.md, or a program
//! that prints something else, fails this test. build.zig compiles it
//! twice: for the programs of `zig build test-rpc` and for those of `zig
//! build test-rpc-log`. It embeds what each program printed in this build
//! as `<name>.out`, and README.md of the repository as `root_readme`.

const std = @import("std");
const cases = @import("cases");
const options = @import("readme_options");

const guide = @embedFile("README.md");

const programs = if (options.access_log) cases.access_log_programs else cases.programs;

const testing = std.testing;

/// `text` with "\r\n" turned into "\n": Git may check files out with CRLF
/// on Windows.
fn unixLines(text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, testing.allocator, text, "\r\n", "\n");
}

/// Fails unless the document `name`, `doc`, contains `block`.
fn expectBlock(name: []const u8, doc: []const u8, block: []const u8) !void {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const wanted = try unixLines(block);
    defer testing.allocator.free(wanted);
    if (std.mem.find(u8, text, wanted) == null) {
        std.debug.print("{s} does not contain this block:\n{s}\n", .{ name, wanted });
        return error.TestBlockNotInReadme;
    }
}

/// Fails unless the document `name`, `doc`, shows a run of `command` that
/// printed `output`: a ```text block of `command` and then the lines of
/// `output`. The parts that change from run to run may have other values
/// there.
fn expectRun(name: []const u8, doc: []const u8, command: []const u8, output: []const u8) !void {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const printed = try unixLines(output);
    defer testing.allocator.free(printed);
    const expected = try mask(printed);
    defer testing.allocator.free(expected);
    const start = try std.mem.concat(testing.allocator, u8, &.{ "```text\n", command, "\n" });
    defer testing.allocator.free(start);
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, start)) |at| {
        const body = rest[at + start.len ..];
        const end = std.mem.find(u8, body, "```\n") orelse break;
        const shown = try mask(body[0..end]);
        defer testing.allocator.free(shown);
        if (std.mem.eql(u8, shown, expected)) return;
        rest = body[end..];
    }
    std.debug.print("{s} shows no run like this one; the parts in <> may vary:\n```text\n{s}\n{s}```\n", .{ name, command, expected });
    return error.TestRunNotInReadme;
}

/// `text` with the parts that change from run to run replaced by `<…>`.
fn mask(text: []const u8) ![]u8 {
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

/// A field of `cases.varying_fields` at the start of `s`: ` name=value` in
/// text, `"name":value` in JSON, where the name is the last part of a
/// dotted one.
fn varyingAt(s: []const u8) ?Varying {
    inline for (cases.varying_fields) |name| {
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
fn isPartOf(file: []const u8, block: []const u8) !bool {
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

/// The files of the examples: README.md may show any part of them.
const example_files = names: {
    var names: []const []const u8 = &.{};
    for (cases.programs ++ cases.access_log_programs) |program| names = names ++ &[_][]const u8{program.name};
    break :names names ++ &cases.files;
};

test "README.md shows every file of the examples as it is" {
    inline for (programs) |program| try expectBlock("README.md", guide, "```zig\n" ++ @embedFile(program.name ++ ".zig") ++ "```\n");
    if (!options.access_log) {
        inline for (cases.files) |name| try expectBlock("README.md", guide, "```zig\n" ++ @embedFile(name ++ ".zig") ++ "```\n");
    }
}

test "README.md shows a run of every program as it printed" {
    inline for (programs) |program| try expectRun("README.md", guide, cases.command(program), @embedFile(program.name ++ ".out"));
}

test "every Zig block of README.md but those of build.zig is a part of an example" {
    if (options.access_log) return;
    const doc = try unixLines(guide);
    defer testing.allocator.free(doc);
    const open = "```zig\n";
    var rest: []const u8 = doc;
    while (std.mem.find(u8, rest, open)) |at| {
        const body = rest[at + open.len ..];
        const end = std.mem.find(u8, body, "```") orelse return error.TestUnclosedBlock;
        const block = body[0..end];
        rest = body[end + 3 ..];
        if (std.mem.startsWith(u8, block, "// build.zig")) continue;
        const found = found: inline for (example_files) |name| {
            const file = try unixLines(@embedFile(name ++ ".zig"));
            defer testing.allocator.free(file);
            if (try isPartOf(file, block)) break :found true;
        } else false;
        if (!found) {
            std.debug.print("README.md shows Zig code that is not a part of an example:\n{s}\n", .{block});
            return error.TestBlockNotFromExamples;
        }
    }
}

test "README.md of the repository shows its examples of rpc and their runs" {
    if (options.access_log) return;
    const root = @embedFile("root_readme");
    inline for (cases.root_readme) |name| {
        try expectBlock("README.md of the repository", root, "```zig\n" ++ @embedFile(name ++ ".zig") ++ "```\n");
        const program = comptime for (cases.programs) |program| {
            if (std.mem.eql(u8, program.name, name)) break program;
        } else unreachable;
        try expectRun("README.md of the repository", root, cases.command(program), @embedFile(name ++ ".out"));
    }
}

test "the parts of a run that vary are masked, in text and in JSON" {
    const text = "2026-10-16T09:41:07.415Z INFO  [rpc] RPC call served rpc.code=ok rpc.duration_ms=0.42 trace_id=4bf9 span_id=00f0\n";
    const masked_text = try mask(text);
    defer testing.allocator.free(masked_text);
    try testing.expectEqualStrings("<timestamp> INFO  [rpc] RPC call served rpc.code=ok rpc.duration_ms=<…> trace_id=4bf9 span_id=<…>\n", masked_text);

    const json = "{\"timestamp\":\"2026-10-16T09:41:07.415Z\",\"trace_id\":\"4bf9\",\"rpc\":{\"request_id\":\"6f1e\",\"duration_ms\":0.42}}";
    const masked_json = try mask(json);
    defer testing.allocator.free(masked_json);
    try testing.expectEqualStrings("{\"timestamp\":<…>,\"trace_id\":\"4bf9\",\"rpc\":{\"request_id\":<…>,\"duration_ms\":<…>}}", masked_json);

    // A value that is the end of the line, a lone key, an unclosed string.
    for ([_][2][]const u8{
        .{ "a rpc.request_id=", "a rpc.request_id=<…>" },
        .{ "\"span_id\":\"", "\"span_id\":<…>" },
        .{ "\"span_id\":", "\"span_id\":<…>" },
        .{ "2026-10-16T09:41:07.415", "2026-10-16T09:41:07.415" },
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
