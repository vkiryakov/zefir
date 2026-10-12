//! The string rules through `check` and `checkAll`: code points and bytes,
//! the utf8 precondition and its order, the character classes on every byte,
//! White_Space and the width classes on every scalar value, messages and
//! placeholders, every kind of string field, and random bytes into every rule.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const S = []const u8;
const utf8_code = "validation.utf8";
const utf8_message = "must be valid UTF-8";

/// `.{ .x = value }` on a `[]const u8` field passes `rules`.
fn passes(comptime rules: anytype, value: S) bool {
    const Dto = h.One(S, rules);
    var buf: [8]u8 = undefined;
    return v.check(&Dto{ .x = value }, &buf) == null;
}

/// The UTF-8 encoding of the scalar value `cp`.
fn encode(cp: u21, out: *[4]u8) S {
    const n = std.unicode.utf8Encode(cp, out) catch unreachable;
    return out[0..n];
}

/// `s` repeated `n` times, at compile time.
inline fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}

/// Random bytes, or random picks from bytes that matter to the rules (ASCII
/// classes, UTF-8 leads and continuations, invalid bytes), of 0-24 bytes.
fn randomString(random: std.Random, buf: *[24]u8) S {
    const alphabet = "aA1 !\x00\x7f\x80\xbf\xc0\xc2\xe0\xed\xef\xf0\xf4\xf5\xff";
    const n = random.uintLessThan(usize, buf.len + 1);
    if (random.boolean()) {
        random.bytes(buf[0..n]);
    } else {
        for (buf[0..n]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
    }
    return buf[0..n];
}

/// `rule` reports its own code on `.{ .x = value }`.
fn expectOwnFailure(comptime T: type, comptime rule: v.Rule, value: T) !void {
    const got = (try h.run(T, rule, value)) orelse return error.TestExpectedViolation;
    try testing.expectEqualStrings(rule.code, got.code);
}

/// Every rule of `passing` passes "abc" and every rule of `failing` fails it
/// with its own code, on every kind of string field: const or not, with a
/// sentinel, over-aligned.
fn expectEveryKindOfString(comptime passing: anytype, comptime failing: anytype) !void {
    var buffer = "abc".*;
    const mutable: []u8 = &buffer;
    var with_zero = "abc".*;
    const mutable_z: [:0]u8 = with_zero[0..3 :0];
    const aligned_bytes: [3]u8 align(4) = "abc".*;
    const aligned: []align(4) const u8 = &aligned_bytes;
    inline for (passing) |rule| {
        try h.expectPass([]const u8, rule, "abc");
        try h.expectPass([]u8, rule, mutable);
        try h.expectPass([:0]const u8, rule, "abc");
        try h.expectPass([:0]u8, rule, mutable_z);
        try h.expectPass([]align(4) const u8, rule, aligned);
    }
    inline for (failing) |rule| {
        try expectOwnFailure([]const u8, rule, "abc");
        try expectOwnFailure([]u8, rule, mutable);
        try expectOwnFailure([:0]const u8, rule, "abc");
        try expectOwnFailure([:0]u8, rule, mutable_z);
        try expectOwnFailure([]align(4) const u8, rule, aligned);
    }
}

// ------------------------------------------------------------------ length and bytes

test "minLength, maxLength and length count code points: no trimming, normalization or grapheme clusters" {
    const cases = [_]struct { S, usize }{
        .{ "", 0 },
        .{ "abc", 3 },
        .{ "\u{E9}", 1 }, // precomposed
        .{ "e\u{301}", 2 }, // a combining mark
        .{ "\u{2764}\u{FE0F}", 2 }, // a variation selector counts
        .{ "\u{1F600}", 1 },
        .{ "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 7 }, // a family joined by ZWJ
        .{ "\u{FEFF}abc", 4 },
        .{ "a\x00b", 3 },
        .{ " \t ", 3 },
        .{ "\u{10FFFF}\u{D7FF}\u{E000}", 3 },
    };
    inline for (1..6) |k| {
        for (cases) |c| {
            try testing.expectEqual(c[1] >= k, passes(v.minLength(k), c[0]));
            try testing.expectEqual(c[1] <= k, passes(v.maxLength(k), c[0]));
            try testing.expectEqual(c[1] == k, passes(v.length(k, k), c[0]));
            try testing.expectEqual(c[1] >= k and c[1] <= k + 2, passes(v.length(k, k + 2), c[0]));
        }
    }
    try h.expectPass(S, v.maxLength(128), repeat("x", 128));
    try h.expectFail(S, v.maxLength(128), repeat("x", 129), "validation.max_length", "must be at most 128 characters");
    try h.expectPass(S, v.maxLength(64), repeat("я", 64));
    try h.expectFail(S, v.minLength(3), "ab", "validation.min_length", "must be at least 3 characters");
    try h.expectFail(S, v.minLength(1), "", "validation.min_length", "must be at least 1 character");
    try h.expectFail(S, v.length(2, 4), "abcde", "validation.length", "must be from 2 to 4 characters");
    try h.expectFail(S, v.length(5, 5), "abcd", "validation.length", "must be exactly 5 characters");
    try h.expectPass(S, v.maxLength(1), "");
}

test "the utf8 precondition of the length rules comes first, even when the number of bytes alone would decide; withMessage keeps it" {
    try h.expectFail(S, v.minLength(3), "\xff", utf8_code, utf8_message);
    try h.expectFail(S, v.maxLength(100), "\xff", utf8_code, utf8_message);
    try h.expectFail(S, v.length(1, 1), "\xc0\x80", utf8_code, utf8_message);
    try h.expectFail(S, v.minLength(1), "abc\xe6\x97", utf8_code, utf8_message);
    // Past the 8-byte ASCII fast path of the count.
    try h.expectFail(S, v.maxLength(1), repeat("a", 64) ++ "\x80", utf8_code, utf8_message);
    inline for (.{ v.minLength(1).withMessage("x"), v.maxLength(10).withMessage("x"), v.length(1, 10).withMessage("x") }) |rule| {
        try h.expectFail(S, rule, "\xff", utf8_code, utf8_message);
        try h.expectFail(S, rule, "Ab1!\xed\xa0\x80", utf8_code, utf8_message);
    }
    try h.expectFail(S, v.minLength(2).withMessage("name is too short"), "a", "validation.min_length", "name is too short");
    // The byte rules have no precondition: invalid UTF-8 is a value like any other.
    try h.expectFail(S, v.maxBytes(1).withMessage("x"), "\xff\xff", "validation.max_bytes", "x");
}

test "minBytes and maxBytes count raw bytes and never decode" {
    try h.expectPass(S, v.minBytes(3), "\xed\xa0\x80"); // an encoded surrogate: 3 bytes, invalid UTF-8
    try h.expectFail(S, v.minBytes(2), "\xff", "validation.min_bytes", "must be at least 2 bytes");
    try h.expectPass(S, v.maxBytes(3), "\xff\xff\xff");
    try h.expectFail(S, v.maxBytes(2), "\xff\xff\xff", "validation.max_bytes", "must be at most 2 bytes");
    try h.expectFail(S, v.minBytes(1), "", "validation.min_bytes", "must be at least 1 byte");
    try h.expectPass(S, v.minBytes(1), "\x00");
    try h.expectPass(S, v.maxBytes(1), "");
    try h.expectFail(S, v.maxBytes(8), "日本語", "validation.max_bytes", "must be at most 8 bytes");
    try h.expectPass(S, v.maxBytes(9), "日本語");
    // A byte limit put first rejects a long value before the count of code points.
    try h.expectFail(S, .{ v.maxBytes(2), v.minLength(1) }, "\xff\xff\xff", "validation.max_bytes", "must be at most 2 bytes");
    // The byte length of class-validator: a minimum and a maximum.
    const byte_length = .{ v.minBytes(2), v.maxBytes(4) };
    try h.expectFail(S, byte_length, "a", "validation.min_bytes", "must be at least 2 bytes");
    try h.expectPass(S, byte_length, "\u{E9}");
    try h.expectPass(S, byte_length, "\u{1F600}");
    try h.expectFail(S, byte_length, "abcde", "validation.max_bytes", "must be at most 4 bytes");
}

test "withMessage: the placeholders of the length and byte rules" {
    try h.expectRule(v.minLength(2).withMessage("at least {min}"), "validation.min_length", "at least 2");
    try h.expectRule(v.maxLength(64).withMessage("name must be at most {max} characters"), "validation.max_length", "name must be at most 64 characters");
    try h.expectRule(v.length(3, 32).withMessage("{min}..{max}"), "validation.length", "3..32");
    try h.expectRule(v.length(4, 4).withMessage("exactly {min} (= {max})"), "validation.length", "exactly 4 (= 4)");
    try h.expectRule(v.minBytes(8).withMessage("{min} bytes or more"), "validation.min_bytes", "8 bytes or more");
    try h.expectRule(v.maxBytes(255).withMessage("up to {max} bytes"), "validation.max_bytes", "up to 255 bytes");
    try h.expectFail(S, v.maxLength(64).withMessage("не длиннее {max} символов"), repeat("я", 65), "validation.max_length", "не длиннее 64 символов");
}

test "a length rule on items through each reports its template at the item's path; a null list skips it" {
    const Tags = struct {
        tags: ?[]const []const u8,
        pub const field_rules = .{ .tags = v.each(v.maxLength(3).withMessage("tag: at most {max}")) };
    };
    try h.expectAt(&Tags{ .tags = &.{ "abc", "abcd" } }, "validation.max_length", "tag: at most 3", "tags[1]");
    try h.expectValid(&Tags{ .tags = null });
}

test "the length and byte rules take every kind of string: const or not, with a sentinel, over-aligned" {
    try expectEveryKindOfString(
        .{ v.minLength(1), v.maxLength(8), v.length(1, 8), v.minBytes(1), v.maxBytes(8) },
        .{ v.minLength(4), v.maxLength(2), v.length(4, 8), v.minBytes(4), v.maxBytes(2) },
    );
}

test "a length rule on an optional field skips null and checks the value; on optional items through each" {
    try h.expectPass(?S, v.minLength(3), null);
    try h.expectFail(?S, v.minLength(3), "ab", "validation.min_length", "must be at least 3 characters");
    try h.expectPass(??S, v.maxBytes(1), null);
    try h.expectFail(??S, v.maxBytes(1), "ab", "validation.max_bytes", "must be at most 1 byte");
    const Codes = struct {
        codes: []const ?[]const u8,
        pub const field_rules = .{ .codes = v.each(v.length(4, 4)) };
    };
    try h.expectValid(&Codes{ .codes = &.{ "0123", null, "abcd" } });
    try h.expectAt(&Codes{ .codes = &.{ "0123", null, "123" } }, "validation.length", "must be exactly 4 characters", "codes[2]");
    try h.expectAll(&Codes{ .codes = &.{ "12", "1234", "\xff\xff\xff\xff" } }, &.{
        .{ .code = "validation.length", .field = "codes[0]" },
        .{ .code = utf8_code, .field = "codes[2]" },
    });
}

test "random bytes into the length and byte rules: no panic, and they agree with the count of code points" {
    var prng = std.Random.DefaultPrng.init(0x5715_0003);
    const random = prng.random();
    var buf: [24]u8 = undefined;
    for (0..20_000) |_| {
        const s = randomString(random, &buf);
        const count: ?usize = std.unicode.utf8CountCodepoints(s) catch null;
        try testing.expectEqual(std.unicode.utf8ValidateSlice(s), count != null);
        try testing.expectEqual(if (count) |c| c >= 3 else false, passes(v.minLength(3), s));
        try testing.expectEqual(if (count) |c| c <= 3 else false, passes(v.maxLength(3), s));
        try testing.expectEqual(if (count) |c| c >= 2 and c <= 5 else false, passes(v.length(2, 5), s));
        try testing.expectEqual(s.len >= 3, passes(v.minBytes(3), s));
        try testing.expectEqual(s.len <= 3, passes(v.maxBytes(3), s));
    }
}

// ------------------------------------------------------------------ utf8, notBlank, ASCII classes, widths

test "notBlank and the width rules report the utf8 precondition first, also under withMessage; the byte classes have none" {
    inline for (.{ v.notBlank, v.fullWidth, v.halfWidth, v.variableWidth }) |rule| {
        try h.expectFail(S, rule, "\xff", utf8_code, utf8_message);
        try h.expectFail(S, rule.withMessage("x"), "\xff", utf8_code, utf8_message);
        try h.expectFail(S, rule.withMessage("x"), "Ab1!\xed\xa0\x80", utf8_code, utf8_message);
    }
    try h.expectFail(S, v.ascii.withMessage("x"), "\xff", "validation.ascii", "x");
    try h.expectPass(S, v.multibyte, "\xff");
    try h.expectPass(S, v.lowercase, "\xff");
}

test "utf8 put first gives invalid UTF-8 its own message before a rule with the precondition" {
    const name = .{ v.utf8.withMessage("name must be UTF-8"), v.maxLength(4) };
    try h.expectFail(S, name, "ab\xff", utf8_code, "name must be UTF-8");
    try h.expectFail(S, name, "abcde", "validation.max_length", "must be at most 4 characters");
    try h.expectPass(S, name, "abcd");
}

test "isUtf8 is utf8ValidateSlice on every input of 1 and 2 bytes, and the rule agrees" {
    var buf: [2]u8 = undefined;
    for (0..256) |a| {
        buf[0] = @intCast(a);
        try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..1]), v.isUtf8(buf[0..1]));
        try testing.expectEqual(v.isUtf8(buf[0..1]), passes(v.utf8, buf[0..1]));
        for (0..256) |b| {
            buf[1] = @intCast(b);
            try testing.expectEqual(std.unicode.utf8ValidateSlice(&buf), v.isUtf8(&buf));
        }
    }
}

test "utf8 follows RFC 3629; its failure is its own check, so withMessage applies" {
    for ([_]S{ "", "abc", "\u{7F}", "\u{80}", "\u{7FF}", "\u{800}", "\u{D7FF}", "\u{E000}", "\u{FFFD}", "\u{FFFE}", "\u{FFFF}", "\u{10000}", "\u{10FFFF}", "\u{FEFF}", "a\x00b" }) |s|
        try h.expectPass(S, v.utf8, s);
    for ([_]S{ "\x80", "\xbf", "\xc0\x80", "\xc1\xbf", "\xc2", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xed\xbf\xbf", "\xf0\x80\x80\x80", "\xf0\x8f\xbf\xbf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xfe", "abc\xe6\x97", "\xe6\x97abc" }) |s|
        try h.expectFail(S, v.utf8, s, utf8_code, utf8_message);
    try h.expectFail(S, v.utf8.withMessage("bad text"), "\xff", utf8_code, "bad text");
}

/// Unicode White_Space: the 25 code points of the rule.
const white_space = [_]u21{ 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 };

test "notBlank: of every scalar value exactly the 25 White_Space code points are blank" {
    var blank: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        var one: [4]u8 = undefined;
        const s = encode(cp, &one);
        const is_white = std.mem.findScalar(u21, &white_space, cp) != null;
        if (is_white) blank += 1;
        try testing.expectEqual(!is_white, v.isNotBlank(s));
    }
    try testing.expectEqual(25, blank);
    // All of them at once are blank; any content passes.
    var all: [4 * white_space.len]u8 = undefined;
    var len: usize = 0;
    for (white_space) |w| {
        var one: [4]u8 = undefined;
        const s = encode(w, &one);
        @memcpy(all[len..][0..s.len], s);
        len += s.len;
    }
    try h.expectFail(S, v.notBlank, all[0..len], "validation.not_blank", "must not be blank");
    try h.expectFail(S, v.notBlank, "", "validation.not_blank", "must not be blank");
    for ([_]S{ "\u{200B}", "\u{FEFF}", "\u{180E}", "\u{2060}", "\u{AD}", "\u{3164}", "\u{115F}", "\u{1160}", "\u{FFA0}", "\u{2800}", "\x1c\x1d\x1e\x1f", " \u{200B} ", "\t\n\u{3000}x" }) |s|
        try h.expectPass(S, v.notBlank, s);
    try testing.expect(!v.isNotBlank(""));
}

test "notBlank: invalid UTF-8 anywhere is the precondition, also after content; withMessage keeps it" {
    for ([_]S{ "\xff", "abc\x80", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "abc\xe6\x97", "a\xff", "\xffa", " \xff", "\u{3000}\xe6\x97" }) |s| {
        try h.expectFail(S, v.notBlank, s, utf8_code, utf8_message);
        try h.expectFail(S, v.notBlank.withMessage("fill it in"), s, utf8_code, utf8_message);
        try testing.expect(!v.isNotBlank(s));
    }
    try h.expectFail(S, v.notBlank.withMessage("fill it in"), " ", "validation.not_blank", "fill it in");
    // notEmpty counts bytes: a space is not empty, but it is blank.
    try h.expectFail(S, .{ v.notEmpty, v.notBlank }, " ", "validation.not_blank", "must not be blank");
}

test "the ASCII classes, the case rules and multibyte on every byte agree with std.ascii, and the rules with their predicates" {
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const s: S = &.{c};
        try testing.expectEqual(c <= 0x7F, v.isAscii(s));
        try testing.expectEqual(std.ascii.isPrint(c), v.isPrintableAscii(s));
        try testing.expectEqual(std.ascii.isAlphanumeric(c), v.isAlphanumeric(s));
        try testing.expectEqual(std.ascii.isAlphabetic(c), v.isAlpha(s));
        try testing.expectEqual(std.ascii.isDigit(c), v.isDigits(s));
        try testing.expectEqual(!std.ascii.isUpper(c), v.isLowercase(s));
        try testing.expectEqual(!std.ascii.isLower(c), v.isUppercase(s));
        try testing.expectEqual(c >= 0x80, v.isMultibyte(s));
        try testing.expectEqual(v.isAscii(s), passes(v.ascii, s));
        try testing.expectEqual(v.isPrintableAscii(s), passes(v.printableAscii, s));
        try testing.expectEqual(v.isAlphanumeric(s), passes(v.alphanumeric, s));
        try testing.expectEqual(v.isAlpha(s), passes(v.alpha, s));
        try testing.expectEqual(v.isDigits(s), passes(v.digits, s));
        try testing.expectEqual(v.isLowercase(s), passes(v.lowercase, s));
        try testing.expectEqual(v.isUppercase(s), passes(v.uppercase, s));
        try testing.expectEqual(v.isMultibyte(s), passes(v.multibyte, s));
    }
    // "" is in every character class, and not in multibyte.
    inline for (.{ v.isUtf8, v.isAscii, v.isPrintableAscii, v.isAlphanumeric, v.isAlpha, v.isDigits, v.isLowercase, v.isUppercase }) |predicate| try testing.expect(predicate(""));
    try testing.expect(!v.isMultibyte(""));
    try h.expectFail(S, v.multibyte, "", "validation.multibyte", "must contain at least one non-ASCII character");
    // To require content, put notEmpty first.
    try h.expectFail(S, .{ v.notEmpty, v.digits }, "", "validation.not_empty", "must not be empty");
}

test "the ASCII classes fail on any byte outside the class, valid UTF-8 or not" {
    try h.expectFail(S, v.ascii, "caf\u{E9}", "validation.ascii", "must contain only ASCII characters");
    try h.expectPass(S, v.ascii, "\x00\x1f\x7f");
    try h.expectFail(S, v.printableAscii, "a\tb", "validation.printable_ascii", "must contain only printable ASCII characters");
    try h.expectPass(S, v.printableAscii, " ~");
    try h.expectFail(S, v.alphanumeric, "user_1", "validation.alphanumeric", "must contain only ASCII letters and digits");
    try h.expectFail(S, v.alphanumeric, "\u{FF11}\u{FF12}", "validation.alphanumeric", "must contain only ASCII letters and digits");
    try h.expectPass(S, v.alphanumeric, "abcXYZ019");
    try h.expectFail(S, v.alpha, "abc1", "validation.alpha", "must contain only ASCII letters");
    try h.expectFail(S, v.alpha, "\u{17F}", "validation.alpha", "must contain only ASCII letters");
    try h.expectPass(S, v.alpha, "Zefir");
    try h.expectFail(S, v.alphanumeric, "abc123\x80", "validation.alphanumeric", "must contain only ASCII letters and digits");
}

test "digits: no sign, point, exponent, whitespace or digits outside ASCII; leading zeros stay" {
    try h.expectPass(S, v.digits, "000123");
    try h.expectPass(S, v.digits, "");
    for ([_]S{ "-1", "+1", "1.5", "1e3", " 1", "1 ", "1\n", "1,000", "\u{FF11}", "\u{661}", "0x1F" }) |s|
        try h.expectFail(S, v.digits, s, "validation.digits", "must contain only ASCII digits");
}

test "lowercase and uppercase look at ASCII letters only" {
    try h.expectPass(S, v.lowercase, "\u{C9}mile"); // É is not inspected
    try h.expectPass(S, v.lowercase, "\u{41F}\u{420}\u{418}\u{412}\u{415}\u{422}");
    try h.expectFail(S, v.lowercase, "hello World", "validation.lowercase", "must be lowercase");
    try h.expectPass(S, v.lowercase, "abc-123_!");
    try h.expectPass(S, v.uppercase, "STRA\u{DF}E"); // ß is not inspected
    try h.expectFail(S, v.uppercase, "ABC\u{E9}x", "validation.uppercase", "must be uppercase");
    try h.expectPass(S, v.uppercase, "ABC-123");
    try h.expectPass(S, v.lowercase, "abc\xff\xc3\x89");
}

test "multibyte is the opposite of ascii on any bytes" {
    var prng = std.Random.DefaultPrng.init(0x5715_0001);
    const random = prng.random();
    var buf: [16]u8 = undefined;
    for (0..5_000) |_| {
        const n = random.uintLessThan(usize, buf.len + 1);
        random.bytes(buf[0..n]);
        for (buf[0..n]) |*c| {
            if (random.boolean()) c.* &= 0x7F;
        }
        try testing.expectEqual(!v.isAscii(buf[0..n]), v.isMultibyte(buf[0..n]));
    }
    try h.expectPass(S, v.multibyte, "caf\u{E9}");
    try h.expectFail(S, v.multibyte, "cafe", "validation.multibyte", "must contain at least one non-ASCII character");
}

/// The half-width class of validator.js, written apart from the library.
fn inHalfWidthSet(cp: u21) bool {
    return (cp >= 0x20 and cp <= 0x7E) or (cp >= 0xFF61 and cp <= 0xFFDC) or (cp >= 0xFFE8 and cp <= 0xFFEE);
}

test "the width rules over every scalar value: 226 are half-width, and one code point is never of variable width" {
    var half: usize = 0;
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        var one: [4]u8 = undefined;
        const s = encode(cp, &one);
        const in_set = inHalfWidthSet(cp);
        if (in_set) half += 1;
        try testing.expectEqual(in_set, v.isHalfWidth(s));
        try testing.expectEqual(!in_set, v.isFullWidth(s));
        try testing.expect(!v.isVariableWidth(s));
    }
    try testing.expectEqual(226, half);
    for ([_]S{ "", "\xff", "a\xff", "\xe3\x81" }) |s| {
        try testing.expect(!v.isFullWidth(s) and !v.isHalfWidth(s) and !v.isVariableWidth(s));
    }
}

test "the width rules: half-width katakana, hiragana, mixed values, and controls or Latin-1 as full-width" {
    try h.expectPass(S, v.halfWidth, "\u{FF71}\u{FF72}\u{FF73}");
    try h.expectFail(S, v.fullWidth, "\u{FF71}\u{FF72}\u{FF73}", "validation.full_width", "must contain at least one full-width character");
    try h.expectPass(S, v.fullWidth, "\u{3072}\u{3089}\u{304C}\u{306A}");
    try h.expectFail(S, v.halfWidth, "\u{3072}\u{3089}\u{304C}\u{306A}", "validation.half_width", "must contain at least one half-width character");
    try h.expectPass(S, v.variableWidth, "\u{3072}\u{3089}abc");
    try h.expectPass(S, v.variableWidth, "\u{FF71}\u{30A2}");
    try h.expectPass(S, v.variableWidth, "abc\n"); // LF is outside the half-width class
    try h.expectPass(S, v.variableWidth, "caf\u{E9}");
    try h.expectPass(S, v.fullWidth, "\u{43F}\u{440}\u{438}\u{432}\u{435}\u{442}");
    try h.expectFail(S, v.variableWidth, "\t\n", "validation.variable_width", "must contain both full-width and half-width characters");
    try h.expectFail(S, v.variableWidth, "abc", "validation.variable_width", "must contain both full-width and half-width characters");
    try h.expectFail(S, v.fullWidth, "", "validation.full_width", "must contain at least one full-width character");
    try h.expectFail(S, v.halfWidth, "", "validation.half_width", "must contain at least one half-width character");
    try h.expectFail(S, v.halfWidth.withMessage("x"), "\xffa", utf8_code, utf8_message);
}

test "withMessage on the rules without parameters: no placeholders, braces escape as usual, any language" {
    inline for (.{ v.utf8, v.notBlank, v.ascii, v.printableAscii, v.alphanumeric, v.alpha, v.digits, v.lowercase, v.uppercase, v.multibyte, v.fullWidth, v.halfWidth, v.variableWidth }) |rule| {
        const custom = rule.withMessage("{{literal}} and } stay");
        try testing.expectEqualStrings("{literal} and } stay", custom.message);
        try testing.expectEqualStrings(rule.code, custom.code);
    }
    const person_name = .{ v.notBlank.withMessage("заполните имя"), v.maxLength(64).withMessage("не длиннее {max} символов") };
    try h.expectFail(S, person_name, " ", "validation.not_blank", "заполните имя");
    try h.expectFail(S, person_name, repeat("я", 65), "validation.max_length", "не длиннее 64 символов");
    try h.expectFail(S, v.digits.withMessage("digits {{0-9}}"), "1a", "validation.digits", "digits {0-9}");
}

test "the rules without parameters take every kind of string: const or not, with a sentinel, over-aligned" {
    try expectEveryKindOfString(
        .{ v.utf8, v.notBlank, v.ascii, v.printableAscii, v.alphanumeric, v.alpha, v.lowercase, v.halfWidth },
        .{ v.digits, v.uppercase, v.multibyte, v.fullWidth, v.variableWidth },
    );
}

test "a rule without parameters on an optional field skips null and checks the value; on optional items through each" {
    try h.expectPass(??S, v.notBlank, null);
    try h.expectFail(??S, v.notBlank, " ", "validation.not_blank", "must not be blank");
    try h.expectPass(?S, v.fullWidth, null);
    try h.expectFail(?S, v.fullWidth, "\xff", utf8_code, utf8_message);
    const Codes = struct {
        codes: []const ?[]const u8,
        pub const field_rules = .{ .codes = v.each(.{ v.length(4, 4), v.digits }) };
    };
    try h.expectValid(&Codes{ .codes = &.{ "0123", null, "9999" } });
    try h.expectAt(&Codes{ .codes = &.{ "0123", null, "12a4" } }, "validation.digits", "must contain only ASCII digits", "codes[2]");
    try h.expectAll(&Codes{ .codes = &.{ "12", "abcd", "1234", "\xff\xff\xff\xff" } }, &.{
        .{ .code = "validation.length", .field = "codes[0]" },
        .{ .code = "validation.digits", .field = "codes[1]" },
        .{ .code = utf8_code, .field = "codes[3]" },
    });
}

test "random bytes into every predicate of a rule without parameters: no panic, and each rule agrees with its predicate" {
    var prng = std.Random.DefaultPrng.init(0x5715_0002);
    const random = prng.random();
    var buf: [24]u8 = undefined;
    for (0..20_000) |_| {
        const s = randomString(random, &buf);
        try testing.expectEqual(v.isUtf8(s), passes(v.utf8, s));
        try testing.expectEqual(v.isNotBlank(s), passes(v.notBlank, s));
        try testing.expectEqual(v.isAscii(s), passes(v.ascii, s));
        try testing.expectEqual(v.isPrintableAscii(s), passes(v.printableAscii, s));
        try testing.expectEqual(v.isAlphanumeric(s), passes(v.alphanumeric, s));
        try testing.expectEqual(v.isAlpha(s), passes(v.alpha, s));
        try testing.expectEqual(v.isDigits(s), passes(v.digits, s));
        try testing.expectEqual(v.isLowercase(s), passes(v.lowercase, s));
        try testing.expectEqual(v.isUppercase(s), passes(v.uppercase, s));
        try testing.expectEqual(v.isMultibyte(s), passes(v.multibyte, s));
        try testing.expectEqual(v.isFullWidth(s), passes(v.fullWidth, s));
        try testing.expectEqual(v.isHalfWidth(s), passes(v.halfWidth, s));
        try testing.expectEqual(v.isVariableWidth(s), passes(v.variableWidth, s));
    }
}
