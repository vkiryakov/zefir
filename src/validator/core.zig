//! The core that the rule files and the walker share: limits, violations,
//! rule kinds, the `Rule` type and the compile-time helpers that check
//! declarations. Only what `root.zig` re-exports is public API.

const std = @import("std");

/// Rule constructors, declaration checks and walker functions share one
/// comptime branch counter per declaration, so the library raises the quota
/// itself: a DTO with many fields or rules never stops a build with
/// `evaluation exceeded 1000 backwards branches`.
pub const eval_quota = 10_000_000;

/// Longest `v.custom` and `v.fail` code, in bytes.
pub const max_code_bytes = 128;
/// Longest message, in bytes (not code points).
pub const max_message_bytes = 512;
/// Most violations `checkAll` keeps; `Report.truncated` says when more existed.
pub const max_report_violations = 100;

/// One failed rule. The library builds `code` and `message` at compile time:
/// they live as long as the program and never contain the checked value, so
/// a violation can be logged or sent to a client as it is.
pub const Violation = struct {
    /// `validation.<kind>` for a built-in rule (`validation.not_empty`), a
    /// precondition's code (`validation.finite`), `validation.invalid` for a
    /// malformed `validateSelf` result outside Debug builds, or the `code`
    /// argument of `v.custom` and `v.fail`.
    code: []const u8,
    /// What the value must be, without the field name: a built-in English
    /// message such as `must not be empty`, or the message given to
    /// `v.custom` or `v.fail`. Always 1-512 bytes of valid UTF-8.
    message: []const u8,
    /// The path of the value from the root: `email`, `address.city`,
    /// `items[2].name`, `[1].email`. Null means the root value itself or, for
    /// `check` only, a path that did not fit `path_buf`.
    field: ?[]const u8 = null,
};

// ------------------------------------------------------------------ kinds

/// Every rule of the catalog, 96 kinds, declared once: shipping a rule adds
/// its constructor, never a kind. The tag is the snake_case name used in
/// codes (`validation.<kind>`) and in compile errors.
pub const Kind = enum {
    // common
    equals,
    not_equals,
    one_of,
    none_of,
    empty,
    not_empty,
    // numbers
    min,
    max,
    range,
    positive,
    non_negative,
    negative,
    non_positive,
    divisible_by,
    finite,
    // strings
    min_length,
    max_length,
    length,
    min_bytes,
    max_bytes,
    utf8,
    not_blank,
    ascii,
    printable_ascii,
    alphanumeric,
    alpha,
    digits,
    lowercase,
    uppercase,
    multibyte,
    full_width,
    half_width,
    variable_width,
    contains,
    not_contains,
    strong_password,
    // formats: numbers in strings, network
    number_string,
    decimal,
    boolean_string,
    hexadecimal,
    octal,
    port,
    latitude,
    longitude,
    lat_long,
    email,
    http_url,
    fqdn,
    ip,
    ipv4,
    ipv6,
    mac_address,
    // formats: encodings and other formats
    json,
    jwt,
    base32,
    base58,
    base64,
    base64_url,
    data_uri,
    magnet_uri,
    mime_type,
    locale,
    sem_ver,
    hex_color,
    rgb_color,
    hsl_color,
    // identifiers
    uuid,
    mongo_id,
    firebase_push_id,
    hash,
    credit_card,
    isbn,
    isbn10,
    isbn13,
    issn,
    ean,
    isin,
    isrc,
    bic,
    iban,
    btc_address,
    ethereum_address,
    // dates
    date,
    rfc3339,
    iso8601,
    min_date,
    max_date,
    military_time,
    // lists
    min_items,
    max_items,
    unique_items,
    unique_by,
    contains_all,
    contains_none,
    each,
    // custom
    custom,
};

/// A kind and the name of its rule.
pub const KindInfo = struct {
    kind: Kind,
    /// The public name in the `validator` namespace: `notEmpty` for `v.notEmpty`.
    name: []const u8,
};

fn k(kind: Kind, name: []const u8) KindInfo {
    return .{ .kind = kind, .name = name };
}

/// One row per `Kind`, in declaration order (checked below).
pub const kinds = [_]KindInfo{
    k(.equals, "equals"),
    k(.not_equals, "notEquals"),
    k(.one_of, "oneOf"),
    k(.none_of, "noneOf"),
    k(.empty, "empty"),
    k(.not_empty, "notEmpty"),
    k(.min, "min"),
    k(.max, "max"),
    k(.range, "range"),
    k(.positive, "positive"),
    k(.non_negative, "nonNegative"),
    k(.negative, "negative"),
    k(.non_positive, "nonPositive"),
    k(.divisible_by, "divisibleBy"),
    k(.finite, "finite"),
    k(.min_length, "minLength"),
    k(.max_length, "maxLength"),
    k(.length, "length"),
    k(.min_bytes, "minBytes"),
    k(.max_bytes, "maxBytes"),
    k(.utf8, "utf8"),
    k(.not_blank, "notBlank"),
    k(.ascii, "ascii"),
    k(.printable_ascii, "printableAscii"),
    k(.alphanumeric, "alphanumeric"),
    k(.alpha, "alpha"),
    k(.digits, "digits"),
    k(.lowercase, "lowercase"),
    k(.uppercase, "uppercase"),
    k(.multibyte, "multibyte"),
    k(.full_width, "fullWidth"),
    k(.half_width, "halfWidth"),
    k(.variable_width, "variableWidth"),
    k(.contains, "contains"),
    k(.not_contains, "notContains"),
    k(.strong_password, "strongPassword"),
    k(.number_string, "numberString"),
    k(.decimal, "decimal"),
    k(.boolean_string, "booleanString"),
    k(.hexadecimal, "hexadecimal"),
    k(.octal, "octal"),
    k(.port, "port"),
    k(.latitude, "latitude"),
    k(.longitude, "longitude"),
    k(.lat_long, "latLong"),
    k(.email, "email"),
    k(.http_url, "httpUrl"),
    k(.fqdn, "fqdn"),
    k(.ip, "ip"),
    k(.ipv4, "ipv4"),
    k(.ipv6, "ipv6"),
    k(.mac_address, "macAddress"),
    k(.json, "json"),
    k(.jwt, "jwt"),
    k(.base32, "base32"),
    k(.base58, "base58"),
    k(.base64, "base64"),
    k(.base64_url, "base64Url"),
    k(.data_uri, "dataUri"),
    k(.magnet_uri, "magnetUri"),
    k(.mime_type, "mimeType"),
    k(.locale, "locale"),
    k(.sem_ver, "semVer"),
    k(.hex_color, "hexColor"),
    k(.rgb_color, "rgbColor"),
    k(.hsl_color, "hslColor"),
    k(.uuid, "uuid"),
    k(.mongo_id, "mongoId"),
    k(.firebase_push_id, "firebasePushId"),
    k(.hash, "hash"),
    k(.credit_card, "creditCard"),
    k(.isbn, "isbn"),
    k(.isbn10, "isbn10"),
    k(.isbn13, "isbn13"),
    k(.issn, "issn"),
    k(.ean, "ean"),
    k(.isin, "isin"),
    k(.isrc, "isrc"),
    k(.bic, "bic"),
    k(.iban, "iban"),
    k(.btc_address, "btcAddress"),
    k(.ethereum_address, "ethereumAddress"),
    k(.date, "date"),
    k(.rfc3339, "rfc3339"),
    k(.iso8601, "iso8601"),
    k(.min_date, "minDate"),
    k(.max_date, "maxDate"),
    k(.military_time, "militaryTime"),
    k(.min_items, "minItems"),
    k(.max_items, "maxItems"),
    k(.unique_items, "uniqueItems"),
    k(.unique_by, "uniqueBy"),
    k(.contains_all, "containsAll"),
    k(.contains_none, "containsNone"),
    k(.each, "each"),
    k(.custom, "custom"),
};

// The table matches `Kind`: one row per tag, in tag order, named by the tag
// in camelCase. A mismatch stops every build of the module.
comptime {
    @setEvalBranchQuota(eval_quota);
    if (kinds.len != @typeInfo(Kind).@"enum".field_names.len) @compileError("validator: internal: the kind table must list every Kind once");
    for (kinds, 0..) |row, i| {
        if (@backingInt(row.kind) != i) @compileError("validator: internal: kind table row " ++ row.name ++ " is out of order");
        if (!std.mem.eql(u8, snakeCase(row.name), @tagName(row.kind)))
            @compileError("validator: internal: kind " ++ @tagName(row.kind) ++ " does not match the public name " ++ row.name);
    }
}

/// The table row of `kind`.
pub fn info(comptime kind: Kind) KindInfo {
    return kinds[@backingInt(kind)];
}

/// `notEmpty` -> `not_empty`, `base64Url` -> `base64_url`, `isbn10` -> `isbn10`.
pub fn snakeCase(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (name) |c| out = out ++ if (std.ascii.isUpper(c)) "_" ++ [1]u8{std.ascii.toLower(c)} else [1]u8{c};
        return out;
    }
}

/// The code of a built-in rule: `validation.<kind>`, except `uniqueBy`,
/// which shares `validation.unique_items` with `uniqueItems`. `each` reports
/// through its inner rules and `custom` through the user's code.
pub fn codeOf(comptime kind: Kind) []const u8 {
    return switch (kind) {
        .unique_by => "validation.unique_items",
        .each, .custom => @compileError("validator: internal: " ++ @tagName(kind) ++ " has no code of its own"),
        else => "validation." ++ @tagName(kind),
    };
}

// ------------------------------------------------------------------ custom codes

/// Why a `v.custom` or `v.fail` code is not valid.
pub const CodeProblem = enum { too_long, empty_segment, bad_start, bad_char, one_segment, reserved };

/// Why `code` is not a valid custom code, or null. A valid code is segments
/// of `[a-z][a-z0-9_]*` joined by `.`: at least 2 segments, at most 128
/// bytes, not starting with `validation.` (the built-in rules) or `rpc.`
/// (zefir-rpc). The length is checked first. Usable at run time:
/// `validateSelf` results are checked with it.
pub fn codeProblem(code: []const u8) ?CodeProblem {
    if (code.len > max_code_bytes) return .too_long;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, code, '.');
    while (it.next()) |segment| : (segments += 1) {
        if (segment.len == 0) return .empty_segment;
        for (segment, 0..) |c, i| switch (c) {
            'a'...'z' => {},
            '0'...'9', '_' => if (i == 0) return .bad_start,
            else => return .bad_char,
        };
    }
    if (segments < 2) return .one_segment;
    if (std.mem.startsWith(u8, code, "validation.") or std.mem.startsWith(u8, code, "rpc.")) return .reserved;
    return null;
}

const code_grammar = "use segments of [a-z][a-z0-9_]* joined by '.', e.g. 'users.name_taken'";

/// The error text for a code with `problem`; the code is shown escaped.
pub fn describeCodeProblem(comptime code: []const u8, comptime problem: CodeProblem) []const u8 {
    const head = "code '" ++ escape(code) ++ "' ";
    return head ++ switch (problem) {
        .too_long => std.fmt.comptimePrint("is longer than {d} bytes", .{max_code_bytes}),
        .empty_segment => "has an empty segment; " ++ code_grammar,
        .bad_start => "has a segment that does not start with a letter; " ++ code_grammar,
        .bad_char => "has a character outside [a-z0-9_.]; " ++ code_grammar,
        .one_segment => "needs at least 2 segments, e.g. 'users.name_taken'",
        .reserved => "uses a reserved prefix (validation., rpc.)",
    };
}

/// Stops compilation with `validator: <where>: code '<code>' ...` when
/// `code` is not a valid custom code. `where` is the call: `custom("<code>", ...)`
/// or `fail(<Type>, .<field>)`.
pub fn checkCode(comptime where: []const u8, comptime code: []const u8) void {
    @setEvalBranchQuota(eval_quota);
    if (codeProblem(code)) |problem| @compileError("validator: " ++ where ++ ": " ++ describeCodeProblem(code, problem));
}

// ------------------------------------------------------------------ messages

/// Why a message cannot be used.
pub const MessageProblem = enum { empty, too_long, invalid_utf8 };

/// Why `message` is not 1-512 bytes of valid UTF-8, or null. Bytes are
/// counted, not code points. Usable at run time.
pub fn messageProblem(message: []const u8) ?MessageProblem {
    if (message.len == 0) return .empty;
    if (message.len > max_message_bytes) return .too_long;
    if (!std.unicode.utf8ValidateSlice(message)) return .invalid_utf8;
    return null;
}

/// The error text for a message with `problem`.
pub fn describeMessageProblem(comptime problem: MessageProblem) []const u8 {
    return switch (problem) {
        .empty => "message must not be empty",
        .too_long => std.fmt.comptimePrint("message is longer than {d} bytes", .{max_message_bytes}),
        .invalid_utf8 => "message must be valid UTF-8",
    };
}

/// Stops compilation with `validator: <where>: message ...` when a
/// `v.custom` or `v.fail` message is not 1-512 bytes of valid UTF-8.
pub fn checkMessage(comptime where: []const u8, comptime message: []const u8) void {
    @setEvalBranchQuota(eval_quota);
    if (messageProblem(message)) |problem| @compileError("validator: " ++ where ++ ": " ++ describeMessageProblem(problem));
}

/// `s` as it is written inside a Zig string literal (`std.zig.fmtString`):
/// `\n \r \t \\ "` are escaped; control bytes, invalid UTF-8, U+0085,
/// U+2028, U+2029 and U+FEFF are hex-encoded. Compile errors show codes
/// and arguments this way, so every text stays on one readable line.
pub fn escape(comptime s: []const u8) []const u8 {
    @setEvalBranchQuota(eval_quota);
    return std.fmt.comptimePrint("{f}", .{std.zig.fmtString(s)});
}

test "the kind table has a row for each of the 96 kinds" {
    try std.testing.expectEqual(96, kinds.len);
    try std.testing.expectEqual(96, @typeInfo(Kind).@"enum".field_names.len);
    try std.testing.expectEqualStrings("notEmpty", comptime info(.not_empty).name);
    try std.testing.expectEqualStrings("uniqueBy", comptime info(.unique_by).name);
    try std.testing.expectEqualStrings("custom", comptime info(.custom).name);
}

test "a public name in snake_case is the tag of its kind" {
    try std.testing.expectEqualStrings("not_empty", comptime snakeCase("notEmpty"));
    try std.testing.expectEqualStrings("base64_url", comptime snakeCase("base64Url"));
    try std.testing.expectEqualStrings("firebase_push_id", comptime snakeCase("firebasePushId"));
    try std.testing.expectEqualStrings("isbn13", comptime snakeCase("isbn13"));
}

test "a built-in rule's code is validation.<kind>, and uniqueBy shares uniqueItems' code" {
    try std.testing.expectEqualStrings("validation.not_empty", comptime codeOf(.not_empty));
    try std.testing.expectEqualStrings("validation.positive", comptime codeOf(.positive));
    try std.testing.expectEqualStrings("validation.unique_items", comptime codeOf(.unique_by));
}

test "a custom code is two or more lowercase segments without a reserved prefix" {
    try std.testing.expectEqual(null, codeProblem("users.name_taken"));
    try std.testing.expectEqual(null, codeProblem("a.b1_"));
    try std.testing.expectEqual(null, codeProblem("validationx.y"));
    try std.testing.expectEqual(null, codeProblem("rpcx.y"));
    try std.testing.expectEqual(CodeProblem.one_segment, codeProblem("users").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("a..b").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem(".a.b").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("a.b.").?);
    try std.testing.expectEqual(CodeProblem.bad_start, codeProblem("a.1b").?);
    try std.testing.expectEqual(CodeProblem.bad_start, codeProblem("_a.b").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.B").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.b-c").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.b c").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.\u{e9}").?);
    try std.testing.expectEqual(CodeProblem.reserved, codeProblem("validation.x").?);
    try std.testing.expectEqual(CodeProblem.reserved, codeProblem("rpc.x").?);
    // The length is checked first, in bytes: 128 fit, 129 do not.
    try std.testing.expectEqual(null, codeProblem("a." ++ @as([126]u8, @splat('b'))));
    try std.testing.expectEqual(CodeProblem.too_long, codeProblem("a." ++ @as([127]u8, @splat('b'))).?);
    try std.testing.expectEqual(CodeProblem.too_long, codeProblem("A" ++ @as([128]u8, @splat('.'))).?);
}

test "a message is 1-512 bytes of valid UTF-8, counted in bytes" {
    try std.testing.expectEqual(MessageProblem.empty, messageProblem("").?);
    try std.testing.expectEqual(null, messageProblem("must be ok"));
    try std.testing.expectEqual(null, messageProblem(&@as([512]u8, @splat('m'))));
    try std.testing.expectEqual(MessageProblem.too_long, messageProblem(&@as([513]u8, @splat('m'))).?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("\xff").?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("\xc3").?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("caf\xc3").?);
    // "€" is 3 bytes: 509 bytes plus "€" fit, 510 bytes plus "€" do not.
    const filler: [509]u8 = @splat('m');
    try std.testing.expectEqual(null, messageProblem(filler ++ "\u{20ac}"));
    try std.testing.expectEqual(MessageProblem.too_long, messageProblem(filler ++ "m\u{20ac}").?);
}

test "code and message problems are described with the texts of the custom and fail errors" {
    const expect = std.testing.expectEqualStrings;
    const grammar = "; use segments of [a-z][a-z0-9_]* joined by '.', e.g. 'users.name_taken'";
    const long_code = "a." ++ @as([127]u8, @splat('b'));
    try expect("code '" ++ long_code ++ "' is longer than 128 bytes", comptime describeCodeProblem(long_code, .too_long));
    try expect("code 'users..taken' has an empty segment" ++ grammar, comptime describeCodeProblem("users..taken", .empty_segment));
    try expect("code 'users.Taken' has a character outside [a-z0-9_.]" ++ grammar, comptime describeCodeProblem("users.Taken", .bad_char));
    try expect("code 'users.1st' has a segment that does not start with a letter" ++ grammar, comptime describeCodeProblem("users.1st", .bad_start));
    try expect("code 'taken' needs at least 2 segments, e.g. 'users.name_taken'", comptime describeCodeProblem("taken", .one_segment));
    try expect("code 'validation.mine' uses a reserved prefix (validation., rpc.)", comptime describeCodeProblem("validation.mine", .reserved));
    // The code is escaped, so a control byte or invalid UTF-8 stays readable.
    try expect("code 'users.\\x00\\xff' has a character outside [a-z0-9_.]" ++ grammar, comptime describeCodeProblem("users.\x00\xff", .bad_char));
    try expect("message must not be empty", comptime describeMessageProblem(.empty));
    try expect("message is longer than 512 bytes", comptime describeMessageProblem(.too_long));
    try expect("message must be valid UTF-8", comptime describeMessageProblem(.invalid_utf8));
}

test "a valid code and message pass the compile-time checks" {
    comptime checkCode("custom(\"users.name_taken\", ...)", "users.name_taken");
    comptime checkMessage("custom(\"users.name_taken\", ...)", "is taken");
    comptime checkCode("custom(\"a.b\", ...)", "a." ++ @as([126]u8, @splat('b')));
    comptime checkMessage("custom(\"a.b\", ...)", &@as([512]u8, @splat('m')));
}

test "escape writes strings as Zig string literals do" {
    const expect = std.testing.expectEqualStrings;
    try expect("a\\\"b\\n\\x01\\xe2\\x80\\xa8\\xff", comptime escape("a\"b\n\x01\u{2028}\xff"));
    try expect("users.name_taken", comptime escape("users.name_taken"));
    try expect("caf\u{e9}", comptime escape("caf\u{e9}"));
}
