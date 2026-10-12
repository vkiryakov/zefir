//! The format rules through `v.check` and `v.checkAll`: codes and default
//! messages, every kind of string field, optional fields and `v.each`, ""
//! and non-ASCII bytes under the rule's own code, `latitude` and
//! `longitude` on float fields with the finite precondition, the option
//! variants, and random inputs: no predicate panics, and each rule passes
//! exactly the strings its predicate accepts.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

/// A format rule, its predicate, its code and default message, and an input
/// it passes and one it fails.
const Case = struct {
    rule: v.Rule,
    predicate: fn ([]const u8) bool,
    code: []const u8,
    message: []const u8,
    good: [:0]const u8,
    bad: [:0]const u8,
};

fn isDecimalDefault(s: []const u8) bool {
    return v.isDecimal(s, .{});
}

fn isMacAddressDefault(s: []const u8) bool {
    return v.isMacAddress(s, .{});
}

fn isFqdnDefault(s: []const u8) bool {
    return v.isFqdn(s, .{});
}

const cases = [_]Case{
    .{ .rule = v.numberString, .predicate = v.isNumberString, .code = "validation.number_string", .message = "must be a number", .good = "-12.5", .bad = "1e5" },
    .{ .rule = v.decimal(.{}), .predicate = isDecimalDefault, .code = "validation.decimal", .message = "must be a decimal number", .good = "+.5", .bad = "1." },
    .{ .rule = v.booleanString, .predicate = v.isBooleanString, .code = "validation.boolean_string", .message = "must be true, false, 1 or 0", .good = "false", .bad = "TRUE" },
    .{ .rule = v.hexadecimal, .predicate = v.isHexadecimal, .code = "validation.hexadecimal", .message = "must be a hexadecimal number", .good = "0xDEADbeef", .bad = "0x" },
    .{ .rule = v.octal, .predicate = v.isOctal, .code = "validation.octal", .message = "must be an octal number", .good = "0o755", .bad = "0o8" },
    .{ .rule = v.port, .predicate = v.isPort, .code = "validation.port", .message = "must be a port number from 0 to 65535", .good = "65535", .bad = "65536" },
    .{ .rule = v.latitude, .predicate = v.isLatitude, .code = "validation.latitude", .message = "must be a latitude from -90 to 90", .good = "-90.000", .bad = "90.1" },
    .{ .rule = v.longitude, .predicate = v.isLongitude, .code = "validation.longitude", .message = "must be a longitude from -180 to 180", .good = "180.0", .bad = "-180.5" },
    .{ .rule = v.latLong, .predicate = v.isLatLong, .code = "validation.lat_long", .message = "must be a latitude,longitude pair", .good = "(40.7128, -74.0060)", .bad = "40.7128,\t-74.0060" },
    .{ .rule = v.email, .predicate = v.isEmail, .code = "validation.email", .message = "must be a valid email address", .good = "user@example.XN--P1AI", .bad = "user@example.c" },
    .{ .rule = v.httpUrl, .predicate = v.isHttpUrl, .code = "validation.http_url", .message = "must be a valid HTTP or HTTPS URL", .good = "https://example.com:8080/a?b=[1]#c", .bad = "http://user@example.com" },
    .{ .rule = v.fqdn(.{}), .predicate = isFqdnDefault, .code = "validation.fqdn", .message = "must be a valid domain name", .good = "example.com", .bad = "localhost" },
    .{ .rule = v.ip, .predicate = v.isIp, .code = "validation.ip", .message = "must be a valid IP address", .good = "::ffff:192.0.2.1", .bad = "fe80::1%eth0" },
    .{ .rule = v.ipv4, .predicate = v.isIpv4, .code = "validation.ipv4", .message = "must be a valid IPv4 address", .good = "192.0.2.1", .bad = "192.168.1.01" },
    .{ .rule = v.ipv6, .predicate = v.isIpv6, .code = "validation.ipv6", .message = "must be a valid IPv6 address", .good = "2001:db8::1", .bad = "1::2::3" },
    .{ .rule = v.macAddress(.{}), .predicate = isMacAddressDefault, .code = "validation.mac_address", .message = "must be a valid MAC address", .good = "00-00-5E-00-53-01", .bad = "00:00:5e-00:53:01" },
};

test "every format rule has its code and default message, and its predicate agrees on samples" {
    inline for (cases) |c| {
        try h.expectRule(c.rule, c.code, c.message);
        try testing.expect(c.predicate(c.good));
        try testing.expect(!c.predicate(c.bad));
        try testing.expect(!c.predicate(""));
    }
}

test "every format rule on every kind of string field, optional ones included" {
    inline for (cases) |c| {
        try h.expectPass([]const u8, c.rule, c.good);
        try h.expectFail([]const u8, c.rule, c.bad, c.code, c.message);
        try h.expectPass([:0]const u8, c.rule, c.good);
        try h.expectFail([:0]const u8, c.rule, c.bad, c.code, c.message);
        var good_buf: [c.good.len:0]u8 = c.good[0..c.good.len :0].*;
        var bad_buf: [c.bad.len:0]u8 = c.bad[0..c.bad.len :0].*;
        try h.expectPass([]u8, c.rule, &good_buf);
        try h.expectFail([:0]u8, c.rule, &bad_buf, c.code, c.message);
        try h.expectPass(?[]const u8, c.rule, null);
        try h.expectPass(?[]const u8, c.rule, c.good);
        try h.expectFail(?[]const u8, c.rule, c.bad, c.code, c.message);
        try h.expectPass(??[]const u8, c.rule, @as(?[]const u8, null));
        try h.expectFail(??[:0]const u8, c.rule, c.bad, c.code, c.message);
    }
}

test "\"\" and non-ASCII bytes fail every format rule under its own code, so withMessage applies" {
    inline for (cases) |c| {
        try h.expectFail([]const u8, c.rule, "", c.code, c.message);
        try h.expectFail([]const u8, c.rule, "\xff", c.code, c.message);
        try h.expectFail([]const u8, c.rule, c.good ++ "\xff", c.code, c.message);
        try h.expectFail([]const u8, c.rule, c.good ++ "\xc3\xa9", c.code, c.message);
        try h.expectFail([]const u8, c.rule.withMessage("bad input"), "\xc3", c.code, "bad input");
        try h.expectPass([]const u8, c.rule.withMessage("bad input"), c.good);
    }
}

test "every format rule inside each: failing items by index, null items skipped" {
    inline for (cases) |c| {
        const Lists = struct {
            slice: []const []const u8,
            array: [2][:0]const u8,
            optional_items: []const ?[]const u8,
            pub const field_rules = .{
                .slice = v.each(c.rule),
                .array = v.each(c.rule),
                .optional_items = v.each(c.rule),
            };
        };
        try h.expectValid(&Lists{ .slice = &.{ c.good, c.good }, .array = .{ c.good, c.good }, .optional_items = &.{ null, c.good } });
        try h.expectAll(&Lists{ .slice = &.{ c.good, c.bad }, .array = .{ c.bad, c.good }, .optional_items = &.{ null, c.bad } }, &.{
            .{ .code = c.code, .field = "slice[1]" },
            .{ .code = c.code, .field = "array[0]" },
            .{ .code = c.code, .field = "optional_items[1]" },
        });
    }
}

const finite_code = "validation.finite";
const finite_message = "must be a finite number";

/// `rule` (latitude or longitude) on the float field type `T`: the limits
/// pass, the next values outward fail, NaN and infinities fail the finite
/// precondition, which `.withMessage` does not change.
fn expectCoordinate(comptime T: type, comptime rule: v.Rule, comptime limit: comptime_int, code: []const u8, message: []const u8) !void {
    const lim: T = limit;
    try h.expectPass(T, rule, lim);
    try h.expectPass(T, rule, -lim);
    try h.expectPass(T, rule, -0.0);
    try h.expectPass(T, rule, 1e-7);
    try h.expectFail(T, rule, std.math.nextAfter(T, lim, std.math.inf(T)), code, message);
    try h.expectFail(T, rule, std.math.nextAfter(T, -lim, -std.math.inf(T)), code, message);
    try h.expectFail(T, rule, std.math.nan(T), finite_code, finite_message);
    try h.expectFail(T, rule, std.math.inf(T), finite_code, finite_message);
    try h.expectFail(T, rule, -std.math.inf(T), finite_code, finite_message);
    try h.expectFail(T, rule.withMessage("out of range"), std.math.nan(T), finite_code, finite_message);
    try h.expectFail(T, rule.withMessage("out of range"), lim * 2, code, "out of range");
    try h.expectPass(?T, rule, null);
    try h.expectFail(?T, rule, -lim * 2, code, message);
}

test "latitude and longitude on float fields: the limits pass, NaN and infinities fail the finite precondition" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |T| {
        try expectCoordinate(T, v.latitude, 90, "validation.latitude", "must be a latitude from -90 to 90");
        try expectCoordinate(T, v.longitude, 180, "validation.longitude", "must be a longitude from -180 to 180");
    }
    // The comparison is in the field type: the f32 above 90 fails.
    try h.expectFail(f32, v.latitude, 90.00000762939453, "validation.latitude", "must be a latitude from -90 to 90");
    try h.expectFail(f16, v.latitude, 90.0625, "validation.latitude", "must be a latitude from -90 to 90");
    try h.expectFail(f64, v.latitude, 180, "validation.latitude", "must be a latitude from -90 to 90");
    try h.expectFail(f64, v.longitude, 360, "validation.longitude", "must be a longitude from -180 to 180");
    // A string is never NaN: "NaN" is just not a coordinate.
    try h.expectFail([]const u8, v.latitude, "NaN", "validation.latitude", "must be a latitude from -90 to 90");
}

test "latitude and longitude on lists of floats: each item with its own precondition" {
    const Track = struct {
        lats: []const f64,
        lons: [3]f32,
        pub const field_rules = .{ .lats = v.each(v.latitude), .lons = v.each(v.longitude) };
    };
    try h.expectValid(&Track{ .lats = &.{ 0, -90, 90 }, .lons = .{ -180, 180, 0.5 } });
    try h.expectAll(&Track{ .lats = &.{ 90.5, std.math.nan(f64) }, .lons = .{ 181, 0, -std.math.inf(f32) } }, &.{
        .{ .code = "validation.latitude", .field = "lats[0]" },
        .{ .code = finite_code, .field = "lats[1]" },
        .{ .code = "validation.longitude", .field = "lons[0]" },
        .{ .code = finite_code, .field = "lons[2]" },
    });
}

test "decimal reports the default message of its options" {
    const code = "validation.decimal";
    try h.expectFail([]const u8, v.decimal(.{}), "1.", code, "must be a decimal number");
    try h.expectFail([]const u8, v.decimal(.{ .min_decimal_digits = 2 }), "1.5", code, "must be a whole number or have at least 2 decimal places");
    try h.expectFail([]const u8, v.decimal(.{ .max_decimal_digits = 1 }), "1.25", code, "must be a decimal number with at most 1 decimal place");
    try h.expectFail([]const u8, v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 2 }), "1.5", code, "must be a whole number or have exactly 2 decimal places");
    try h.expectFail([]const u8, v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 3 }), "1.2345", code, "must be a whole number or have 2 to 3 decimal places");
    try h.expectFail([]const u8, v.decimal(.{ .force_decimal = true }), "12", code, "must be a decimal number with at least 1 decimal place");
    try h.expectFail([]const u8, v.decimal(.{ .force_decimal = true, .max_decimal_digits = 1 }), "1.25", code, "must be a decimal number with exactly 1 decimal place");
    try h.expectFail([]const u8, v.decimal(.{ .force_decimal = true, .max_decimal_digits = 2 }), "1", code, "must be a decimal number with 1 to 2 decimal places");
    try h.expectPass([]const u8, v.decimal(.{ .min_decimal_digits = 2 }), "15");
    try h.expectPass([]const u8, v.decimal(.{ .force_decimal = true, .max_decimal_digits = 2 }), "-.75");
    try h.expectFail([]const u8, v.decimal(.{ .max_decimal_digits = 2 }).withMessage("use at most {max_decimal_digits} decimals"), "1.234", code, "use at most 2 decimals");
    // An integral float coerces to a digit count.
    try h.expectFail([]const u8, v.decimal(.{ .min_decimal_digits = 2.0, .max_decimal_digits = 3.0 }), "1.2", code, "must be a whole number or have 2 to 3 decimal places");
}

test "macAddress reports the default message of its options" {
    const code = "validation.mac_address";
    const eui64 = "00:00:5e:ef:10:00:00:01";
    try h.expectFail([]const u8, v.macAddress(.{}), "00:00:5e:00:53", code, "must be a valid MAC address");
    try h.expectFail([]const u8, v.macAddress(.{ .eui = .eui48 }), eui64, code, "must be a valid 48-bit MAC address");
    try h.expectFail([]const u8, v.macAddress(.{ .eui = .eui64 }), "00:00:5e:00:53:01", code, "must be a valid 64-bit MAC address");
    try h.expectFail([]const u8, v.macAddress(.{ .format = .bare }), "00:00:5e:00:53:01", code, "must be a MAC address of 12 or 16 hex digits without separators");
    try h.expectFail([]const u8, v.macAddress(.{ .eui = .eui48, .format = .bare }), "00005eef10000001", code, "must be a MAC address of 12 hex digits without separators");
    try h.expectFail([]const u8, v.macAddress(.{ .eui = .eui64, .format = .bare }), "00005e005301", code, "must be a MAC address of 16 hex digits without separators");
    try h.expectPass([]const u8, v.macAddress(.{}), eui64);
    try h.expectPass([]const u8, v.macAddress(.{ .eui = .eui64 }), "0000.5eef.1000.0001");
    try h.expectPass([]const u8, v.macAddress(.{ .eui = .eui48, .format = .bare }), "00005E005301");
    try h.expectFail([]const u8, v.macAddress(.{}), "00\t00\t5e\t00\t53\t01", code, "must be a valid MAC address");
}

test "fqdn options: one label, underscores, a trailing dot and a wildcard" {
    const code = "validation.fqdn";
    const message = "must be a valid domain name";
    try h.expectFail([]const u8, v.fqdn(.{}), "localhost", code, message);
    try h.expectPass([]const u8, v.fqdn(.{ .require_tld = false }), "localhost");
    try h.expectFail([]const u8, v.fqdn(.{ .require_tld = false }), "a.123", code, message);
    try h.expectPass([]const u8, v.fqdn(.{ .allow_underscores = true }), "_dmarc.example.com");
    try h.expectPass([]const u8, v.fqdn(.{ .allow_trailing_dot = true }), "example.com.");
    try h.expectFail([]const u8, v.fqdn(.{}), "example.com.", code, message);
    try h.expectPass([]const u8, v.fqdn(.{ .allow_wildcard = true }), "*.example.com");
    try h.expectFail([]const u8, v.fqdn(.{ .allow_wildcard = true }), "*.com", code, message);
    try h.expectPass([]const u8, v.fqdn(.{}), "example.xn1a");
    try h.expectFail([]const u8, v.fqdn(.{}), "example.xn1", code, message);
}

test "email: the last label of the domain is a top-level domain, xn in any case" {
    const code = "validation.email";
    const message = "must be a valid email address";
    for ([_][]const u8{ "user@example.XN--P1AI", "user@example.xn--p1ai", "user@example.Xn--p1ai", "user@example.xN--P1AI", "user@example.xn", "user@example.xn12" }) |s| {
        try h.expectPass([]const u8, v.email, s);
    }
    for ([_][]const u8{ "user@example.c", "user@example.com1", "user@example.c-m", "user@example.0x1f", "user@example.xn1", "user@localhost", "\"a b\"@example.com", "user@ex\xffample.com" }) |s| {
        try h.expectFail([]const u8, v.email, s, code, message);
    }
}

test "httpUrl: the tail, the port and the host, and what it does not guard against" {
    const code = "validation.http_url";
    const message = "must be a valid HTTP or HTTPS URL";
    for ([_][]const u8{
        "https://fonts.googleapis.com/css?family=Roboto|Open+Sans",
        "https://api.example.com/articles?page[number]=2&page[size]=10",
        "https://example.com/search?ids[]=1&ids[]=2",
        "http://example.com/a{b}^c",
        "http://example.com/a|b",
        "http://example.com/[x]",
        "https://googlecom",
        "http://169.254.169.254/latest/meta-data/",
        "http://127.0.0.1/",
        "http://[::1]/",
        "http://localhost:8080",
        "http://example.com:080/",
        "https://example.com/%00",
    }) |s| try h.expectPass([]const u8, v.httpUrl, s);
    for ([_][]const u8{
        "http://example.com/a\"b",
        "http://example.com/a\\b",
        "http://example.com/a\x7fb",
        "http://example.com/%zz",
        "http://example.com/a#b#c",
        "http://example.com:00000/",
        "http://example.com:",
        "http://example.com:000080",
        "https://user@example.com",
        "https://example.com@evil.example",
        "https://m\xc3\xbcnchen.de/",
        "https://example.com/\xc3\xbcber",
        "http://[fe80::1%25eth0]/",
        "ftp://example.com",
        "example.com",
    }) |s| try h.expectFail([]const u8, v.httpUrl, s, code, message);
}

test "the format rules combine with other rules: notEmpty first, withMessage, inside each" {
    const Server = struct {
        host: []const u8 = "example.com",
        port: ?[]const u8 = null,
        admin: []const u8 = "ops@example.com",
        mirrors: []const []const u8 = &.{},
        pub const field_rules = .{
            .host = .{ v.notEmpty, v.fqdn(.{ .require_tld = false }) },
            .port = .{ v.notEmpty, v.port },
            .admin = v.email.withMessage("ungültige E-Mail"),
            .mirrors = .{ v.maxItems(3), v.each(.{ v.notEmpty, v.httpUrl }) },
        };
    };
    comptime v.assertRules(Server);
    try h.expectValid(&Server{});
    try h.expectValid(&Server{ .port = "8080", .mirrors = &.{ "https://a.example", "http://[2001:db8::1]:8443/" } });
    try h.expectAll(&Server{ .host = "", .port = "", .admin = "ops@localhost", .mirrors = &.{ "", "ftp://x" } }, &.{
        .{ .code = "validation.not_empty", .field = "host" },
        .{ .code = "validation.not_empty", .field = "port" },
        .{ .code = "validation.email", .field = "admin" },
        .{ .code = "validation.not_empty", .field = "mirrors[0]" },
        .{ .code = "validation.http_url", .field = "mirrors[1]" },
    });
    try h.expectAt(&Server{ .admin = "x" }, "validation.email", "ungültige E-Mail", "admin");
}

test "the example at the top of formats.md compiles and checks a value" {
    const Server = struct {
        host: []const u8,
        port: []const u8,
        admin: ?[]const u8 = null,
        mirrors: []const []const u8 = &.{},
        lat: f64,

        pub const field_rules = .{
            .host = v.fqdn(.{ .require_tld = false }), // "localhost" passes
            .port = v.port,
            .admin = v.email, // null skips the rule
            .mirrors = .{ v.maxItems(5), v.each(v.httpUrl) },
            .lat = v.latitude, // a float field: NaN fails with validation.finite
        };
    };
    try h.expectValid(&Server{ .host = "localhost", .port = "8080", .mirrors = &.{"https://mirror.example.com/"}, .lat = 59.9 });
    try h.expectAll(&Server{ .host = "-bad", .port = "080", .admin = "ops@localhost", .mirrors = &.{"ftp://x"}, .lat = std.math.nan(f64) }, &.{
        .{ .code = "validation.fqdn", .field = "host" },
        .{ .code = "validation.port", .field = "port" },
        .{ .code = "validation.email", .field = "admin" },
        .{ .code = "validation.http_url", .field = "mirrors[0]" },
        .{ .code = "validation.finite", .field = "lat" },
    });
}

test "port and the numbers in strings: the spec's own examples" {
    try h.expectPass([]const u8, v.port, "0");
    try h.expectFail([]const u8, v.port, "080", "validation.port", "must be a port number from 0 to 65535");
    try h.expectFail([]const u8, v.port, "+80", "validation.port", "must be a port number from 0 to 65535");
    try h.expectPass([]const u8, v.numberString, ".5");
    try h.expectFail([]const u8, v.numberString, "1,000", "validation.number_string", "must be a number");
    try h.expectPass([]const u8, v.hexadecimal, "0h1F");
    try h.expectPass([]const u8, v.octal, "0O17");
    try h.expectFail([]const u8, v.booleanString, "True", "validation.boolean_string", "must be true, false, 1 or 0");
    try h.expectPass([]const u8, v.latLong, "40.7128,-74.0060");
    try h.expectFail([]const u8, v.latLong, "1,2,garbage", "validation.lat_long", "must be a latitude,longitude pair");
}

// ------------------------------------------------------------------ random inputs

/// The pieces random inputs are built from: the bytes and tokens that matter
/// to the grammars of this file.
const tokens = [_][]const u8{
    "0",        "1",       "5",      "9",     "05",     "12",       "45",        "89", "90",      "099",  "100",        "179",              "180",      "181",  "255",   "256",
    "65535",    "65536",   "080",    "+",     "-",      ".",        ".0",        ".5", ",",       ", ",   "(",          ")",                " ",        "\t",   "e",     "E5",
    "_",        "0x",      "0X",     "0h",    "0o",     "0O",       "x",         "h",  "o",       "g",    "a",          "f",                "F",        "8",    "true",  "false",
    "TRUE",     "yes",     "\x00",   "\x7f",  "\xff",   "\xc3\xa9", "\xc2\xa0",  "#",  ":",       "::",   ":::",        "ffff",             "FFFF",     "1234", "12345", "1.2.3.4",
    "%eth0",    "/64",     "[",      "]",     "0000",   "5eef",     "00",        "5e", "example", "com",  ".com",       "xn--p1ai",         "XN--P1AI", "xn",   "xn1",   "c",
    "0x1f",     "a-b",     "-a",     "a-",    "_dmarc", "*.",       "localhost", "@",  "@",       "user", "first.last", "!#$%&'*/=?^`{|}~", "..",       "\"",   "\\",    "http://",
    "https://", "HTTP://", "ftp://", "http:", "//",     "/",        "/a",        "?",  "q=1",     "&",    "%20",        "%",                "%zz",      "|",    "{",     "}",
    "^",        "`",       "<",      ">",
};

/// Inputs the rules accept, which random edits turn into near misses.
const seeds = [_][]const u8{
    "-12.5",            "+.5",              "0.25",              "true",                     "0",                                  "1",                   "0xDEADbeef",           "0h1F",             "0o755",           "017",           "65535",               "8080",
    "-90.000",          "45.5",             "180.0",             "05",                       "(40.7128, -74.0060)",                "40.7128,-74.0060",    "90,180",               "192.0.2.1",        "255.255.255.255", "::1",           "2001:db8::1",         "::ffff:192.0.2.1",
    "1:2:3:4:5:6:7:8",  "fe80::",           "00:1A:2B:3C:4D:5E", "00-1a-2b-3c-4d-5e-6f-70",  "001a.2b3c.4d5e",                     "0000.5eef.1000.0001", "001A2B3C4D5E",         "00005eef10000001", "example.com",     "*.example.com", "_dmarc.example.com.", "localhost",
    "example.XN--P1AI", "user@example.com", "a@b.co",            "first.last@example.co.uk", "https://example.com:8080/a?b=[1]#c", "http://[::1]:65535/", "http://192.0.2.1/%00", "http://localhost",
};

/// One random input in `buf`: random bytes, a sequence of tokens, or 1-3
/// edits of a seed.
fn randomInput(random: std.Random, buf: []u8) []const u8 {
    switch (random.uintLessThan(u8, 3)) {
        0 => {
            const len = random.uintAtMost(usize, @min(buf.len, 64));
            random.bytes(buf[0..len]);
            return buf[0..len];
        },
        1 => {
            var len: usize = 0;
            for (0..1 + random.uintLessThan(usize, 8)) |_| {
                const token = tokens[random.uintLessThan(usize, tokens.len)];
                if (len + token.len > buf.len) break;
                @memcpy(buf[len..][0..token.len], token);
                len += token.len;
            }
            return buf[0..len];
        },
        else => {
            const seed = seeds[random.uintLessThan(usize, seeds.len)];
            var len = seed.len;
            @memcpy(buf[0..len], seed);
            for (0..1 + random.uintLessThan(u8, 3)) |_| {
                switch (random.uintLessThan(u8, 3)) {
                    // Replace a byte.
                    0 => if (len > 0) {
                        buf[random.uintLessThan(usize, len)] = random.int(u8);
                    },
                    // Insert a token.
                    1 => {
                        const token = tokens[random.uintLessThan(usize, tokens.len)];
                        if (len + token.len <= buf.len) {
                            const at = random.uintAtMost(usize, len);
                            std.mem.copyBackwards(u8, buf[at + token.len .. len + token.len], buf[at..len]);
                            @memcpy(buf[at..][0..token.len], token);
                            len += token.len;
                        }
                    },
                    // Delete a byte.
                    else => if (len > 0) {
                        const at = random.uintLessThan(usize, len);
                        std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                        len -= 1;
                    },
                }
            }
            return buf[0..len];
        },
    }
}

/// `rule` passes `s` exactly when `accepted`, through `v.check`.
fn expectAgrees(comptime rule: v.Rule, s: []const u8, accepted: bool) !void {
    const Dto = h.One([]const u8, rule);
    var path_buf: [8]u8 = undefined;
    const passed = v.check(&Dto{ .x = s }, &path_buf) == null;
    if (passed != accepted) {
        std.debug.print("{s} on \"{f}\": the rule {s}, the predicate {s}\n", .{
            rule.code,                         std.zig.fmtString(s),
            if (passed) "passes" else "fails", if (accepted) "accepts" else "rejects",
        });
        return error.TestRuleDisagreesWithPredicate;
    }
}

test "random inputs: no predicate panics, each rule passes what its predicate accepts, and the grammars nest" {
    var prng = std.Random.DefaultPrng.init(0x5eed_f0a7);
    const random = prng.random();
    var buf: [96]u8 = undefined;
    var accepted: [cases.len]usize = @splat(0);
    for (0..20_000) |_| {
        const s = randomInput(random, &buf);
        inline for (cases, 0..) |c, i| {
            const ok = c.predicate(s);
            if (ok) accepted[i] += 1;
            try expectAgrees(c.rule, s, ok);
        }
        // The predicates with options apply runtime options, even those a
        // rule refuses at compile time.
        inline for (.{
            v.DecimalOptions{ .force_decimal = true },
            v.DecimalOptions{ .min_decimal_digits = 2, .max_decimal_digits = 4 },
            v.DecimalOptions{ .min_decimal_digits = 0 },
            v.DecimalOptions{ .min_decimal_digits = 3, .max_decimal_digits = 1 },
        }) |options| {
            const ok = v.isDecimal(s, options);
            const valid = comptime options.min_decimal_digits != 0 and (options.max_decimal_digits orelse options.min_decimal_digits) >= options.min_decimal_digits;
            if (valid) try expectAgrees(v.decimal(options), s, ok);
        }
        inline for (0..16) |bits| {
            const options: v.FqdnOptions = .{
                .require_tld = bits & 1 != 0,
                .allow_underscores = bits & 2 != 0,
                .allow_trailing_dot = bits & 4 != 0,
                .allow_wildcard = bits & 8 != 0,
            };
            try expectAgrees(v.fqdn(options), s, v.isFqdn(s, options));
        }
        inline for (.{ .any, .eui48, .eui64 }) |eui| {
            inline for (.{ .separated, .bare }) |format| {
                const options: v.MacAddressOptions = .{ .eui = eui, .format = format };
                try expectAgrees(v.macAddress(options), s, v.isMacAddress(s, options));
            }
        }
        // decimal with the default options is numberString; a port is a
        // number string; latLong is latitude, ", " and longitude.
        try testing.expectEqual(v.isNumberString(s), v.isDecimal(s, .{}));
        if (v.isPort(s)) try testing.expect(v.isNumberString(s));
        // ip is the union of ipv4 and ipv6, which share no string.
        try testing.expectEqual(v.isIpv4(s) or v.isIpv6(s), v.isIp(s));
        try testing.expect(!(v.isIpv4(s) and v.isIpv6(s)));
        // An email address is a local part, '@' and a domain that fqdn accepts.
        var wrap: [128]u8 = undefined;
        if (s.len <= 252) try testing.expectEqual(v.isFqdn(s, .{}), v.isEmail(try std.fmt.bufPrint(&wrap, "a@{s}", .{s})));
        // The hosts of httpUrl include the names fqdn accepts, IPv4
        // addresses, and IPv6 addresses in brackets.
        if (v.isFqdn(s, .{})) try testing.expect(v.isHttpUrl(try std.fmt.bufPrint(&wrap, "http://{s}/", .{s})));
        if (v.isIpv4(s)) try testing.expect(v.isHttpUrl(try std.fmt.bufPrint(&wrap, "https://{s}:443/", .{s})));
        if (std.mem.findAny(u8, s, "/?#[]@") == null)
            try testing.expectEqual(v.isIpv6(s), v.isHttpUrl(try std.fmt.bufPrint(&wrap, "http://[{s}]/", .{s})));
        if (s.len <= 40 and std.mem.findAny(u8, s, ",()") == null) {
            var pair_buf: [96]u8 = undefined;
            const pair = try std.fmt.bufPrint(&pair_buf, "{s}, {s}", .{ s, s });
            try testing.expectEqual(v.isLatitude(s) and v.isLongitude(s), v.isLatLong(pair));
        }
    }
    // Every rule saw inputs it accepts, so both paths ran.
    for (accepted) |n| try testing.expect(n > 0);
}
