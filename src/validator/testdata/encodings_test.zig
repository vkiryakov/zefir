//! The encoding and other format rules through the public API: on every
//! kind of string field, optional and inside `each`, with their codes and
//! messages; every predicate on random bytes (no panic, and the rule always
//! agrees with its predicate); `isBase64` and `isBase64Url` against the
//! decoders of `std.base64`.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

/// A rule of this group with its predicate, code, default message, a value
/// it passes and one it fails.
const Case = struct {
    predicate_name: []const u8,
    rule: v.Rule,
    predicate: fn ([]const u8) bool,
    code: []const u8,
    message: []const u8,
    good: []const u8,
    bad: []const u8,
};

const cases = [_]Case{
    .{ .predicate_name = "isJson", .rule = v.json, .predicate = v.isJson, .code = "validation.json", .message = "must be a valid JSON object or array", .good = "{\"a\":[1,2]}", .bad = "{\"a\":[1,2]" },
    .{ .predicate_name = "isJwt", .rule = v.jwt, .predicate = v.isJwt, .code = "validation.jwt", .message = "must be a valid JWT", .good = "e30.e30.", .bad = "e30.e30" },
    .{ .predicate_name = "isBase32", .rule = v.base32, .predicate = v.isBase32, .code = "validation.base32", .message = "must be valid base32", .good = "MZXW6===", .bad = "MZXW6YTBOI" },
    .{ .predicate_name = "isBase58", .rule = v.base58, .predicate = v.isBase58, .code = "validation.base58", .message = "must be valid base58", .good = "3yZe7d", .bad = "3yZe7O" },
    .{ .predicate_name = "isBase64", .rule = v.base64, .predicate = v.isBase64, .code = "validation.base64", .message = "must be valid base64", .good = "Zm9vYg==", .bad = "Zm9vYh==" },
    .{ .predicate_name = "isDataUri", .rule = v.dataUri, .predicate = v.isDataUri, .code = "validation.data_uri", .message = "must be a valid data URI", .good = "data:text/plain;base64,SGVsbG8=", .bad = "data:text/plain;base64,SGVsbG8" },
    .{ .predicate_name = "isMagnetUri", .rule = v.magnetUri, .predicate = v.isMagnetUri, .code = "validation.magnet_uri", .message = "must be a valid magnet URI", .good = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a", .bad = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88" },
    .{ .predicate_name = "isMimeType", .rule = v.mimeType, .predicate = v.isMimeType, .code = "validation.mime_type", .message = "must be a valid MIME type", .good = "text/plain; charset=utf-8", .bad = "text/plain; charset=utf-8;" },
    .{ .predicate_name = "isLocale", .rule = v.locale, .predicate = v.isLocale, .code = "validation.locale", .message = "must be a valid locale", .good = "zh-Hant-TW", .bad = "zh_Hant_TW" },
    .{ .predicate_name = "isSemVer", .rule = v.semVer, .predicate = v.isSemVer, .code = "validation.sem_ver", .message = "must be a valid semantic version", .good = "1.0.0-rc.1", .bad = "1.0.0-rc.01" },
    .{ .predicate_name = "isHexColor", .rule = v.hexColor, .predicate = v.isHexColor, .code = "validation.hex_color", .message = "must be a valid hex color", .good = "#ff000080", .bad = "#ff00008" },
    .{ .predicate_name = "isRgbColor", .rule = v.rgbColor, .predicate = v.isRgbColor, .code = "validation.rgb_color", .message = "must be a valid RGB color", .good = "rgba(255, 0, 0, 0.5)", .bad = "rgba(255, 0, 0)" },
    .{ .predicate_name = "isHslColor", .rule = v.hslColor, .predicate = v.isHslColor, .code = "validation.hsl_color", .message = "must be a valid HSL color", .good = "hsl(120deg 100% 50%)", .bad = "hsl(120deg 100% 50)" },
    .{ .predicate_name = "isBase64Url", .rule = v.base64Url, .predicate = v.isBase64Url, .code = "validation.base64_url", .message = "must be valid base64url", .good = "Zm9vYg", .bad = "Zm9vYg==" },
};

test "every rule passes and fails a string with its code and default message" {
    inline for (cases) |c| {
        try h.expectRule(c.rule, c.code, c.message);
        try h.expectPass([]const u8, c.rule, c.good);
        try h.expectFail([]const u8, c.rule, c.bad, c.code, c.message);
        try testing.expect(c.predicate(c.good));
        try testing.expect(!c.predicate(c.bad));
    }
}

test "every rule takes []u8, sentinel-terminated and optional strings, and string items through each" {
    inline for (cases) |c| {
        var good = c.good[0..c.good.len].*;
        var bad = c.bad[0..c.bad.len].*;
        try h.expectPass([]u8, c.rule, &good);
        try h.expectFail([]u8, c.rule, &bad, c.code, c.message);
        try h.expectPass([:0]const u8, c.rule, c.good ++ "");
        try h.expectFail([:0]const u8, c.rule, c.bad ++ "", c.code, c.message);
        try h.expectPass(?[]const u8, c.rule, null);
        try h.expectPass(?[]const u8, c.rule, c.good);
        try h.expectFail(?[]const u8, c.rule, c.bad, c.code, c.message);
        try h.expectPass(??[]const u8, c.rule, null);
        const List = h.One([]const ?[]const u8, v.each(c.rule));
        try h.expectValid(&List{ .x = &.{ c.good, null } });
        try h.expectAt(&List{ .x = &.{ c.good, null, c.bad } }, c.code, c.message, "x[2]");
        try h.expectPass([]const u8, c.rule.withMessage("another message"), c.good);
        try h.expectFail([]const u8, c.rule.withMessage("another message"), c.bad, c.code, "another message");
    }
}

test "the empty string passes the pure encodings: pair them with notEmpty to require content" {
    inline for (.{ v.base32, v.base58, v.base64, v.base64Url }) |rule| {
        try h.expectPass([]const u8, rule, "");
        try h.expectFail([]const u8, .{ v.notEmpty, rule }, "", "validation.not_empty", "must not be empty");
    }
}

test "the empty string fails every other rule of this group with the rule's own code" {
    inline for (cases) |c| {
        if (!c.predicate("")) try h.expectFail([]const u8, c.rule, "", c.code, c.message);
    }
}

/// Bytes that the formats of this group give a meaning to, so that random
/// strings reach past the first byte of each parser.
const alphabet = "AZaz09+/-_=.:;,%#@!$&'()*?[]{}\"\\ \t\r\n\x0b\x0c\x00\x7f\x80\xc3\xa9\xff2367LOIl" ++
    "datimgnetxrbhsuvwlfopc";

/// A random string: from `alphabet` mostly, any byte sometimes, up to 96 bytes.
fn randomString(random: std.Random, buf: *[96]u8) []u8 {
    const len = random.uintLessThan(usize, buf.len + 1);
    for (buf[0..len]) |*c| {
        c.* = if (random.uintLessThan(u8, 8) == 0) random.int(u8) else alphabet[random.uintLessThan(usize, alphabet.len)];
    }
    return buf[0..len];
}

/// Whether `v.check` finds no violation of `rule` in a string field holding `s`.
fn rulePasses(comptime rule: v.Rule, s: []const u8) bool {
    var path_buf: [8]u8 = undefined;
    return v.check(&h.One([]const u8, rule){ .x = s }, &path_buf) == null;
}

test "every predicate takes any bytes without a panic, and its rule agrees with it" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_e1c0);
    const random = prng.random();
    var buf: [96]u8 = undefined;
    for (0..20_000) |_| {
        const s = randomString(random, &buf);
        inline for (cases) |c| {
            if (rulePasses(c.rule, s) != c.predicate(s)) {
                std.debug.print("{s} and its rule disagree on \"{f}\"\n", .{ c.predicate_name, std.zig.fmtString(s) });
                return error.RuleDisagrees;
            }
        }
    }
}

test "json takes nested documents of random brackets without a panic and never accepts more than 64 levels" {
    var prng: std.Random.DefaultPrng = .init(0x7a5_0b1e);
    const random = prng.random();
    const tokens = "[]{}[]{}\":,1 ";
    var buf: [200]u8 = undefined;
    for (0..20_000) |_| {
        const len = random.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*c| c.* = tokens[random.uintLessThan(usize, tokens.len)];
        const s = buf[0..len];
        if (!v.isJson(s)) continue;
        // An accepted document never nests deeper than the limit.
        var depth: usize = 0;
        var deepest: usize = 0;
        var in_string = false;
        for (s) |c| switch (c) {
            '"' => in_string = !in_string,
            '[', '{' => if (!in_string) {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            ']', '}' => if (!in_string) {
                depth -= 1;
            },
            else => {},
        };
        try testing.expect(deepest >= 1 and deepest <= v.max_json_depth);
    }
}

/// Whether the std decoder `codec` decodes `s`.
fn stdDecodes(codec: std.base64.Codecs, s: []const u8) bool {
    var out: [96]u8 = undefined;
    const size = codec.Decoder.calcSizeForSlice(s) catch return false;
    codec.Decoder.decode(out[0..size], s) catch return false;
    return true;
}

test "isBase64 and isBase64Url accept exactly what the std.base64 decoders decode" {
    var prng: std.Random.DefaultPrng = .init(0xba5e_64);
    const random = prng.random();
    const symbols = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_=";
    var buf: [24]u8 = undefined;
    for (0..50_000) |_| {
        const len = random.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*c| c.* = symbols[random.uintLessThan(usize, symbols.len)];
        // Padding at the end half of the time, where the decoders differ most.
        if (len >= 2 and random.boolean()) buf[len - 1] = '=';
        if (len >= 3 and random.uintLessThan(u8, 4) == 0) buf[len - 2] = '=';
        const s = buf[0..len];
        if (v.isBase64(s) != stdDecodes(std.base64.standard, s)) {
            std.debug.print("isBase64 and std.base64.standard disagree on \"{s}\"\n", .{s});
            return error.DecoderDisagrees;
        }
        if (v.isBase64Url(s) != stdDecodes(std.base64.url_safe_no_pad, s)) {
            std.debug.print("isBase64Url and std.base64.url_safe_no_pad disagree on \"{s}\"\n", .{s});
            return error.DecoderDisagrees;
        }
    }
}
