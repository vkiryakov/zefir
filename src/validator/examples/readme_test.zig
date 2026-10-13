//! README.md shows every example of `cases.examples` verbatim, and a run of
//! every example program: an example that changes without its copy in
//! README.md fails this test. The examples of the rule pages are checked by
//! pages_test.zig.

const std = @import("std");
const cases = @import("cases");

const readme = @embedFile("README.md");

/// Fails unless README.md contains `block`. Both are compared with "\r\n"
/// turned into "\n", since Git may check files out with CRLF on Windows.
fn expectInReadme(block: []const u8) !void {
    const gpa = std.testing.allocator;
    const doc = try std.mem.replaceOwned(u8, gpa, readme, "\r\n", "\n");
    defer gpa.free(doc);
    const wanted = try std.mem.replaceOwned(u8, gpa, block, "\r\n", "\n");
    defer gpa.free(wanted);
    if (std.mem.find(u8, doc, wanted) == null) {
        std.debug.print("README.md does not contain this block:\n{s}\n", .{wanted});
        return error.TestBlockNotInReadme;
    }
}

/// Fails unless README.md shows a run of a program that logs `records`: a
/// ```text block of `$ zig build run` and then the lines of `records`, in
/// order, each after a timestamp and a space. The timestamps of a run are
/// its own, so the block may show any.
fn expectRunInReadme(records: []const u8) !void {
    const gpa = std.testing.allocator;
    const doc = try std.mem.replaceOwned(u8, gpa, readme, "\r\n", "\n");
    defer gpa.free(doc);
    const start = "```text\n$ zig build run\n";
    var rest: []const u8 = doc;
    while (std.mem.find(u8, rest, start)) |at| {
        const body = rest[at + start.len ..];
        const end = std.mem.find(u8, body, "```\n") orelse break;
        if (showsRecords(body[0..end], records)) return;
        rest = body[end..];
    }
    std.debug.print("README.md shows no run that logs these records, each after a timestamp:\n{s}\n", .{records});
    return error.TestRunNotInReadme;
}

/// Whether the lines of `shown` are the lines of `records`, each after a
/// timestamp and a space.
fn showsRecords(shown: []const u8, records: []const u8) bool {
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

test "README.md shows every example file verbatim" {
    inline for (cases.examples) |example| {
        try expectInReadme("```zig\n" ++ @embedFile(example.name ++ ".zig") ++ "```\n");
    }
}

test "README.md shows a run of every example program" {
    inline for (cases.examples) |example| {
        if (example.records) |records| try expectRunInReadme(records);
    }
}
