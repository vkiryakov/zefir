//! The string length rules through `check` and `checkAll`: code points and
//! bytes, the utf8 precondition and its order, messages and placeholders,
//! every kind of string field, and random bytes into every rule.
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
