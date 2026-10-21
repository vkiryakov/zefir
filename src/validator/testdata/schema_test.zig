//! `v.schemaOf`: every kind of rule on each field type it takes, as its
//! accuracy, its keywords written as one JSON object and its note; `?T`,
//! `each`, transforms and the JSON text of characters outside ASCII.
const std = @import("std");
const v = @import("validator");
const testing = std.testing;

const Role = enum { admin, user, guest };

/// An item of a list, whose `id` is called `itemId` outside.
const Item = struct {
    id: u32,
    pub const field_rules = .{ .id = v.rename("itemId") };
};

fn isEven(x: u32) bool {
    return x % 2 == 0;
}

fn normalize(_: std.mem.Allocator, s: []const u8) []const u8 {
    return s;
}

/// The keywords of `s` as one JSON object, in their order: `{"minLength":1}`.
fn objectText(comptime s: v.RuleSchema) []const u8 {
    var out: []const u8 = "{";
    for (s.keywords, 0..) |k, i| out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ k.name ++ "\":" ++ k.value;
    return out ++ "}";
}

/// `v.schemaOf(element, T)` has this accuracy, these keywords and this note,
/// and no items.
fn expectSchema(comptime element: anytype, comptime T: type, accuracy: v.RuleSchema.Accuracy, keywords: []const u8, note: ?[]const u8) !void {
    const s = comptime v.schemaOf(element, T);
    try testing.expectEqualStrings(keywords, comptime objectText(s));
    try testing.expectEqual(accuracy, s.accuracy);
    try expectNote(note, s.note);
    try testing.expectEqual(0, s.items.len);
}

fn expectNote(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |e| {
        try testing.expectEqualStrings(e, actual orelse return error.NoNote);
    } else if (actual) |a| {
        std.debug.print("unexpected note: {s}\n", .{a});
        return error.UnexpectedNote;
    }
}

/// An exact schema with these keywords and no note.
fn expectExact(comptime element: anytype, comptime T: type, keywords: []const u8) !void {
    try expectSchema(element, T, .exact, keywords, null);
}

test "common rules: const, enum and not of the parameter, tags by name; lengths or items for empty" {
    try expectExact(v.equals(5), u32, "{\"const\":5}");
    try expectExact(v.equals(-2.5), f64, "{\"const\":-2.5}");
    try expectExact(v.equals(@as(f32, 0.1)), f32, "{\"const\":0.1}");
    try expectExact(v.equals(true), bool, "{\"const\":true}");
    try expectExact(v.equals(.admin), Role, "{\"const\":\"admin\"}");
    try expectExact(v.equals("a\"b"), []const u8, "{\"const\":\"a\\\"b\"}");
    try expectExact(v.notEquals(0), i32, "{\"not\":{\"const\":0}}");
    try expectExact(v.notEquals(false), bool, "{\"not\":{\"const\":false}}");
    try expectExact(v.notEquals(.guest), Role, "{\"not\":{\"const\":\"guest\"}}");
    try expectExact(v.notEquals("x"), []const u8, "{\"not\":{\"const\":\"x\"}}");
    try expectExact(v.oneOf(.{ "a", "" }), []const u8, "{\"enum\":[\"a\",\"\"]}");
    try expectExact(v.oneOf(.{ .admin, .user }), Role, "{\"enum\":[\"admin\",\"user\"]}");
    try expectExact(v.oneOf(.{ 1, 2, 3 }), u8, "{\"enum\":[1,2,3]}");
    try expectExact(v.noneOf(.{"root"}), []const u8, "{\"not\":{\"enum\":[\"root\"]}}");
    try expectExact(v.noneOf(.{.guest}), Role, "{\"not\":{\"enum\":[\"guest\"]}}");
    try expectExact(v.noneOf(.{ -1, 0 }), i64, "{\"not\":{\"enum\":[-1,0]}}");
    try expectExact(v.empty, []const u8, "{\"maxLength\":0}");
    try expectExact(v.empty, []const u32, "{\"maxItems\":0}");
    try expectExact(v.notEmpty, [:0]const u8, "{\"minLength\":1}");
    try expectExact(v.notEmpty, []const []const u8, "{\"minItems\":1}");
}

test "number rules: bounds as written, positive by signedness, multipleOf; finite has nothing to say" {
    try expectExact(v.min(18), u8, "{\"minimum\":18}");
    try expectExact(v.min(0.5), f64, "{\"minimum\":0.5}");
    try expectExact(v.min(-1), f32, "{\"minimum\":-1}");
    try expectExact(v.max(100), u32, "{\"maximum\":100}");
    try expectExact(v.max(1e-7), f64, "{\"maximum\":1e-7}");
    try expectExact(v.range(1, 100), u16, "{\"minimum\":1,\"maximum\":100}");
    try expectExact(v.range(@as(f32, -0.1), 0.5), f32, "{\"minimum\":-0.1,\"maximum\":0.5}");
    try expectExact(v.range(std.math.minInt(i128) + 1, 0), i128, "{\"minimum\":-170141183460469231731687303715884105727,\"maximum\":0}");
    try expectExact(v.positive, u32, "{\"minimum\":1}");
    try expectExact(v.positive, u1, "{\"minimum\":1}");
    try expectExact(v.positive, i32, "{\"exclusiveMinimum\":0}");
    try expectExact(v.positive, f64, "{\"exclusiveMinimum\":0}");
    try expectExact(v.nonNegative, i32, "{\"minimum\":0}");
    try expectExact(v.nonNegative, f32, "{\"minimum\":0}");
    try expectExact(v.negative, i64, "{\"exclusiveMaximum\":0}");
    try expectExact(v.negative, f64, "{\"exclusiveMaximum\":0}");
    try expectExact(v.nonPositive, i8, "{\"maximum\":0}");
    try expectExact(v.nonPositive, f16, "{\"maximum\":0}");
    try expectExact(v.divisibleBy(5), u32, "{\"multipleOf\":5}");
    try expectExact(v.divisibleBy(5), f64, "{\"multipleOf\":5}");
    try expectExact(v.finite, f64, "{}");
}

test "length rules count code points as JSON Schema does; byte rules are approximate" {
    try expectExact(v.minLength(3), []const u8, "{\"minLength\":3}");
    try expectExact(v.maxLength(200), []const u8, "{\"maxLength\":200}");
    try expectExact(v.length(2, 5), []const u8, "{\"minLength\":2,\"maxLength\":5}");
    try expectExact(v.length(5, 5), []u8, "{\"minLength\":5,\"maxLength\":5}");
    try expectSchema(v.minBytes(5), []const u8, .approximate, "{\"minLength\":2}", "Checked by the server: at least 5 bytes in UTF-8.");
    try expectSchema(v.minBytes(1), []const u8, .approximate, "{\"minLength\":1}", "Checked by the server: at least 1 byte in UTF-8.");
    try expectSchema(v.maxBytes(64), []const u8, .approximate, "{\"maxLength\":64}", "Checked by the server: at most 64 bytes in UTF-8.");
    try expectExact(v.utf8, []const u8, "{}");
}

test "character rules are patterns, with the characters outside printable ASCII escaped as JSON escapes them" {
    try expectExact(v.notBlank, []const u8,
        \\{"pattern":"[^\t\n\u000b\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]"}
    );
    try expectExact(v.ascii, []const u8,
        \\{"pattern":"^[\u0000-\u007f]*$"}
    );
    try expectExact(v.printableAscii, []const u8,
        \\{"pattern":"^[ -~]*$"}
    );
    try expectExact(v.alphanumeric, []const u8,
        \\{"pattern":"^[0-9A-Za-z]*$"}
    );
    try expectExact(v.alpha, []const u8,
        \\{"pattern":"^[A-Za-z]*$"}
    );
    try expectExact(v.digits, []const u8,
        \\{"pattern":"^[0-9]*$"}
    );
    try expectExact(v.lowercase, []const u8,
        \\{"pattern":"^[^A-Z]*$"}
    );
    try expectExact(v.uppercase, []const u8,
        \\{"pattern":"^[^a-z]*$"}
    );
    try expectExact(v.multibyte, []const u8,
        \\{"pattern":"[^\u0000-\u007f]"}
    );
    try expectExact(v.fullWidth, []const u8,
        \\{"pattern":"[^ -~\uff61-\uffdc\uffe8-\uffee]"}
    );
    try expectExact(v.halfWidth, []const u8,
        \\{"pattern":"[ -~\uff61-\uffdc\uffe8-\uffee]"}
    );
    try expectExact(v.variableWidth, []const u8,
        \\{"allOf":[{"pattern":"[^ -~\uff61-\uffdc\uffe8-\uffee]"},{"pattern":"[ -~\uff61-\uffdc\uffe8-\uffee]"}]}
    );
}

test "contains and notContains search the seed literally; notContains carries the type inside not" {
    try expectExact(v.contains("@"), []const u8,
        \\{"pattern":"@"}
    );
    try expectExact(v.contains("a.b(c)[d]{e}|f^g$h*i+j?k\\"), []const u8,
        \\{"pattern":"a\\.b\\(c\\)\\[d\\]\\{e\\}\\|f\\^g\\$h\\*i\\+j\\?k\\\\"}
    );
    try expectExact(v.contains("é-/\"x"), []const u8,
        \\{"pattern":"\u00e9-/\"x"}
    );
    try expectExact(v.notContains(" "), []const u8,
        \\{"not":{"type":"string","pattern":" "}}
    );
    try expectExact(v.notContains("{x}"), []const u8,
        \\{"not":{"type":"string","pattern":"\\{x\\}"}}
    );
}

test "strongPassword: minLength and one pattern per class with a minimum; a count above 1000 is approximate" {
    try expectExact(v.strongPassword(.{}), []const u8,
        \\{"minLength":8,"allOf":[{"pattern":"^(?:[^a-z]*[a-z]){1}"},{"pattern":"^(?:[^A-Z]*[A-Z]){1}"},{"pattern":"^(?:[^0-9]*[0-9]){1}"},{"pattern":"^(?:[^ -/:-@\\[-`{-~\u00a3]*[ -/:-@\\[-`{-~\u00a3]){1}"}]}
    );
    try expectExact(v.strongPassword(.{ .min_length = 12, .min_lowercase = 0, .min_uppercase = 2, .min_numbers = 0, .min_symbols = 0 }), []const u8,
        \\{"minLength":12,"allOf":[{"pattern":"^(?:[^A-Z]*[A-Z]){2}"}]}
    );
    try expectExact(v.strongPassword(.{ .min_length = 10, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }), []const u8,
        \\{"minLength":10}
    );
    try expectSchema(v.strongPassword(.{ .min_length = 1001, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 1001, .min_symbols = 0 }), []const u8, .approximate,
        \\{"minLength":1001,"allOf":[{"pattern":"^(?:[^0-9]*[0-9]){1000}"}]}
    , "Checked by the server: every minimum of strongPassword, of which a pattern counts at most 1000.");
}

test "number and boolean formats in strings are exact patterns; booleanString is an enum" {
    try expectExact(v.numberString, []const u8,
        \\{"pattern":"^[+-]?(?:[0-9]+|[0-9]*\\.[0-9]+)$"}
    );
    try expectExact(v.decimal(.{}), []const u8,
        \\{"pattern":"^[+-]?(?:[0-9]+|[0-9]*\\.[0-9]{1,})$"}
    );
    try expectExact(v.decimal(.{ .min_decimal_digits = 1, .max_decimal_digits = 3 }), []const u8,
        \\{"pattern":"^[+-]?(?:[0-9]+|[0-9]*\\.[0-9]{1,3})$"}
    );
    try expectExact(v.decimal(.{ .force_decimal = true, .min_decimal_digits = 2, .max_decimal_digits = 2 }), []const u8,
        \\{"pattern":"^[+-]?[0-9]*\\.[0-9]{2}$"}
    );
    try expectSchema(v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 1500 }), []const u8, .approximate,
        \\{"pattern":"^[+-]?(?:[0-9]+|[0-9]*\\.[0-9]{2,})$"}
    , "Checked by the server: the number of digits after the point.");
    try expectExact(v.booleanString, []const u8,
        \\{"enum":["true","false","1","0"]}
    );
    try expectExact(v.hexadecimal, []const u8,
        \\{"pattern":"^(?:0[xXhH])?[0-9A-Fa-f]+$"}
    );
    try expectExact(v.octal, []const u8,
        \\{"pattern":"^(?:0[oO])?[0-7]+$"}
    );
    try expectExact(v.port, []const u8,
        \\{"pattern":"^(?:0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"}
    );
}

test "coordinates: a pattern on strings, bounds on floats" {
    try expectExact(v.latitude, []const u8,
        \\{"pattern":"^[+-]?(?:(?:[0-9]|[1-8][0-9])(?:\\.[0-9]+)?|90(?:\\.0+)?)$"}
    );
    try expectExact(v.latitude, f64, "{\"minimum\":-90,\"maximum\":90}");
    try expectExact(v.longitude, []const u8,
        \\{"pattern":"^[+-]?(?:(?:[0-9]{1,2}|1[0-7][0-9])(?:\\.[0-9]+)?|180(?:\\.0+)?)$"}
    );
    try expectExact(v.longitude, f32, "{\"minimum\":-180,\"maximum\":180}");
    try expectExact(v.latLong, []const u8,
        \\{"pattern":"^(?:[+-]?(?:(?:[0-9]|[1-8][0-9])(?:\\.[0-9]+)?|90(?:\\.0+)?), ?[+-]?(?:(?:[0-9]{1,2}|1[0-7][0-9])(?:\\.[0-9]+)?|180(?:\\.0+)?)|\\([+-]?(?:(?:[0-9]|[1-8][0-9])(?:\\.[0-9]+)?|90(?:\\.0+)?), ?[+-]?(?:(?:[0-9]{1,2}|1[0-7][0-9])(?:\\.[0-9]+)?|180(?:\\.0+)?)\\))$"}
    );
}

test "network formats: format with an exact or a short pattern" {
    try expectSchema(v.email, []const u8, .approximate,
        \\{"format":"email","maxLength":254,"pattern":"^[0-9A-Za-z!#$%&'*+/=?^_`{|}~-]+(?:\\.[0-9A-Za-z!#$%&'*+/=?^_`{|}~-]+)*@(?:[0-9A-Za-z](?:[0-9A-Za-z-]{0,61}[0-9A-Za-z])?\\.)+(?:[A-Za-z]{2,63}|[Xx][Nn][0-9A-Za-z-]{1,60}[0-9A-Za-z])$"}
    , "Checked by the server: a valid email address.");
    try expectSchema(v.httpUrl, []const u8, .approximate,
        \\{"format":"uri","pattern":"^[Hh][Tt][Tt][Pp][Ss]?://"}
    , "Checked by the server: a valid HTTP or HTTPS URL.");
    try expectExact(v.ipv4, []const u8,
        \\{"format":"ipv4","pattern":"^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"}
    );
    try expectSchema(v.ipv6, []const u8, .approximate,
        \\{"format":"ipv6","pattern":"^[0-9A-Fa-f:.]{2,45}$"}
    , "Checked by the server: a valid IPv6 address.");
    try expectSchema(v.ip, []const u8, .approximate,
        \\{"anyOf":[{"format":"ipv4","pattern":"^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"},{"format":"ipv6","pattern":"^[0-9A-Fa-f:.]{2,45}$"}]}
    , "Checked by the server: a valid IPv4 or IPv6 address.");
}

test "fqdn: hostname, the length and the labels by its options; a last label of digits is refused by not" {
    try expectExact(v.fqdn(.{}), []const u8,
        \\{"format":"hostname","maxLength":253,"pattern":"^(?:[0-9A-Za-z](?:[0-9A-Za-z-]{0,61}[0-9A-Za-z])?\\.)+(?:[A-Za-z]{2,63}|[Xx][Nn][0-9A-Za-z-]{1,60}[0-9A-Za-z])$"}
    );
    try expectExact(v.fqdn(.{ .require_tld = false }), []const u8,
        \\{"format":"hostname","maxLength":253,"pattern":"^(?:[0-9A-Za-z](?:[0-9A-Za-z-]{0,61}[0-9A-Za-z])?\\.)*[0-9A-Za-z](?:[0-9A-Za-z-]{0,61}[0-9A-Za-z])?$","not":{"type":"string","pattern":"(?:^|\\.)[0-9]+\\.?$"}}
    );
    try expectExact(v.fqdn(.{ .allow_underscores = true, .allow_trailing_dot = true, .allow_wildcard = true }), []const u8,
        \\{"anyOf":[{"maxLength":253},{"maxLength":254,"pattern":"\\.$"}],"pattern":"^(?:\\*\\.)?(?:[0-9A-Za-z_](?:[0-9A-Za-z_-]{0,61}[0-9A-Za-z_])?\\.)+(?:[A-Za-z]{2,63}|[Xx][Nn][0-9A-Za-z-]{1,60}[0-9A-Za-z])\\.?$"}
    );
}

test "macAddress: each size and form its options take" {
    try expectExact(v.macAddress(.{}), []const u8,
        \\{"pattern":"^(?:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?: [0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{4}(?:\\.[0-9A-Fa-f]{4}){2}|[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{2}(?: [0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{4}(?:\\.[0-9A-Fa-f]{4}){3})$"}
    );
    try expectExact(v.macAddress(.{ .eui = .eui48, .format = .bare }), []const u8,
        \\{"pattern":"^(?:[0-9A-Fa-f]{12})$"}
    );
    try expectExact(v.macAddress(.{ .eui = .eui64 }), []const u8,
        \\{"pattern":"^(?:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{2}(?: [0-9A-Fa-f]{2}){7}|[0-9A-Fa-f]{4}(?:\\.[0-9A-Fa-f]{4}){3})$"}
    );
}

test "encodings: the base encodings exactly, with their unused bits; the long grammars approximately" {
    try expectSchema(v.json, []const u8, .approximate,
        \\{"contentMediaType":"application/json","pattern":"^[\t\n\r ]*[\\[{]"}
    , "Checked by the server: a JSON object or array.");
    try expectSchema(v.jwt, []const u8, .approximate,
        \\{"pattern":"^[0-9A-Za-z_-]+\\.[0-9A-Za-z_-]+\\.[0-9A-Za-z_-]*$"}
    , "Checked by the server: a JWT of three base64url segments.");
    try expectExact(v.base32, []const u8,
        \\{"pattern":"^(?:[A-Z2-7]{8})*(?:[A-Z2-7][AEIMQUY4]======|[A-Z2-7]{3}[AQ]====|[A-Z2-7]{4}[ACEGIKMOQSUWY246]===|[A-Z2-7]{6}[AIQY]=)?$"}
    );
    try expectExact(v.base58, []const u8,
        \\{"pattern":"^[1-9A-HJ-NP-Za-km-z]*$"}
    );
    try expectExact(v.base64, []const u8,
        \\{"contentEncoding":"base64","pattern":"^(?:[0-9A-Za-z+/]{4})*(?:[0-9A-Za-z+/][AQgw]==|[0-9A-Za-z+/]{2}[AEIMQUYcgkosw048]=)?$"}
    );
    try expectExact(v.base64Url, []const u8,
        \\{"contentEncoding":"base64url","pattern":"^(?:[0-9A-Za-z_-]{4})*(?:[0-9A-Za-z_-][AQgw]|[0-9A-Za-z_-]{2}[AEIMQUYcgkosw048])?$"}
    );
    try expectSchema(v.dataUri, []const u8, .approximate,
        \\{"format":"uri","pattern":"^data:"}
    , "Checked by the server: a valid data URI.");
    try expectSchema(v.magnetUri, []const u8, .approximate,
        \\{"format":"uri","pattern":"^magnet:\\?"}
    , "Checked by the server: a valid magnet URI.");
    try expectSchema(v.mimeType, []const u8, .approximate,
        \\{"format":"media-range","pattern":"^[A-Za-z]+/[0-9A-Za-z]"}
    , "Checked by the server: a valid MIME type.");
    try expectSchema(v.locale, []const u8, .approximate,
        \\{"format":"language","pattern":"^[A-Za-z]{1,8}(?:-[0-9A-Za-z]{1,8})*$"}
    , "Checked by the server: a well-formed BCP 47 language tag.");
    try expectExact(v.semVer, []const u8,
        \\{"pattern":"^(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$"}
    );
    try expectExact(v.hexColor, []const u8,
        \\{"pattern":"^#(?:[0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"}
    );
    try expectSchema(v.rgbColor, []const u8, .approximate,
        \\{"pattern":"^rgba?\\([^)]*\\)$"}
    , "Checked by the server: a valid CSS rgb() or rgba() color.");
    try expectSchema(v.hslColor, []const u8, .approximate,
        \\{"pattern":"^[Hh][Ss][Ll][Aa]?\\([^)]*\\)$"}
    , "Checked by the server: a valid CSS hsl() or hsla() color.");
}

test "identifiers: exact patterns without a check digit, approximate ones with it" {
    try expectExact(v.uuid, []const u8,
        \\{"format":"uuid","pattern":"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"}
    );
    try expectExact(v.mongoId, []const u8,
        \\{"pattern":"^[0-9A-Fa-f]{24}$"}
    );
    try expectExact(v.firebasePushId, []const u8,
        \\{"pattern":"^[0-9A-Za-z_-]{20}$"}
    );
    try expectExact(v.hash(.crc32), []const u8,
        \\{"pattern":"^[0-9A-Fa-f]{8}$"}
    );
    try expectExact(v.hash(.sha256), []const u8,
        \\{"pattern":"^[0-9A-Fa-f]{64}$"}
    );
    try expectExact(v.hash(.sha512), []const u8,
        \\{"pattern":"^[0-9A-Fa-f]{128}$"}
    );
    try expectSchema(v.creditCard, []const u8, .approximate,
        \\{"pattern":"^[0-9]{12,19}$"}
    , "Checked by the server: a valid credit card number, with its Luhn check digit.");
    try expectSchema(v.isbn, []const u8, .approximate,
        \\{"pattern":"^(?:[0-9]{9}[0-9X]|97(?:8[0-9]|9[1-9])[0-9]{9})$"}
    , "Checked by the server: a valid ISBN-10 or ISBN-13, with its check digit.");
    try expectSchema(v.isbn10, []const u8, .approximate,
        \\{"pattern":"^[0-9]{9}[0-9X]$"}
    , "Checked by the server: a valid ISBN-10, with its check digit.");
    try expectSchema(v.isbn13, []const u8, .approximate,
        \\{"pattern":"^97(?:8[0-9]|9[1-9])[0-9]{9}$"}
    , "Checked by the server: a valid ISBN-13, with its check digit.");
    try expectSchema(v.issn, []const u8, .approximate,
        \\{"pattern":"^[0-9]{4}-[0-9]{3}[0-9X]$"}
    , "Checked by the server: a valid ISSN, with its check digit.");
    try expectSchema(v.ean, []const u8, .approximate,
        \\{"pattern":"^(?:[0-9]{8}|[0-9]{13,14})$"}
    , "Checked by the server: a valid EAN, with its check digit.");
    try expectSchema(v.isin, []const u8, .approximate,
        \\{"pattern":"^[A-Z]{2}[0-9A-Z]{9}[0-9]$"}
    , "Checked by the server: a valid ISIN, with its check digit.");
    try expectExact(v.isrc, []const u8,
        \\{"pattern":"^[A-Z]{2}[0-9A-Z]{3}[0-9]{7}$"}
    );
    try expectExact(v.bic, []const u8,
        \\{"pattern":"^[A-Z]{6}[0-9A-Z]{2}(?:[0-9A-Z]{3})?$"}
    );
    try expectSchema(v.iban, []const u8, .approximate,
        \\{"pattern":"^[A-Z]{2}(?:0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{11,30}$"}
    , "Checked by the server: a valid IBAN, with its MOD 97-10 check digits.");
    try expectSchema(v.btcAddress(.mainnet), []const u8, .approximate,
        \\{"pattern":"^(?:bc1[02-9ac-hj-np-z]{7,87}|[13][1-9A-HJ-NP-Za-km-z]{0,34})$"}
    , "Checked by the server: a valid Bitcoin address, with its checksum.");
    try expectSchema(v.btcAddress(.testnet), []const u8, .approximate,
        \\{"pattern":"^(?:tb1[02-9ac-hj-np-z]{7,87}|[2mn][1-9A-HJ-NP-Za-km-z]{0,34})$"}
    , "Checked by the server: a valid Bitcoin testnet address, with its checksum.");
    try expectSchema(v.btcAddress(.any), []const u8, .approximate,
        \\{"pattern":"^(?:(?:bc|tb)1[02-9ac-hj-np-z]{7,87}|[123mn][1-9A-HJ-NP-Za-km-z]{0,34})$"}
    , "Checked by the server: a valid Bitcoin mainnet or testnet address, with its checksum.");
    try expectSchema(v.ethereumAddress, []const u8, .approximate,
        \\{"pattern":"^0x[0-9A-Fa-f]{40}$"}
    , "Checked by the server: a valid Ethereum address, with the EIP-55 checksum when the letters mix cases.");
}

test "dates: the calendar in the pattern of date; shapes for date-times; minDate and maxDate in the note only" {
    try expectExact(v.date, []const u8,
        \\{"format":"date","pattern":"^(?:[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|02-(?:0[1-9]|1[0-9]|2[0-8]))|(?:[0-9]{2}(?:0[48]|[2468][048]|[13579][26])|(?:[02468][048]|[13579][26])00)-02-29)$"}
    );
    try expectSchema(v.rfc3339, []const u8, .approximate,
        \\{"format":"date-time","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$"}
    , "Checked by the server: a valid RFC 3339 date-time.");
    try expectSchema(v.iso8601, []const u8, .approximate,
        \\{"pattern":"^[0-9]{4}(?:-[0-9]{2}|-?W[0-9]{2}|(?:-[0-9]{2}-[0-9]{2}|[0-9]{4}|-?[0-9]{3}|-W[0-9]{2}-[0-9]|W[0-9]{3})(?:[Tt ][0-9]{2}(?::[0-9]{2}(?::[0-9]{2})?|[0-9]{2}(?:[0-9]{2})?)?(?:[.,][0-9]+)?(?:[Zz]|[+-][0-9]{2}(?::?[0-9]{2})?)?)?)?$"}
    , "Checked by the server: a valid ISO 8601 date or date-time.");
    try expectSchema(v.minDate("2020-01-01"), []const u8, .none, "{}", "Checked by the server: a date not before 2020-01-01.");
    try expectSchema(v.maxDate("2030-12-31T23:59:59+02:00"), []const u8, .none, "{}", "Checked by the server: an RFC 3339 date-time not after 2030-12-31T23:59:59+02:00.");
    try expectExact(v.militaryTime, []const u8,
        \\{"pattern":"^(?:[01][0-9]|2[0-3]):?[0-5][0-9]$"}
    );
}

test "list rules: counts, uniqueItems, contains in allOf, items not in an enum; uniqueBy in the note by the key's outside name" {
    try expectExact(v.minItems(1), []const []const u8, "{\"minItems\":1}");
    try expectExact(v.maxItems(10), []const u32, "{\"maxItems\":10}");
    try expectExact(v.uniqueItems, []const u32, "{\"uniqueItems\":true}");
    try expectExact(v.uniqueItems, [3]Role, "{\"uniqueItems\":true}");
    try expectSchema(v.uniqueBy(.id), []const Item, .none, "{}", "Checked by the server: no two items with the same itemId.");
    try expectExact(v.containsAll(.{ "a", "b" }), []const []const u8,
        \\{"allOf":[{"contains":{"const":"a"}},{"contains":{"const":"b"}}]}
    );
    try expectExact(v.containsAll(.{.admin}), []const Role,
        \\{"allOf":[{"contains":{"const":"admin"}}]}
    );
    try expectExact(v.containsAll(.{true}), []const bool,
        \\{"allOf":[{"contains":{"const":true}}]}
    );
    try expectExact(v.containsNone(.{ 1, 2 }), [4]i32,
        \\{"items":{"not":{"enum":[1,2]}}}
    );
    try expectExact(v.containsNone(.{"x"}), []const []const u8,
        \\{"items":{"not":{"enum":["x"]}}}
    );
}

test "custom has no keywords; its message is the note" {
    try expectSchema(v.custom("users.even", "must be even", isEven), u32, .none, "{}", "Checked by the server: must be even.");
    try expectSchema(v.custom("users.free", "is taken.", isEven), u32, .none, "{}", "Checked by the server: is taken.");
    try expectSchema(v.custom("users.even", "must be even", isEven).withMessage("muss gerade sein"), u32, .none, "{}", "Checked by the server: muss gerade sein.");
}

test "a transform has no keywords and says what it does in the note" {
    try expectSchema(v.trim, []const u8, .exact, "{}", "Leading and trailing spaces are removed.");
    try expectSchema(v.trimStart, []const u8, .exact, "{}", "Leading spaces are removed.");
    try expectSchema(v.trimEnd, ?[]const u8, .exact, "{}", "Trailing spaces are removed.");
    try expectSchema(v.toLower, []const u8, .exact, "{}", "Converted to lowercase.");
    try expectSchema(v.toUpper, []const u8, .exact, "{}", "Converted to uppercase.");
    try expectSchema(v.transformWith(normalize), []const u8, .exact, "{}", "The server changes the value before it checks it.");
}

test "on ?T null stays valid: const becomes an enum with null, an enum gets null, and not passes null" {
    try expectExact(v.equals("x"), ?[]const u8, "{\"enum\":[\"x\",null]}");
    try expectExact(v.equals(true), ?bool, "{\"enum\":[true,null]}");
    try expectExact(v.equals(.admin), ?Role, "{\"enum\":[\"admin\",null]}");
    try expectExact(v.equals(7), ??u8, "{\"enum\":[7,null]}");
    try expectExact(v.oneOf(.{ "a", "b" }), ?[]const u8, "{\"enum\":[\"a\",\"b\",null]}");
    try expectExact(v.oneOf(.{ .user, .guest }), ?Role, "{\"enum\":[\"user\",\"guest\",null]}");
    try expectExact(v.noneOf(.{"a"}), ?[]const u8, "{\"not\":{\"enum\":[\"a\"]}}");
    try expectExact(v.notEquals(0), ?i32, "{\"not\":{\"const\":0}}");
    try expectExact(v.booleanString, ?[]const u8,
        \\{"enum":["true","false","1","0",null]}
    );
    try expectExact(v.notContains("x"), ?[]const u8,
        \\{"not":{"type":"string","pattern":"x"}}
    );
    try expectExact(v.maxLength(3), ?[]const u8, "{\"maxLength\":3}");
    try expectExact(v.positive, ?u32, "{\"minimum\":1}");
}

/// `s.items[i]` has these keywords, this accuracy and this note.
fn expectItem(comptime s: v.RuleSchema, comptime i: usize, accuracy: v.RuleSchema.Accuracy, keywords: []const u8, note: ?[]const u8) !void {
    try testing.expectEqualStrings(keywords, comptime objectText(s.items[i]));
    try testing.expectEqual(accuracy, s.items[i].accuracy);
    try expectNote(note, s.items[i].note);
}

test "each has no keywords of its own: its items hold the schemas of its transforms and rules, in order" {
    const one = comptime v.schemaOf(v.each(v.notEmpty), []const []const u8);
    try testing.expectEqualStrings("{}", comptime objectText(one));
    try testing.expectEqual(.exact, one.accuracy);
    try testing.expectEqual(null, one.note);
    try testing.expectEqual(1, one.items.len);
    try expectItem(one, 0, .exact, "{\"minLength\":1}", null);

    // Transforms first, as in field_rules; the least accurate item decides.
    const tags = comptime v.schemaOf(v.each(.{ v.trim, v.toLower, v.maxLength(254), v.email }), ?[]const []const u8);
    try testing.expectEqual(.approximate, tags.accuracy);
    try testing.expectEqual(4, tags.items.len);
    try expectItem(tags, 0, .exact, "{}", "Leading and trailing spaces are removed.");
    try expectItem(tags, 1, .exact, "{}", "Converted to lowercase.");
    try expectItem(tags, 2, .exact, "{\"maxLength\":254}", null);
    try testing.expectEqual(.approximate, tags.items[3].accuracy);
    try testing.expectEqualStrings("Checked by the server: a valid email address.", tags.items[3].note.?);

    // Items that are optional get null where an enum would refuse it.
    const optional = comptime v.schemaOf(v.each(v.equals("a")), []const ?[]const u8);
    try expectItem(optional, 0, .exact, "{\"enum\":[\"a\",null]}", null);

    // An array, and a rule that no keyword says.
    const array = comptime v.schemaOf(v.each(.{ v.max(9), v.custom("digits.odd", "must be odd", isEven) }), [3]u32);
    try testing.expectEqual(.none, array.accuracy);
    try expectItem(array, 0, .exact, "{\"maximum\":9}", null);
    try expectItem(array, 1, .none, "{}", "Checked by the server: must be odd.");
}

test "a nested each holds an each among its items" {
    const nested = comptime v.schemaOf(v.each(.{ v.maxItems(3), v.each(v.positive) }), []const []const u32);
    try testing.expectEqual(.exact, nested.accuracy);
    try testing.expectEqual(2, nested.items.len);
    try expectItem(nested, 0, .exact, "{\"maxItems\":3}", null);
    const inner = nested.items[1];
    try testing.expectEqualStrings("{}", comptime objectText(nested.items[1]));
    try testing.expectEqual(1, inner.items.len);
    try testing.expectEqualStrings("{\"minimum\":1}", comptime objectText(nested.items[1].items[0]));
}

test "notBlank's pattern escapes U+0085 and U+3000 as JSON escapes, and std.json reads back those code points" {
    const text = comptime v.schemaOf(v.notBlank, []const u8).keywords[0].value;
    try testing.expect(std.mem.find(u8, text, "\\u0085") != null);
    try testing.expect(std.mem.find(u8, text, "\\u3000") != null);
    // The text is ASCII: every character outside it is an escape.
    for (text) |c| try testing.expect(c >= 0x20 and c < 0x7f);
    const parsed = try std.json.parseFromSlice([]const u8, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("[^\t\n\x0b\x0c\r \u{85}\u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]", parsed.value);
}
