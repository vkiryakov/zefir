//! `.env` files: one `KEY=value` per line.
//!
//! - Keys match `[A-Za-z_][A-Za-z0-9_]*`; `export KEY=value` is accepted.
//! - `#` starts a comment at the start of a line, or after whitespace in an unquoted value.
//! - "Double quotes" unescape `\n`, `\t`, `\r`, `\"` and `\\`; 'single quotes' are literal.
//! - An empty value (`KEY=`) is an empty string.
//! - Lines without `=`, invalid keys, unterminated quotes and repeated keys are
//!   reported to `diag`; the rest of the file is still read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("../Diagnostics.zig");
const Origin = @import("../tree.zig").Origin;

pub const Entry = struct {
    value: []const u8,
    /// 1-based line in the file.
    line: u32,
};

/// Variables by name, in file order. Keys and values point into `text` or the arena.
pub const Vars = std.array_hash_map.String(Entry);

pub fn parse(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostics) Allocator.Error!Vars {
    var vars: Vars = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: u32 = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");

        const origin: Origin = .{ .file = file, .line = line_number };
        const eq = std.mem.findScalar(u8, line, '=') orelse {
            try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected KEY=value" });
            continue;
        };
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (!isValidKey(key)) {
            try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected a variable name like APP_PORT before '='" });
            continue;
        }

        const key_origin: Origin = .{ .file = file, .line = line_number, .env_key = key };
        const value = parseValue(arena, std.mem.trimStart(u8, line[eq + 1 ..], " \t")) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnterminatedQuote => {
                try diag.add(.{ .kind = .syntax, .origin = key_origin, .detail = "unterminated quote" });
                continue;
            },
        };

        const gop = try vars.getOrPut(arena, key);
        if (gop.found_existing) {
            try diag.addFmt(.duplicate_key, "", key_origin, "first set on line {d}", .{gop.value_ptr.line});
            continue;
        }
        gop.value_ptr.* = .{ .value = value, .line = line_number };
    }
    return vars;
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn parseValue(arena: Allocator, raw: []const u8) error{ OutOfMemory, UnterminatedQuote }![]const u8 {
    if (raw.len == 0) return raw;
    switch (raw[0]) {
        '\'' => {
            const end = std.mem.findScalar(u8, raw[1..], '\'') orelse return error.UnterminatedQuote;
            return raw[1 .. 1 + end];
        },
        '"' => {
            var value: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i < raw.len) : (i += 1) {
                switch (raw[i]) {
                    '"' => return value.items,
                    '\\' => {
                        i += 1;
                        if (i == raw.len) break;
                        switch (raw[i]) {
                            'n' => try value.append(arena, '\n'),
                            't' => try value.append(arena, '\t'),
                            'r' => try value.append(arena, '\r'),
                            '"', '\\' => try value.append(arena, raw[i]),
                            else => try value.appendSlice(arena, raw[i - 1 .. i + 1]),
                        }
                    },
                    else => |c| try value.append(arena, c),
                }
            }
            return error.UnterminatedQuote;
        },
        else => {
            var end = raw.len;
            for (raw, 0..) |c, i| {
                if (c == '#' and i > 0 and (raw[i - 1] == ' ' or raw[i - 1] == '\t')) {
                    end = i;
                    break;
                }
            }
            return std.mem.trimEnd(u8, raw[0..end], " \t");
        },
    }
}

fn expectParsed(text: []const u8, expected: []const [2][]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const vars = try parse(arena_state.allocator(), text, ".env", &diag);
    try std.testing.expectEqual(0, diag.problems.items.len);
    try std.testing.expectEqual(expected.len, vars.count());
    for (expected, vars.keys(), vars.values()) |pair, key, entry| {
        try std.testing.expectEqualStrings(pair[0], key);
        try std.testing.expectEqualStrings(pair[1], entry.value);
    }
}

test "plain, exported, quoted and commented values" {
    try expectParsed(
        \\# comment
        \\APP_PORT=8080
        \\export APP_HOST = localhost
        \\APP_NAME="zefir app"
        \\APP_RAW='no \n escapes'
        \\APP_ESCAPED="line\nnext \"quoted\" back\\slash"
        \\APP_INLINE=value # comment
        \\APP_HASH=a#b
        \\APP_EMPTY=
        \\APP_CRLF=yes
    ++ "\r\n", &.{
        .{ "APP_PORT", "8080" },
        .{ "APP_HOST", "localhost" },
        .{ "APP_NAME", "zefir app" },
        .{ "APP_RAW", "no \\n escapes" },
        .{ "APP_ESCAPED", "line\nnext \"quoted\" back\\slash" },
        .{ "APP_INLINE", "value" },
        .{ "APP_HASH", "a#b" },
        .{ "APP_EMPTY", "" },
        .{ "APP_CRLF", "yes" },
    });
}

test "problems are reported and the rest is read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const vars = try parse(arena_state.allocator(),
        \\APP_PORT=8080
        \\not a pair
        \\9LIVES=yes
        \\APP_NAME="unterminated
        \\APP_PORT=9090
        \\APP_HOST=localhost
    , ".env", &diag);

    try std.testing.expectEqual(2, vars.count());
    try std.testing.expectEqualStrings("8080", vars.get("APP_PORT").?.value);

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\4 configuration problems:
        \\  .env:2: syntax error (expected KEY=value)
        \\  .env:3: syntax error (expected a variable name like APP_PORT before '=')
        \\  .env:4: APP_NAME: syntax error (unterminated quote)
        \\  .env:5: APP_PORT: duplicate key (first set on line 1)
    , text);
}

test "spacing, quotes and escapes at the edges" {
    try expectParsed(
        \\SPACED = value
        \\export   MANY_SPACES=1
        \\QUOTED_COMMENT="a b" # comment
        \\SINGLE_HASH='a #b'
        \\UNKNOWN_ESCAPE="a\qb"
        \\EMPTY_QUOTES=""
        \\_UNDERSCORE=1
        \\
    ++ "TRAILING=value   \n", &.{
        .{ "SPACED", "value" },
        .{ "MANY_SPACES", "1" },
        .{ "QUOTED_COMMENT", "a b" },
        .{ "SINGLE_HASH", "a #b" },
        .{ "UNKNOWN_ESCAPE", "a\\qb" },
        .{ "EMPTY_QUOTES", "" },
        .{ "_UNDERSCORE", "1" },
        .{ "TRAILING", "value" },
    });
}

test "unterminated quotes and invalid names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const vars = try parse(arena_state.allocator(),
        \\A='open
        \\B="escape at the end\
        \\=no name
        \\MY-KEY=1
        \\VALID=1
    , ".env", &diag);

    try std.testing.expectEqual(1, vars.count());

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\4 configuration problems:
        \\  .env:1: A: syntax error (unterminated quote)
        \\  .env:2: B: syntax error (unterminated quote)
        \\  .env:3: syntax error (expected a variable name like APP_PORT before '=')
        \\  .env:4: syntax error (expected a variable name like APP_PORT before '=')
    , text);
}
