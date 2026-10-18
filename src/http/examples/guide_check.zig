//! Checks of the guide of zefir-http against its examples: that the guide
//! shows a file as it is, a run of a program as it printed, after the
//! program, no Zig code that is not a part of its examples, a curl
//! command with the response it got, and the log of the service's session.
//! readme_test.zig runs them for the programs in the repository,
//! tests/http/guide_test.zig for the runs of the service on the network.
//! Every function compares texts with "\r\n" turned into "\n", since Git
//! may check files out with CRLF on Windows.

const std = @import("std");

const testing = std.testing;

/// The header fields whose values change from run to run: a guide shows
/// them with values of its own.
pub const varying_headers = [_][]const u8{ "date", "etag", "last-modified" };

/// The fields of a record of zefir-log, in text, whose values change from
/// run to run.
pub const varying_fields = [_][]const u8{ "duration_ms", "port" };

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
/// The parts that change from run to run may have other values there (see
/// `mask`).
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

/// Fails unless the document `name`, `doc`, shows `$ <command>` with what
/// it printed, `output`, below it: up to the next line of a command or
/// the end of the block. Such as a curl command and the response it got.
pub fn expectExchange(name: []const u8, doc: []const u8, command: []const u8, output: []const u8) !void {
    const shown = try exchangeShown(doc, command, output);
    if (shown == .same) return;
    const expected = try maskedLines(output);
    defer testing.allocator.free(expected);
    if (shown == .other) {
        std.debug.print("{s} shows `$ {s}` with another output; the parts in <> may vary:\n{s}\n", .{ name, command, expected });
    } else {
        std.debug.print("{s} does not show `$ {s}`, which printed; the parts in <> may vary:\n{s}\n", .{ name, command, expected });
    }
    return error.TestExchangeNotInGuide;
}

/// How a document shows a command against what it printed.
const Exchange = enum {
    /// With that output below it, once at least.
    same,
    /// Only with other outputs.
    other,
    /// Not at all.
    missing,
};

/// How `doc` shows `$ <command>` with `output` below it.
fn exchangeShown(doc: []const u8, command: []const u8, output: []const u8) !Exchange {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const line = try std.mem.concat(testing.allocator, u8, &.{ "\n$ ", command, "\n" });
    defer testing.allocator.free(line);
    var shown_any = false;
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, line)) |at| {
        shown_any = true;
        const body = rest[at + line.len ..];
        rest = body;
        const fence = closingFence(body) orelse body.len;
        const end = std.mem.find(u8, body[0..fence], "\n$ ") orelse fence;
        if (try sameMasked(body[0..end], output)) return .same;
    }
    return if (shown_any) .other else .missing;
}

/// Fails unless every ```text block of the document `name`, `doc`, that
/// begins with `$ <command>` shows the first lines of `output`, and one of
/// them all of it: the log of a service, which a guide shows as it starts
/// and again as it stops. A line `^C` of a block, where the reader stops
/// the service, is not a line of the output.
pub fn expectSession(name: []const u8, doc: []const u8, command: []const u8, output: []const u8) !void {
    const shown = try sessionShown(doc, command, output);
    if (shown == .whole) return;
    const expected = try maskedLines(output);
    defer testing.allocator.free(expected);
    if (shown == .other_start) {
        std.debug.print("{s} shows a run of `$ {s}` that is not how its output begins; the parts in <> may vary:\n{s}\n", .{ name, command, expected });
    } else {
        std.debug.print("{s} shows no whole run of `$ {s}`; the parts in <> may vary:\n{s}\n", .{ name, command, expected });
    }
    return error.TestSessionNotInGuide;
}

/// How a document shows the runs of a command against its output.
const Session = enum {
    /// Each run as the output begins, and one of them whole.
    whole,
    /// A run that is not how the output begins.
    other_start,
    /// No run, or none of them whole.
    not_whole,
};

/// How `doc` shows the runs of `$ <command>` against `output`, as
/// `expectSession` checks them.
fn sessionShown(doc: []const u8, command: []const u8, output: []const u8) !Session {
    const text = try unixLines(doc);
    defer testing.allocator.free(text);
    const expected = try maskedLines(output);
    defer testing.allocator.free(expected);
    const start = try std.mem.concat(testing.allocator, u8, &.{ "```text\n$ ", command, "\n" });
    defer testing.allocator.free(start);
    var whole = false;
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, start)) |at| {
        const body = rest[at + start.len ..];
        const end = closingFence(body) orelse return error.TestUnclosedBlock;
        rest = body[end..];
        var shown: std.ArrayList(u8) = .empty;
        defer shown.deinit(testing.allocator);
        var lines = std.mem.splitScalar(u8, body[0..end], '\n');
        while (lines.next()) |l| {
            if (std.mem.eql(u8, l, "^C")) continue;
            try shown.appendSlice(testing.allocator, l);
            try shown.append(testing.allocator, '\n');
        }
        const masked = try maskedLines(shown.items);
        defer testing.allocator.free(masked);
        if (!std.mem.startsWith(u8, expected, masked)) return .other_start;
        if (masked.len == expected.len) whole = true;
    }
    return if (whole) .whole else .not_whole;
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

/// `text` with the parts that change from run to run replaced: a zefir-log
/// timestamp at the start of a line by `<timestamp>`, the values of
/// `varying_headers` by `<…>`, the values of `varying_fields` by `<…>`, and
/// every id of 32 lowercase hex digits, the kind the server draws for a
/// request or a trace, by `<id>`. An id a client gave, such as
/// `checkout-42`, stays.
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
        if (varyingHeader(rest)) |name_len| {
            try out.appendSlice(testing.allocator, rest[0..name_len]);
            try out.appendSlice(testing.allocator, ": <…>");
            continue;
        }
        var i: usize = 0;
        while (i < rest.len) {
            if (varyingFieldAt(rest[i..])) |found| {
                try out.appendSlice(testing.allocator, rest[i..][0..found.key]);
                try out.appendSlice(testing.allocator, "<…>");
                i += found.key + found.value;
            } else if (idAt(rest, i)) {
                try out.appendSlice(testing.allocator, "<id>");
                i += id_len;
            } else {
                try out.append(testing.allocator, rest[i]);
                i += 1;
            }
        }
    }
    return out.toOwnedSlice(testing.allocator);
}

/// The length of the name when `line` is a header field of
/// `varying_headers`, `Name: value`, in any case.
fn varyingHeader(line: []const u8) ?usize {
    const colon = std.mem.find(u8, line, ": ") orelse return null;
    for (varying_headers) |name| {
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return colon;
    }
    return null;
}

const Varying = struct {
    /// The length of the key, with its ` ` and `=`.
    key: usize,
    /// The length of the value after it.
    value: usize,
};

fn varyingFieldAt(s: []const u8) ?Varying {
    inline for (varying_fields) |name| {
        const key = " " ++ name ++ "=";
        if (std.mem.startsWith(u8, s, key)) {
            const value = s[key.len..];
            return .{ .key = key.len, .value = std.mem.findScalar(u8, value, ' ') orelse value.len };
        }
    }
    return null;
}

const id_len = 32;

/// Whether an id of 32 lowercase hex digits starts at `i` of `line`, with
/// no letter or digit right before or after it.
fn idAt(line: []const u8, i: usize) bool {
    if (i + id_len > line.len) return false;
    if (i > 0 and std.ascii.isAlphanumeric(line[i - 1])) return false;
    if (i + id_len < line.len and std.ascii.isAlphanumeric(line[i + id_len])) return false;
    for (line[i..][0..id_len]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
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

test "what varies is masked: timestamps, Date, ETag, durations, ports and drawn ids; given ids stay" {
    const text = "2026-10-17T19:45:03.120Z INFO  [access] Request status=200 request=4bf92f3577b34da6a3ce929d0e0e4736 duration_ms=12\n" ++
        "x-request-id: 4bf92f3577b34da6a3ce929d0e0e4736\n" ++
        "x-request-id: checkout-42\n" ++
        "Date: Sat, 17 Oct 2026 19:45:03 GMT\n" ++
        "ETag: \"1a2b-3c\"\n" ++
        "INFO  [app] Serving port=54321\n" ++
        "{\"code\":\"todos.not_found\",\"traceId\":\"0af7651916cd43dd8448eb211c80319c\"}";
    const masked = try mask(text);
    defer testing.allocator.free(masked);
    try testing.expectEqualStrings("<timestamp> INFO  [access] Request status=200 request=<id> duration_ms=<…>\n" ++
        "x-request-id: <id>\n" ++
        "x-request-id: checkout-42\n" ++
        "Date: <…>\n" ++
        "ETag: <…>\n" ++
        "INFO  [app] Serving port=<…>\n" ++
        "{\"code\":\"todos.not_found\",\"traceId\":\"<id>\"}", masked);
    // Hex that is longer or shorter, or a part of a word, is no id.
    for ([_][]const u8{ "4bf92f3577b34da6a3ce929d0e0e47360", "4bf92f3577b34da6a3ce929d0e0e473", "x4bf92f3577b34da6a3ce929d0e0e4736" }) |word| {
        const kept = try mask(word);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings(word, kept);
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

test "an exchange is a command and its output, up to the next command or the end of the block" {
    const doc = "```text\n$ curl -i localhost:8080/a\nHTTP/1.1 200 OK\nDate: Sat, 17 Oct 2026 19:45:03 GMT\n\nfirst\n\n$ curl -i localhost:8080/b\nHTTP/1.1 404 Not Found\n```\n";
    try expectExchange("doc", doc, "curl -i localhost:8080/a", "HTTP/1.1 200 OK\r\nDate: Sun, 18 Oct 2026 10:00:00 GMT\r\n\r\nfirst");
    try expectExchange("doc", doc, "curl -i localhost:8080/b", "HTTP/1.1 404 Not Found\n");
    // What expectExchange fails on, without the message it prints.
    try testing.expectEqual(.other, try exchangeShown(doc, "curl -i localhost:8080/b", "HTTP/1.1 200 OK\n"));
    try testing.expectEqual(.missing, try exchangeShown(doc, "curl -i localhost:8080/c", "HTTP/1.1 200 OK\n"));
}

test "a block closes at a line that starts with its fence, and an exchange at the end of its block" {
    const file = "//! ```zig\n//! const a = 1;\n//! ```\nconst b = 2;\n";
    const doc = "```zig\n" ++ file ++ "```\n";
    try expectZigFromExamples("doc", doc, &.{file});
    // The second command is in another block: the first one's output ends
    // with its own block.
    const two = "```text\n$ curl -i localhost:8080/a\nHTTP/1.1 200 OK\n```\n\nText.\n\n```text\n$ curl -i localhost:8080/b\nHTTP/1.1 404 Not Found\n```\n";
    try expectExchange("doc", two, "curl -i localhost:8080/a", "HTTP/1.1 200 OK\n");
}

test "a session shows how its log begins, and once all of it, ^C aside" {
    const log = "2026-10-17T19:45:01.000Z INFO  [app] Serving port=54321\n2026-10-17T19:45:02.000Z INFO  [app] Stopping\n2026-10-17T19:45:02.001Z INFO  [app] Stopped\n";
    const doc = "```text\n$ zig build run\n2026-10-17T10:00:00.000Z INFO  [app] Serving port=8080\n```\n\nLater:\n\n```text\n$ zig build run\n2026-10-17T10:00:00.000Z INFO  [app] Serving port=8080\n^C\n2026-10-17T10:00:09.000Z INFO  [app] Stopping\n2026-10-17T10:00:09.001Z INFO  [app] Stopped\n```\n";
    try expectSession("doc", doc, "zig build run", log);
    // Only the beginning, or a block that is not how the log begins: what
    // expectSession fails on, without the message it prints.
    try testing.expectEqual(.not_whole, try sessionShown(doc[0..std.mem.find(u8, doc, "Later").?], "zig build run", log));
    try testing.expectEqual(.not_whole, try sessionShown("No run here.\n", "zig build run", log));
    try testing.expectEqual(.other_start, try sessionShown("```text\n$ zig build run\nINFO  [app] Stopped\n```\n", "zig build run", log));
}

test "a guide passes when it shows the file, the run and only parts of the file" {
    const file = "const x = 1;\nconst y = 2;\n";
    const doc = "Text.\n\n```zig\nconst x = 1;\nconst y = 2;\n```\n\n```zig\nconst y = 2;\n```\n\n```zig\n// build.zig\nb.foo();\n```\n\n```text\n$ zig build run\nPOST /api/v1/todos\n```\n";
    try expectFile("doc", doc, "zig", file);
    try expectRun("doc", doc, file, "$ zig build run", "POST /api/v1/todos\n");
    try expectZigFromExamples("doc", doc, &.{file});
    const foreign = (try foreignZig(doc, &.{"const z = 3;\n"})).?;
    defer testing.allocator.free(foreign);
    try testing.expectEqualStrings("const x = 1;\nconst y = 2;\n", foreign);
}
