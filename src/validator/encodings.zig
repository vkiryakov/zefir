//! Encoding and other format rules for string fields, each with its
//! predicate: `v.base64` and `v.isBase64(s)`. Every rule here is a value
//! without parameters, placeholders or precondition, and passes exactly when
//! its predicate returns true. Nothing is trimmed and nothing is decoded into
//! memory; a byte of 0x80 or above fails under the rule's own code, so
//! invalid UTF-8 needs no rule of its own. The predicates take any bytes,
//! never allocate, never backtrack and run in time linear in the input.
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;

// ------------------------------------------------------------------ base64, base64Url

/// RFC 4648 §4 base64 with padding, in its canonical form: the length is a
/// multiple of 4, the data is `A-Z a-z 0-9 + /`, one or two `=` may end it,
/// and the bits the padding leaves unused are zero (RFC 4648 §3.5), so `Zg==`
/// passes and `Zh==` fails. It accepts exactly what
/// `std.base64.standard.Decoder` decodes: no line breaks, no whitespace, no
/// URL-safe alphabet, no missing padding. `""` passes (it encodes no bytes):
/// pair it with `v.notEmpty` to require content.
pub const base64: Rule = core.predicateRule(.base64, "must be valid base64", isBase64);

/// Whether `v.base64` passes `s`.
pub fn isBase64(s: []const u8) bool {
    if (s.len % 4 != 0) return false;
    var pad: usize = 0;
    if (s.len > 0 and s[s.len - 1] == '=') {
        pad = 1;
        // s.len is at least 4 here.
        if (s[s.len - 2] == '=') pad = 2;
    }
    var last: u6 = 0;
    for (s[0 .. s.len - pad]) |c| last = standardDigit(c) orelse return false;
    return switch (pad) {
        0 => true,
        // 3 symbols carry 18 bits for 16 data bits; 2 symbols 12 bits for 8.
        1 => last & 0b11 == 0,
        else => last & 0b1111 == 0,
    };
}

/// RFC 4648 §5 base64url without padding, as JWT segments use it (RFC 7515
/// §2), in its canonical form: the data is `A-Z a-z 0-9 - _`, `=` never
/// appears, the length is not 1 more than a multiple of 4, and the unused
/// bits of the last symbol are zero. It accepts exactly what
/// `std.base64.url_safe_no_pad.Decoder` decodes. `""` passes.
pub const base64Url: Rule = core.predicateRule(.base64_url, "must be valid base64url", isBase64Url);

/// Whether `v.base64Url` passes `s`.
pub fn isBase64Url(s: []const u8) bool {
    var last: u6 = 0;
    for (s) |c| last = urlSafeDigit(c) orelse return false;
    return switch (s.len % 4) {
        0 => true,
        // One symbol holds 6 bits: no whole byte.
        1 => false,
        2 => last & 0b1111 == 0,
        else => last & 0b11 == 0,
    };
}

/// The value of a symbol of the standard alphabet (RFC 4648 table 1).
fn standardDigit(c: u8) ?u6 {
    return switch (c) {
        '+' => 62,
        '/' => 63,
        else => alphanumericDigit(c),
    };
}

/// The value of a symbol of the URL and filename safe alphabet (RFC 4648
/// table 2).
fn urlSafeDigit(c: u8) ?u6 {
    return switch (c) {
        '-' => 62,
        '_' => 63,
        else => alphanumericDigit(c),
    };
}

/// The value of a letter or digit, shared by both base64 alphabets.
fn alphanumericDigit(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        else => null,
    };
}

// ------------------------------------------------------------------ base32, base58

/// RFC 4648 §6 base32 with padding, in its canonical form: the length is a
/// multiple of 8, the data is uppercase `A-Z 2-7`, it ends with 0, 1, 3, 4 or
/// 6 `=` (the only counts an encoder writes), and the bits the padding
/// leaves unused are zero (RFC 4648 §3.5). Not Crockford's base32 and not
/// the unpadded variant. `""` passes.
pub const base32: Rule = core.predicateRule(.base32, "must be valid base32", isBase32);

/// Whether `v.base32` passes `s`.
pub fn isBase32(s: []const u8) bool {
    if (s.len % 8 != 0) return false;
    var pad: usize = 0;
    while (pad < s.len and s[s.len - 1 - pad] == '=') pad += 1;
    // The unused low bits of the last data symbol: 7 symbols carry 35 bits
    // for 32 data bits, 5 symbols 25 for 24, 4 symbols 20 for 16, 2 symbols
    // 10 for 8.
    const unused: u3 = switch (pad) {
        0 => 0,
        1 => 3,
        3 => 1,
        4 => 4,
        6 => 2,
        else => return false,
    };
    var last: u5 = 0;
    for (s[0 .. s.len - pad]) |c| {
        last = switch (c) {
            'A'...'Z' => @intCast(c - 'A'),
            '2'...'7' => @intCast(c - '2' + 26),
            else => return false,
        };
    }
    const mask: u5 = @intCast((@as(u8, 1) << unused) - 1);
    return last & mask == 0;
}

/// Bitcoin's base58 alphabet (draft-msporny-base58-03): `1-9 A-H J-N P-Z
/// a-k m-z`, without `0`, `O`, `I` and `l`. Every string over the alphabet
/// is the canonical encoding of some bytes (a leading `1` is a zero byte), so
/// only the alphabet is checked: no Base58Check checksum, no length (use
/// `v.btcAddress` for Bitcoin addresses). `""` passes.
pub const base58: Rule = core.predicateRule(.base58, "must be valid base58", isBase58);

/// Whether `v.base58` passes `s`.
pub fn isBase58(s: []const u8) bool {
    for (s) |c| switch (c) {
        '1'...'9', 'A'...'H', 'J'...'N', 'P'...'Z', 'a'...'k', 'm'...'z' => {},
        else => return false,
    };
    return true;
}

// ------------------------------------------------------------------ tests

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// The declaration error of `rule` on a field of type `T`, or null.
fn fieldText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return core.stringProblem(&rule, T, test_where, null);
}

test "the encoding rules are values with their documented codes and messages, without parameters or precondition" {
    const t = std.testing;
    const rules = .{ base64, base64Url, base32, base58 };
    const kinds = [_]core.Kind{ .base64, .base64_url, .base32, .base58 };
    const codes = [_][]const u8{ "validation.base64", "validation.base64_url", "validation.base32", "validation.base58" };
    const messages = [_][]const u8{ "must be valid base64", "must be valid base64url", "must be valid base32", "must be valid base58" };
    inline for (rules, kinds, codes, messages) |rule, kind, code, message| {
        try t.expectEqual(kind, rule.kind);
        try t.expectEqualStrings(code, rule.code);
        try t.expectEqualStrings(message, rule.message);
        try t.expectEqual(null, rule.args);
        try t.expectEqual(0, rule.params.len);
        try t.expectEqual(null, rule.precondition);
    }
}

test "a rule of this file takes strings; [N]u8 and lists of strings get their hints, other types none" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "base64 expects a string, field is u32", comptime fieldText(base64, u32).?);
    try expect(head ++ "base64_url expects a string, field is [64]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(base64Url, [64]u8).?);
    try expect(head ++ "base32 expects a string, field is [4:0]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(base32, [4:0]u8).?);
    try expect(head ++ "base58 expects a string, field is []const []const u8; use v.each(v.base58)", comptime fieldText(base58, []const []const u8).?);
    try expect(head ++ "base64 expects a string, field is [2]?[]const u8; use v.each(v.base64)", comptime fieldText(base64, [2]?[]const u8).?);
    try expect(head ++ "base64 expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fieldText(base64, []volatile u8).?);
    try expect(head ++ "base64 expects a string, field is []const u32", comptime fieldText(base64, []const u32).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expectEqual(null, comptime fieldText(base64, T));
    }
}

test "base64 accepts canonical padded RFC 4648 base64 and the empty string" {
    const t = std.testing;
    for ([_][]const u8{ "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy", "AA==", "+/+/", "SGVsbG8sIHdvcmxkIQ==" }) |s| {
        t.expect(isBase64(s)) catch |err| {
            std.debug.print("isBase64 rejected \"{s}\"\n", .{s});
            return err;
        };
    }
    // Wrong length, missing or misplaced padding, non-zero pad bits, other
    // alphabets, whitespace and line breaks.
    for ([_][]const u8{ "Zg", "Zg=", "Zh==", "Zm9=", "AB==", "=Zg=", "Z===", "====", "Zg==Zg==", "-_-_", "Zm9v\nYmFy", " Zm9v", "Zm9v ", "Zm 9v", "Zm9v\x00", "Zm9\xff" }) |s| {
        t.expect(!isBase64(s)) catch |err| {
            std.debug.print("isBase64 accepted \"{s}\"\n", .{s});
            return err;
        };
    }
    try expectOutcome(.pass, base64, @as([]const u8, "Zm9v"));
    try expectOutcome(.fail, base64, @as([:0]const u8, "Zh=="));
}

test "base64Url accepts canonical unpadded base64url and the empty string" {
    const t = std.testing;
    for ([_][]const u8{ "", "Zg", "Zm8", "Zm9v", "-_-_", "eyJhbGciOiJIUzI1NiJ9", "AA" }) |s| try t.expect(isBase64Url(s));
    for ([_][]const u8{ "Z", "Zm9vY", "Zh", "Zm9", "Zg==", "Zm8=", "+/+/", "Zm9v\n", " Zg" }) |s| try t.expect(!isBase64Url(s));
    try expectOutcome(.fail, base64Url, @as([]const u8, "Zg=="));
}

test "base32 accepts canonical padded uppercase RFC 4648 base32 and the empty string" {
    const t = std.testing;
    // RFC 4648 §10 test vectors.
    for ([_][]const u8{ "", "MY======", "MZXQ====", "MZXW6===", "MZXW6YQ=", "MZXW6YTB", "MZXW6YTBOI======" }) |s| {
        t.expect(isBase32(s)) catch |err| {
            std.debug.print("isBase32 rejected \"{s}\"\n", .{s});
            return err;
        };
    }
    // Lowercase, no padding, a length that is not a multiple of 8, pad
    // counts 2, 7 and 8, non-zero unused bits (`MZ======`, `MZXW6YTBOJ======`),
    // padding inside the data, digits outside 2-7.
    for ([_][]const u8{ "my======", "MZXW6YTBOI", "MY=====", "MZXW6Y==", "A=======", "========", "MZ======", "MZXW6YTBOJ======", "MZXQ=A==", "MZXW6YT1", "MZXW6YT0", "MZXW6YT8" }) |s| {
        t.expect(!isBase32(s)) catch |err| {
            std.debug.print("isBase32 accepted \"{s}\"\n", .{s});
            return err;
        };
    }
}

test "base58 accepts the Bitcoin alphabet only, without 0, O, I and l" {
    const t = std.testing;
    for ([_][]const u8{ "", "1", "111", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "z", "9" }) |s| try t.expect(isBase58(s));
    for ([_][]const u8{ "0", "O", "I", "l", "1 1", "+", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa\n", "\xc3\xa9" }) |s| try t.expect(!isBase58(s));
}
