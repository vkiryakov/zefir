//! Escaping of record strings, shared by the JSON and text formats.
//!
//! `"`, `\`, control characters (C0, DEL and C1), the line and paragraph
//! separators U+2028 and U+2029, and the bidi controls that reorder text
//! become escape sequences; other valid UTF-8 passes through, and every byte
//! that does not start a valid UTF-8 sequence becomes U+FFFD. The output is
//! valid UTF-8 without line breaks, so one record stays one line, also in a
//! terminal.

const std = @import("std");
const testing = std.testing;

const replacement = "\u{FFFD}";

const Kind = enum { verbatim, short_escape, unicode_escape, invalid };

/// One character of the input: what it becomes, and how many input bytes
/// it takes.
const Unit = struct {
    kind: Kind,
    len: u3,
    /// The code point a `.unicode_escape` writes.
    cp: u21 = 0,

    fn outLen(unit: Unit) usize {
        return switch (unit.kind) {
            .verbatim => unit.len,
            .short_escape => 2,
            .unicode_escape => 6,
            .invalid => replacement.len,
        };
    }
};

fn unitAt(s: []const u8, i: usize) Unit {
    const c = s[i];
    if (c < 0x80) return switch (c) {
        '"', '\\', '\n', '\r', '\t' => .{ .kind = .short_escape, .len = 1 },
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => .{ .kind = .unicode_escape, .len = 1, .cp = c },
        else => .{ .kind = .verbatim, .len = 1 },
    };
    const bad: Unit = .{ .kind = .invalid, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(c) catch return bad;
    if (n > s.len - i) return bad;
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return bad;
    if (isHidden(cp)) return .{ .kind = .unicode_escape, .len = n, .cp = cp };
    return .{ .kind = .verbatim, .len = n };
}

/// Valid code points that would still break a line or fool a reader: C1
/// controls (U+0085 ends a line for some readers, U+009B starts a terminal
/// escape), the line and paragraph separators, and the bidi controls that
/// make a terminal show text in another order.
fn isHidden(cp: u21) bool {
    return switch (cp) {
        0x80...0x9f, 0x2028, 0x2029, 0x202a...0x202e, 0x2066...0x2069 => true,
        else => false,
    };
}

/// Writes `s` escaped, without quotes.
pub fn write(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0; // the first byte not written yet
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        if (unit.kind != .verbatim) {
            try w.writeAll(s[start..i]);
            try writeEscape(w, s[i], unit);
            start = i + unit.len;
        }
        i += unit.len;
    }
    try w.writeAll(s[start..]);
}

fn writeEscape(w: *std.Io.Writer, c: u8, unit: Unit) std.Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    switch (unit.kind) {
        .verbatim => unreachable,
        .short_escape => try w.writeAll(&[2]u8{
            '\\',
            switch (c) {
                '\n' => 'n',
                '\r' => 'r',
                '\t' => 't',
                else => c, // '"' and '\\'
            },
        }),
        .unicode_escape => try w.writeAll(&[6]u8{
            '\\',
            'u',
            hex[unit.cp >> 12 & 0xf],
            hex[unit.cp >> 8 & 0xf],
            hex[unit.cp >> 4 & 0xf],
            hex[unit.cp & 0xf],
        }),
        .invalid => try w.writeAll(replacement),
    }
}

/// The length of `s` once escaped.
pub fn escapedLen(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        total += unit.outLen();
        i += unit.len;
    }
    return total;
}

/// The length of the longest prefix of `s` whose escaped form fits in
/// `budget` bytes. The cut falls between characters, never inside a UTF-8
/// sequence or an escape.
pub fn fittingPrefix(s: []const u8, budget: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        used += unit.outLen();
        if (used > budget) break;
        i += unit.len;
    }
    return i;
}

/// Whether the text format may write `s` without quotes: it is not empty
/// and has no spaces, no `=`, nothing that needs escaping and no invalid
/// UTF-8.
pub fn isBare(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        if (unit.kind != .verbatim or s[i] == ' ' or s[i] == '=') return false;
        i += unit.len;
    }
    return true;
}

fn expectEscaped(expected: []const u8, input: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, input);
    try testing.expectEqualStrings(expected, w.buffered());
    try testing.expectEqual(expected.len, escapedLen(input));
}

test "quotes, backslashes, control characters and DEL become escapes" {
    try expectEscaped("a\\\"b\\\\c", "a\"b\\c");
    try expectEscaped("\\n\\r\\t", "\n\r\t");
    try expectEscaped("\\u0000\\u0001\\u001b\\u007f", "\x00\x01\x1b\x7f");
}

test "C1 controls, line and paragraph separators and bidi controls become escapes" {
    try expectEscaped("nel\\u0085x", "nel\u{85}x");
    try expectEscaped("\\u0080\\u009b31m", "\u{80}\u{9b}31m");
    try expectEscaped("a\\u2028b\\u2029c", "a\u{2028}b\u{2029}c");
    try expectEscaped("\\u202a\\u202e\\u2066\\u2069", "\u{202a}\u{202e}\u{2066}\u{2069}");
    try expectEscaped("\u{a0}\u{2027}\u{202f}\u{2065}\u{206a}", "\u{a0}\u{2027}\u{202f}\u{2065}\u{206a}"); // their neighbours pass
    try testing.expect(!isBare("x\u{2028}y"));
    try testing.expect(!isBare("\u{9b}31mred"));
    try testing.expectEqual(@as(usize, 1), fittingPrefix("a\u{85}", 6)); // "\\u0085" takes 6
    try testing.expectEqual(@as(usize, 3), fittingPrefix("a\u{85}", 7));
}

test "valid UTF-8 passes through" {
    try expectEscaped("é € 😀", "é € 😀");
}

test "every invalid byte becomes U+FFFD" {
    try expectEscaped("\u{FFFD}", "\xff");
    try expectEscaped("a\u{FFFD}", "a\xc3"); // a sequence cut short
    try expectEscaped("\u{FFFD}\u{FFFD}", "\xc0\x80"); // overlong
    try expectEscaped("\u{FFFD}\u{FFFD}\u{FFFD}", "\xed\xa0\x80"); // a surrogate
    try expectEscaped("\u{FFFD}x", "\x80x"); // a stray continuation byte
}

test "no pair of bytes can break the line or the encoding" {
    for (0..256) |a| {
        for (0..256) |b| {
            const input = [2]u8{ @intCast(a), @intCast(b) };
            var buf: [16]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try write(&w, &input);
            try testing.expect(std.unicode.utf8ValidateSlice(w.buffered()));
            try testing.expect(std.mem.findScalar(u8, w.buffered(), '\n') == null);
            try testing.expect(std.mem.findScalar(u8, w.buffered(), '\r') == null);
        }
    }
}

test "fittingPrefix cuts between characters, never inside one" {
    try testing.expectEqual(@as(usize, 2), fittingPrefix("ab😀", 5)); // the 4-byte emoji does not fit
    try testing.expectEqual(@as(usize, 6), fittingPrefix("ab😀", 6));
    try testing.expectEqual(@as(usize, 1), fittingPrefix("a\nb", 2)); // "\\n" takes 2 bytes
    try testing.expectEqual(@as(usize, 0), fittingPrefix("\x01", 5)); // "\\u0001" takes 6
    try testing.expectEqual(@as(usize, 1), fittingPrefix("\xffz", 3)); // U+FFFD takes 3
    try testing.expectEqual(@as(usize, 0), fittingPrefix("", 0));
}

test "isBare: which text values may go without quotes" {
    try testing.expect(isBare("admin"));
    try testing.expect(isBare("café"));
    try testing.expect(isBare("a/b:c"));
    try testing.expect(!isBare(""));
    try testing.expect(!isBare("a b"));
    try testing.expect(!isBare("a=b"));
    try testing.expect(!isBare("a\"b"));
    try testing.expect(!isBare("a\\b"));
    try testing.expect(!isBare("a\nb"));
    try testing.expect(!isBare("\xff"));
}
