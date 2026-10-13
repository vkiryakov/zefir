//! The "All rules" index of README.md against the module and all_rules.zig:
//! every rule the module exports has exactly one row, every row names such a
//! rule, and the Example of every row uses its rule and is an entry of
//! all_rules.zig, which compiles it. So a rule added without a row, or an
//! example that changes in README.md or in all_rules.zig alone, fails here.

const std = @import("std");
const v = @import("validator");
const testing = std.testing;

const readme = @embedFile("README.md");
const all_rules = @embedFile("all_rules.zig");

/// The names of the rules the module exports: rule values, and functions
/// that return a rule.
const rule_names = names: {
    var names: []const []const u8 = &.{};
    for (std.meta.declarations(v)) |name| {
        const T = @TypeOf(@field(v, name));
        if (T == v.Rule or (@typeInfo(T) == .@"fn" and @typeInfo(T).@"fn".return_type == v.Rule))
            names = names ++ [_][]const u8{name};
    }
    break :names names;
};

const header = "| Rule | Example | Checks | Code |";

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `text` uses the rule `name`: `v.<name>` not followed by more of
/// an identifier, so that `v.min` is not found in `v.minLength(8)`.
fn usesRule(text: []const u8, name: []const u8) bool {
    var rest = text;
    while (std.mem.find(u8, rest, "v.")) |at| {
        const after = rest[at + 2 ..];
        if (std.mem.startsWith(u8, after, name) and (after.len == name.len or !isIdentifierByte(after[name.len]))) return true;
        rest = after;
    }
    return false;
}

/// Whether some line of `source`, without its indentation, is `entry`
/// followed by a comma: the entry as it stands in a `field_rules` literal.
fn hasEntry(source: []const u8, entry: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = std.mem.trimStart(u8, line, " ");
        if (code.len == entry.len + 1 and std.mem.startsWith(u8, code, entry) and code[entry.len] == ',') return true;
    }
    return false;
}

test "every rule has one row in the All rules index of README.md, with an example that all_rules.zig declares" {
    const gpa = testing.allocator;
    // Git may check files out with CRLF on Windows.
    const doc = try std.mem.replaceOwned(u8, gpa, readme, "\r\n", "\n");
    defer gpa.free(doc);
    const source = try std.mem.replaceOwned(u8, gpa, all_rules, "\r\n", "\n");
    defer gpa.free(source);

    const heading = "\n## All rules\n";
    const start = std.mem.find(u8, doc, heading) orelse return error.TestNoAllRulesSection;
    var section = doc[start + heading.len ..];
    if (std.mem.find(u8, section, "\n## ")) |end| section = section[0..end];

    var rows: [rule_names.len]usize = @splat(0);
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) continue;
        if (std.mem.eql(u8, line, header) or std.mem.startsWith(u8, line, "| --- |")) continue;
        if (line.len < 4 or !std.mem.startsWith(u8, line, "| ") or !std.mem.endsWith(u8, line, " |")) return badRow(line, "is not a table row");
        var cells = std.mem.splitSequence(u8, line[2 .. line.len - 2], " | ");
        const rule = cells.next().?;
        const example = cells.next() orelse return badRow(line, "has no Example");
        _ = cells.next() orelse return badRow(line, "has no Checks");
        _ = cells.next() orelse return badRow(line, "has no Code");
        if (cells.next() != null) return badRow(line, "has more than the 4 cells of " ++ header);

        // The Rule cell is `v.<name>...`, possibly as the text of a link.
        const prefix = if (std.mem.startsWith(u8, rule, "[")) "[`v." else "`v.";
        if (!std.mem.startsWith(u8, rule, prefix)) return badRow(line, "has a Rule cell that does not start with `v.");
        var len: usize = 0;
        while (prefix.len + len < rule.len and isIdentifierByte(rule[prefix.len + len])) len += 1;
        const name = rule[prefix.len..][0..len];
        const index = for (rule_names, 0..) |known, i| {
            if (std.mem.eql(u8, known, name)) break i;
        } else return badRow(line, "names no rule of the module");
        rows[index] += 1;

        if (example.len < 2 or example[0] != '`' or example[example.len - 1] != '`') return badRow(line, "has an Example that is not one code span");
        const entry = example[1 .. example.len - 1];
        if (!usesRule(entry, name)) return badRow(line, "has an Example that does not use its rule");
        if (!hasEntry(source, entry)) return badRow(line, "has an Example that all_rules.zig does not declare verbatim, as a line `<example>,`");
    }

    for (rule_names, rows) |name, count| {
        if (count != 1) {
            std.debug.print("v.{s} has {d} rows in the All rules index of README.md; it needs exactly 1\n", .{ name, count });
            return error.TestRuleRows;
        }
    }
}

fn badRow(line: []const u8, problem: []const u8) error{TestBadRow} {
    std.debug.print("this row of the All rules index of README.md {s}:\n{s}\n", .{ problem, line });
    return error.TestBadRow;
}
