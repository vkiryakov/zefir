//! regex_vectors writes the vectors that check the regular expressions of
//! `v.schemaOf` in other engines:
//!
//!     regex_vectors <out.json>
//!
//! For every rule whose schema on `[]const u8` holds a `pattern` (alone, in
//! `not`, `allOf` or `anyOf`), and some of their options, it writes one
//! record per input of the rule's corpus:
//!
//!     {"rule":"notBlank","schema":{...},"input":"...","pass":true,"exact":true}
//!
//! `schema` is the rule's keywords as one JSON object, the very text that a
//! document holds; `pass` is the verdict of `v.check` on a DTO with one
//! `[]const u8` field and the rule; `exact` tells whether the schema is
//! exact. tests/openapi (`zig build regex`) gives each record to a JSON
//! Schema validator on ECMA-262 regular expressions (ajv, with the `u` flag)
//! and to one on RE2 (Go's regexp): an exact schema must give the verdict of
//! the rule, an approximate one must pass what the rule passes.
//!
//! The corpus of a rule is the strings of the validator's tests in this
//! folder (the string literals of the `*_test.zig` of its family, and the
//! inputs of `vectors/*.json`) and edges: every
//! White_Space character, the first and last code points of the classes
//! the patterns use, the bounds of the numbers they spell, and the forms
//! each rule takes and refuses. Inputs that are not valid UTF-8 are left
//! out: a JSON string cannot hold them. build.zig builds the program in
//! `test-validator` without running it.
const std = @import("std");
const v = @import("validator");
const Allocator = std.mem.Allocator;

/// A panic exits with code 3: an aborting process hangs some machines.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("regex_vectors: panic: {s}\n", .{message});
    std.process.exit(3);
}

/// The test file of each family, whose strings go to its rules.
const Family = enum { strings, formats, encodings, identifiers, dates };

/// A rule under test.
const Case = struct {
    label: []const u8,
    family: Family,
    /// The keywords as one JSON object.
    schema: []const u8,
    exact: bool,
    passes: *const fn ([]const u8) bool,
    /// Inputs of this rule alone.
    edges: []const []const u8 = &.{},
};

/// `rule` on `[]const u8`, labelled as the call that builds it.
fn case(comptime label: []const u8, comptime family: Family, comptime rule: v.Rule) Case {
    return caseWith(label, family, rule, &.{});
}

fn caseWith(comptime label: []const u8, comptime family: Family, comptime rule: v.Rule, comptime edges: []const []const u8) Case {
    const s = comptime v.schemaOf(rule, []const u8);
    const text = comptime objectText(s);
    if (comptime std.mem.find(u8, text, "\"pattern\"") == null) @compileError("regex_vectors: " ++ label ++ " has no pattern");
    return .{
        .label = label,
        .family = family,
        .schema = text,
        .exact = s.accuracy == .exact,
        .passes = &struct {
            fn passes(input: []const u8) bool {
                const Dto = struct {
                    x: []const u8,
                    pub const field_rules = .{ .x = rule };
                };
                const dto: Dto = .{ .x = input };
                var path_buf: [64]u8 = undefined;
                return v.check(&dto, &path_buf) == null;
            }
        }.passes,
        .edges = edges,
    };
}

/// The keywords of `s` as one JSON object, in their order.
fn objectText(comptime s: v.RuleSchema) []const u8 {
    var out: []const u8 = "{";
    for (s.keywords, 0..) |k, i| out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ k.name ++ "\":" ++ k.value;
    return out ++ "}";
}

/// The seeds of the `contains` and `notContains` cases: the syntax
/// characters of both engines, and characters outside ASCII.
const seeds = [_][]const u8{ "@", "a.b", "(x)", "[y]", "{z}", "a|b", "^$", "a*b+c?", "\\", "-", "/", " ", "\n", "a\"b", "\u{e9}", "\u{1f600}", "\u{3000}" };

const cases = blk: {
    var list: []const Case = &.{
        case("notBlank", .strings, v.notBlank),
        case("ascii", .strings, v.ascii),
        case("printableAscii", .strings, v.printableAscii),
        case("alphanumeric", .strings, v.alphanumeric),
        case("alpha", .strings, v.alpha),
        case("digits", .strings, v.digits),
        case("lowercase", .strings, v.lowercase),
        case("uppercase", .strings, v.uppercase),
        case("multibyte", .strings, v.multibyte),
        case("fullWidth", .strings, v.fullWidth),
        case("halfWidth", .strings, v.halfWidth),
        case("variableWidth", .strings, v.variableWidth),
        case("strongPassword(.{})", .strings, v.strongPassword(.{})),
        case("strongPassword(.{ .min_length = 4, .min_lowercase = 0, .min_uppercase = 2, .min_numbers = 0, .min_symbols = 2 })", .strings, v.strongPassword(.{ .min_length = 4, .min_lowercase = 0, .min_uppercase = 2, .min_numbers = 0, .min_symbols = 2 })),
        case("numberString", .formats, v.numberString),
        case("decimal(.{})", .formats, v.decimal(.{})),
        case("decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 3 })", .formats, v.decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 3 })),
        case("decimal(.{ .force_decimal = true, .max_decimal_digits = 2 })", .formats, v.decimal(.{ .force_decimal = true, .max_decimal_digits = 2 })),
        case("hexadecimal", .formats, v.hexadecimal),
        case("octal", .formats, v.octal),
        case("port", .formats, v.port),
        case("latitude", .formats, v.latitude),
        case("longitude", .formats, v.longitude),
        case("latLong", .formats, v.latLong),
        case("email", .formats, v.email),
        case("httpUrl", .formats, v.httpUrl),
        case("fqdn(.{})", .formats, v.fqdn(.{})),
        case("fqdn(.{ .require_tld = false })", .formats, v.fqdn(.{ .require_tld = false })),
        case("fqdn(.{ .allow_underscores = true, .allow_trailing_dot = true })", .formats, v.fqdn(.{ .allow_underscores = true, .allow_trailing_dot = true })),
        case("fqdn(.{ .require_tld = false, .allow_trailing_dot = true, .allow_wildcard = true })", .formats, v.fqdn(.{ .require_tld = false, .allow_trailing_dot = true, .allow_wildcard = true })),
        case("ip", .formats, v.ip),
        case("ipv4", .formats, v.ipv4),
        case("ipv6", .formats, v.ipv6),
        case("macAddress(.{})", .formats, v.macAddress(.{})),
        case("macAddress(.{ .eui = .eui48 })", .formats, v.macAddress(.{ .eui = .eui48 })),
        case("macAddress(.{ .format = .bare })", .formats, v.macAddress(.{ .format = .bare })),
        case("macAddress(.{ .eui = .eui64, .format = .bare })", .formats, v.macAddress(.{ .eui = .eui64, .format = .bare })),
        case("json", .encodings, v.json),
        case("jwt", .encodings, v.jwt),
        case("base32", .encodings, v.base32),
        case("base58", .encodings, v.base58),
        case("base64", .encodings, v.base64),
        case("base64Url", .encodings, v.base64Url),
        case("dataUri", .encodings, v.dataUri),
        case("magnetUri", .encodings, v.magnetUri),
        case("mimeType", .encodings, v.mimeType),
        case("locale", .encodings, v.locale),
        case("semVer", .encodings, v.semVer),
        case("hexColor", .encodings, v.hexColor),
        case("rgbColor", .encodings, v.rgbColor),
        case("hslColor", .encodings, v.hslColor),
        case("uuid", .identifiers, v.uuid),
        case("mongoId", .identifiers, v.mongoId),
        case("firebasePushId", .identifiers, v.firebasePushId),
        case("hash(.crc32)", .identifiers, v.hash(.crc32)),
        case("hash(.md5)", .identifiers, v.hash(.md5)),
        case("hash(.sha1)", .identifiers, v.hash(.sha1)),
        case("hash(.tiger192)", .identifiers, v.hash(.tiger192)),
        case("hash(.sha256)", .identifiers, v.hash(.sha256)),
        case("hash(.sha384)", .identifiers, v.hash(.sha384)),
        case("hash(.sha512)", .identifiers, v.hash(.sha512)),
        case("creditCard", .identifiers, v.creditCard),
        case("isbn", .identifiers, v.isbn),
        case("isbn10", .identifiers, v.isbn10),
        case("isbn13", .identifiers, v.isbn13),
        case("issn", .identifiers, v.issn),
        case("ean", .identifiers, v.ean),
        case("isin", .identifiers, v.isin),
        case("isrc", .identifiers, v.isrc),
        case("bic", .identifiers, v.bic),
        case("iban", .identifiers, v.iban),
        case("btcAddress(.mainnet)", .identifiers, v.btcAddress(.mainnet)),
        case("btcAddress(.testnet)", .identifiers, v.btcAddress(.testnet)),
        case("btcAddress(.any)", .identifiers, v.btcAddress(.any)),
        case("ethereumAddress", .identifiers, v.ethereumAddress),
        case("date", .dates, v.date),
        case("rfc3339", .dates, v.rfc3339),
        case("iso8601", .dates, v.iso8601),
        case("militaryTime", .dates, v.militaryTime),
    };
    for (seeds) |seed| {
        const edges = seedEdges(seed);
        list = list ++ &[_]Case{
            caseWith("contains(\"" ++ seed ++ "\")", .strings, v.contains(seed), edges),
            caseWith("notContains(\"" ++ seed ++ "\")", .strings, v.notContains(seed), edges),
        };
    }
    break :blk list;
};

/// The seed, around other text, twice, without its last character, and with
/// each syntax character of the engines turned into a letter: the near
/// misses of a pattern that would not escape it.
fn seedEdges(comptime seed: []const u8) []const []const u8 {
    var mangled: []const u8 = "";
    for (seed) |c| mangled = mangled ++ [1]u8{if (std.mem.findScalar(u8, "^$\\.*+?()[]{}|", c) != null) 'Q' else c};
    return &.{ seed, "<" ++ seed ++ ">", seed ++ seed, mangled, "x" ++ mangled ++ "y", seed[0 .. seed.len - 1] };
}

// ------------------------------------------------------------------ the corpus

/// The test file of each family, whose string literals go to its rules.
const family_sources = .{
    .strings = .{@embedFile("strings_test.zig")},
    .formats = .{@embedFile("formats_test.zig")},
    .encodings = .{@embedFile("encodings_test.zig")},
    .identifiers = .{@embedFile("identifiers_test.zig")},
    .dates = .{@embedFile("dates_test.zig")},
};
const vector_files = .{
    @embedFile("vectors/common.json"),
    @embedFile("vectors/numbers.json"),
    @embedFile("vectors/lists.json"),
};

/// The code points that start or end a class of some pattern, or sit next
/// to one: White_Space, the half-width forms, ASCII, Latin-1, surrogates'
/// neighbours and the last code point.
const boundary_code_points = [_]u21{
    0x00,   0x08,   0x09,   0x0a,   0x0b,   0x0c,   0x0d,   0x0e,    0x1f,    0x20,     0x21,   0x22,
    0x2f,   0x30,   0x39,   0x3a,   0x40,   0x41,   0x5a,   0x5b,    0x5c,    0x5d,     0x5e,   0x5f,
    0x60,   0x61,   0x7a,   0x7b,   0x7c,   0x7d,   0x7e,   0x7f,    0x80,    0x84,     0x85,   0x86,
    0x9f,   0xa0,   0xa1,   0xa2,   0xa3,   0xa4,   0xff,   0x167f,  0x1680,  0x1681,   0x1fff, 0x2000,
    0x2005, 0x200a, 0x200b, 0x2027, 0x2028, 0x2029, 0x202a, 0x202e,  0x202f,  0x2030,   0x205e, 0x205f,
    0x2060, 0x2fff, 0x3000, 0x3001, 0x3164, 0xd7ff, 0xe000, 0xfeff,  0xff60,  0xff61,   0xff71, 0xffdc,
    0xffdd, 0xffe7, 0xffe8, 0xffee, 0xffef, 0xfffd, 0xffff, 0x10000, 0x1f600, 0x10ffff,
};

/// Inputs for every rule.
const common_edges = [_][]const u8{
    "",         " ",         "  ",                       "a",                        "A",           "z",         "Z",        "0",                        "9",
    "-",        "+",         ".",                        "x",                        "abc",         "ABC",       "aBc",      "123",                      "a b",
    " a",       "a ",        "\t",                       "\n",                       "\r\n",        "\u{e9}",    "\u{df}",   "\u{65e5}\u{672c}\u{8a9e}", "\u{1f600}",
    "\u{ff21}", "\u{ff71}",  "\u{a3}",                   "\u{20ac}",                 "\u{c4}",      "a\u{0}b",   "a\u{7f}b", "a\u{85}b",                 "\u{feff}a",
    "abc\n",    "caf\u{e9}", "\u{ff71}\u{ff72}\u{ff73}", "\u{ff41}\u{ff42}\u{ff43}", "abc\u{ff21}", "x\u{200b}", "\u{3164}", "1e5",                      "0x1f",
    "1,000",    "1_000",     "NaN",                      "-0",                       "00",          "true",      "false",    "null",                     "[]",
    "{}",       "\"\"",      "a.b",                      "a..b",                     ".a",          "a.",        "@",        "a@b",                      "a@b.c",
};

const strings_edges = [_][]const u8{
    "Aa1!aaaa",       "aaaaaaaa", "AAAAAAAA",    "11111111",  "!!!!!!!!",  "Aa1 aaaa",                               "Aa1\u{a3}aaaa", "Aa1\u{20ac}aaaa",
    "Aa1\taaaa",      "Aa1!aaa",  "Aa1![aaa",    "Aa1!`aaa",  "Aa1!{aaa",  "Aa1!~aaa",                               "Aa1!\\aaa",     "Aa1!]aaa",
    "Aa1!^aaa",       "Aa1!-aaa", "Aa1!/aaa",    "Aa1!:aaa",  "Aa1!@aaa",  "\u{c4}\u{d6}\u{dc}\u{e4}\u{f6}\u{fc}1!", "Ab1!",          "AB!!",
    "A!",             "aB!?",     "ab!\u{a3}",   "AB\u{a2}!", "AB\u{a4}!", "AB !",                                   "AB\u{7f}!",     "ABC[]",
    "ABC\\_",         "ABC`{",    "AB|}~",       "AB@[",      "AB/:",      "AB0!",                                   "Aa",            "AAa!",
    "\u{c0}\u{c1}!!", "AB\n!!",   "AB\u{3000}!",
};

const formats_edges = [_][]const u8{
    // numbers in strings
    "1",                                  "-1",                  "+1",                     "1.5",                     "-.5",                     "+.5",
    "1.",                                 "--1",                 "+-1",                    "1..2",                    "1.2.3",                   "0.0",
    "007",                                "1.1",                 "1.12",                   "1.123",                   "1.1234",                  ".12",
    ".123",                               "12.00",               "-12.000",                "+0.1",                    "1. 5",                    " 1",
    "1 ",                                 "0x",                  "0x1",                    "0X1f",                    "0h1",                     "0H",
    "ff",                                 "FF",                  "0xg",                    "#ff",                     "0o",                      "0o7",
    "0O17",                               "0o8",                 "17",                     "8",                       "0x0x1",                   "x1",
    "0b1",                                "0h",                  "0hh1",
    // ports
                      "1",                       "10",                      "99",
    "100",                                "999",                 "1000",                   "9999",                    "10000",                   "59999",
    "60000",                              "64999",               "65000",                  "65499",                   "65500",                   "65529",
    "65530",                              "65535",               "65536",                  "65539",                   "65540",                   "65599",
    "65600",                              "66000",               "69999",                  "70000",                   "99999",                   "100000",
    "065535",                             "080",                 "+80",
    // coordinates
                       "90",                      "90.0",                    "90.1",
    "-90",                                "+90.000",             "89.999",                 "05",                      "5",                       "180",
    "180.0",                              "180.01",              "179.9999",               "099",                     "99",                      "100",
    "-180",                               "90.",                 ".5",                     "1,5",                     "45.5,-122.3",             "(45.5, -122.3)",
    "(45.5,-122.3",                       "45.5,-122.3)",        "45.5,  -122.3",          "45.5 ,1",                 "45.5,\t1",                "(1,2)",
    "1,2",                                "91,0",                "0,181",                  "-90,-180",                "(+90.0, +180.0)",         "90,180",
    "90.00,180.00",                       "9,99",                "10,100",
    // email and URLs
                    "a@b.co",                  "user@example.com",        "user.name+tag@example.co.uk",
    ".user@example.com",                  "user.@example.com",   "us..er@example.com",     "user@example.c",          "user@localhost",          "user@-example.com",
    "user@example-.com",                  "user@ex_ample.com",   "user@123.com",           "user@example.123",        "user@xn--p1ai.xn--p1ai",  "user@example.XN--P1AI",
    "user@a.b.c.d.museum",                "\"q\"@example.com",   "user@[192.0.2.1]",       "a@b@c.com",               "a@b.c-d",                 "a@b.xn-a",
    "a@b.xn--",                           "a@b.c1",              "{|}~@x.yz",              "http://a",                "https://example.com",     "HTTP://EXAMPLE.COM",
    "ftp://example.com",                  "http:/a",             "//a",                    "https://",                "hTtPs://x",               "http://user@example.com",
    "https://example.com:8080/a?b=[1]#c",
    // domain names
    "example.com",         "localhost",              "a.b",                     "a.b.c",                   "a-b.com",
    "-a.com",                             "a-.com",              "a_b.com",                "_dmarc.example.com",      "*.example.com",           "example.com.",
    "example.com..",                      ".example.com",        "123",                    "1.2.3.4",                 "a.123",                   "123.a",
    "xn--p1ai",                           "a.xn--p1ai",          "a.xn-a",                 "a.XN--P1AI",              "*.",                      "*",
    "a*.com",                             "a.c",                 "a.co",                   "1a.com",                  "a.1a",                    "a.b1",
    "*.123",                              "a.123.",              "1-2",                    "a.1-2",                   "_.com",                   "a._b",
    "a.b_",
    // IP addresses
                                  "0.0.0.0",             "255.255.255.255",        "256.0.0.0",               "01.2.3.4",                "1.2.3",
    "1.2.3.4.5",                          "1.2.3.04",            "199.249.250.255",        "200.0.0.0",               "249.0.0.0",               "::",
    "::1",                                "1::",                 "1:2:3:4:5:6:7:8",        "1:2:3:4:5:6:7:8:9",       "::ffff:192.0.2.1",        "fe80::1%eth0",
    "1::2::3",                            "[::1]",               "2001:db8::",             "2001:DB8::1",             "12345::",                 "1:2:3:4:5:6:7::",
    "g::1",
    // MAC addresses
                                  "00:1A:2B:3C:4D:5E",   "00-1a-2b-3c-4d-5e",      "00 1a 2b 3c 4d 5e",       "001a.2b3c.4d5e",          "001A2B3C4D5E",
    "00:1A:2B:3C:4D:5E:6F:70",            "001a.2b3c.4d5e.6f70", "001A2B3C4D5E6F70",       "00:1A-2B:3C:4D:5E",       "00:1A:2B:3C:4D",          "00:1A:2B:3C:4D:5E:6F",
    "0:1A:2B:3C:4D:5E",                   "00:1G:2B:3C:4D:5E",   "00\t1a\t2b\t3c\t4d\t5e", "00-1a-2b-3c-4d-5e-6f-70", "00 1a 2b 3c 4d 5e 6f 70", "001a2b3c4d5",
    "001a.2b3c4d5e",
};

const encodings_edges = [_][]const u8{
    // base64 and base64url
    "Zg==",             "Zh==",                                     "Zm8=",                                                         "Zm9=",                 "Zm9v",                       "Zm9",                         "Zg",         "Zg=",           "====",
    "A===",             "AAAA",                                     "A+/=",                                                         "Zm9vYg==",             "Zm9vYmE=",                   "Zm9vYmFy",                    "-_-_",       "Zm9v\n",        "Zh",
    "Zm8",              "Z",                                        "-_",                                                           "+/",                   "AQ==",                       "AR==",                        "Ag==",       "AE=",           "AAE=",
    "AAF=",             "Zw==",                                     "Zx==",                                                         "Zz==",                 "AAA=",                       "AAB=",                        "AA0=",       "AA9=",
    // base32 and base58
             "MY======",
    "MZ======",         "MZXQ====",                                 "MZXR====",                                                     "MZXW6===",             "MZXW7===",                   "MZXW6YQ=",                    "MZXW6YR=",   "MZXW6YTB",      "MZXW6YTBOI======",
    "my======",         "MY=====",                                  "MY=======",                                                    "M1======",             "MZXW6YTBOI",                 "MA======",                    "M4======",   "M5======",      "MZXA====",
    "MZXW2===",         "MZXW6YI=",                                 "MZXW6YT=",                                                     "AA======",             "AAAA====",                   "AAAAA===",                    "AAAAAAA=",   "AAAAAAAA",      "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz",
    "0",                "O",                                        "I",                                                            "l",
    // JWT
                       "a.b.c",                      "a.b.",                        ".b.c",       "a..c",          "a.b",
    "a.b.c.d",          "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", "a+b.c.d",                                                      "Bearer a.b.c",
    // URIs, media types, language tags
            "data:,",                     "data:text/plain;base64,Zg==", "DATA:,",     "data:",         "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a",
    "magnet:?",         "magnet:",                                  "MAGNET:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a", "text/plain",           "TEXT/HTML; charset=utf-8",   "image/*",                     "*/*",        "foo/bar",       "application/",
    "application/json", "/json",                                    "video/-x",                                                     "en",                   "en-US",                      "zh-Hant-TW",                  "i-klingon",  "x-private",     "en_US",
    "english",          "1en",                                      "e",                                                            "abcdefghi",            "en-",                        "-en",                         "en--US",     "sgn-BE-FR",     "en-GB-oed",
    "de-CH-1901",       "a-b",                                      "x",
    // versions and colors
                                                               "1.0.0",                "0.0.0",                      "01.0.0",                      "1.0",        "1.0.0-alpha",   "1.0.0-alpha.1",
    "1.0.0-0.3.7",      "1.0.0-x.7.z.92",                           "1.0.0-alpha+001",                                              "1.0.0+20130313144700", "1.0.0-beta+exp.sha.5114f85", "1.0.0-01",                    "1.0.0-",     "1.0.0+",        "1.0.0-a..b",
    "v1.0.0",           "1.0.0-alpha-1",                            "1.0.0--",                                                      "1.0.0-0a",             "1.0.0+01",                   "1.2.3.4",                     "10.20.30",   "1.0.0-0",       "1.0.0-00",
    "#fff",             "#ffff",                                    "#ff0000",                                                      "#ff000080",            "#ff",                        "#fffff",                      "#ggg",       "fff",           "#FFF",
    "#fffffff",         "#fffffffff",                               "rgb(0,0,0)",                                                   "rgba(0,0,0,0.5)",      "rgb(255, 255, 255)",         "rgb(256,0,0)",                "RGB(0,0,0)", "rgb(0%,0%,0%)", "hsl(0,0%,0%)",
    "HSL(0 0% 0%)",     "hsla(1turn 50% 50% / 0.5)",                "hsl(0,0%,0%))",                                                "rgb(0,0,0",            "rgb()",                      "rgba(0,0,0)",                 "hsl(",       "hsl()",         "hsla(0deg, 0%, 0%, 1)",
    // JSON
    "[]",               "{}",                                       " [1]",                                                         "\t{\"a\":1}\n",        "1",                          "\"x\"",                       "\u{feff}[]", "[",             "{",
    "x[]",              "\u{a0}[]",
};

const identifiers_edges = [_][]const u8{
    "123e4567-e89b-12d3-a456-426614174000",                             "123E4567-E89B-12D3-A456-426614174000",                           "00000000-0000-0000-0000-000000000000",
    "{123e4567-e89b-12d3-a456-426614174000}",                           "123e4567e89b12d3a456426614174000",                               "123e4567-e89b-12d3-a456-42661417400",
    "507f1f77bcf86cd799439011",                                         "507F1F77BCF86CD799439011",                                       "507f1f77bcf86cd79943901",
    "507f1f77bcf86cd7994390111",                                        "0x507f1f77bcf86cd7994390",                                       "-KfTE8bIhWtMUOWhDH0B",
    "-KfTE8bIhWtMUOWhDH0",                                              "-KfTE8bIhWtMUOWhDH0BB",                                          "-KfTE8bIhWtMUOWhDH.B",
    "d87f7e0c",                                                         "D87F7E0C",                                                       "d87f7e0",
    "d87f7e0cc",                                                        "d41d8cd98f00b204e9800998ecf8427e",                               "d41d8cd98f00b204e9800998ecf8427",
    "da39a3ee5e6b4b0d3255bfef95601890afd80709",                         "3293fc5aa0a2ee8dbf16d2e8ff2d8e1fb0c2c8e2cb2e66c9",               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85g", "4111111111111111",                                               "4111111111111112",
    "41111111111",                                                      "411111111111",                                                   "4111111111111111111",
    "41111111111111111111",                                             "4111-1111-1111-1111",                                            "0306406152",
    "030640615X",                                                       "030640615x",                                                     "0306406153",
    "030640615",                                                        "9780306406157",                                                  "9790306406156",
    "9790000000001",                                                    "9781234567897",                                                  "978030640615",
    "97803064061571",                                                   "979030640615X",                                                  "0378-5955",
    "0378-595X",                                                        "03785955",                                                       "0378-595x",
    "0378-59555",                                                       "73513537",                                                       "4006381333931",
    "40063813339310",                                                   "400638133393",                                                   "4006381333932",
    "US0378331005",                                                     "us0378331005",                                                   "US037833100",
    "US03783310051",                                                    "U10378331005",                                                   "USRC17607839",
    "US-RC1-76-07839",                                                  "usrc17607839",                                                   "USRC1760783",
    "DEUTDEFF",                                                         "DEUTDEFF500",                                                    "DEUTDEF",
    "deutdeff",                                                         "DEUT12FF",                                                       "DEUTDEFF50",
    "DE89370400440532013000",                                           "GB82WEST12345698765432",                                         "DE00370400440532013000",
    "DE01370400440532013000",                                           "DE99370400440532013000",                                         "DE98370400440532013000",
    "DE0237040044",                                                     "DE89370400440532013000123456789012",                             "DE89370400440532013000123456789",
    "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",                               "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",                             "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
    "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn",                               "2MzQwSSnBHWHqSAqtTVQ6v47XtaisrJa1Vc",                            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
    "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4",                       "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",                     "bc1",
    "1",                                                                "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "0x52908400098527886E0F7030069857D2E4169EE7",
    "0x52908400098527886e0f7030069857d2e4169ee7",                       "0X52908400098527886E0F7030069857D2E4169EE7",                     "0x52908400098527886E0F7030069857D2E4169EE",
    "52908400098527886E0F7030069857D2E4169EE7",
};

const dates_edges = [_][]const u8{
    "2020-02-29T23:59:60Z",           "2020-12-31T23:59:60Z",      "2020-12-31T23:59:60+00:00", "2021-01-01T01:59:60+02:00",
    "2020-06-30t23:59:60z",           "2020-01-01 00:00:00Z",      "2020-01-01T24:00:00Z",      "2020-01-01T23:60:00Z",
    "2020-01-01T00:00:00.123456789Z", "2020-01-01T00:00:00.Z",     "2020-01-01T00:00:00",       "2020-01-01T00:00:00+05",
    "2020-01-01T00:00:00+0530",       "2020-01-01T00:00:00+24:00", "2020-01-01T00:00:00-00:00", "2020-01-01T00:00:00,5Z",
    "2020-01-01T00:00:00+23:59",      "2020-01-01T00:00:00+23:60", "2020-01-01T00:00:61Z",      "2020-02-30T00:00:00Z",
    "2020",                           "2020-05",                   "202005",                    "2020-05-17",
    "20200517",                       "2020-138",                  "2020138",                   "2020-W20",
    "2020W20",                        "2020-W20-7",                "2020W207",                  "2020-W53",
    "2021-W53",                       "2020-W54",                  "2020-366",                  "2021-366",
    "2020-W20T10",                    "2020-05-17T10",             "2020-05-17T10:30",          "2020-05-17T1030",
    "2020-05-17T10:30:00",            "2020-05-17T103000",         "2020-05-17T10:30:00.5",     "2020-05-17T10:30:00,5",
    "2020-05-17T10:30:00Z",           "2020-05-17T10:30:00+05",    "2020-05-17T10:30:00+0530",  "2020-05-17T10:30:00+05:30",
    "2020-05-17T24:00",               "2020-05-17T24:00:01",       "2020-05-17T10:30:60Z",      "2020-06-30T23:59:60Z",
    "20200517T103000Z",               "2020-05-17 10:30",          "2020-05-17t10:30z",         "2020-05-1710:30",
    "2020-W207T10",                   "2020-W20-7T10:30",          "2020W207T1030",             "2020138T10",
    "2020-138T10:30Z",                "2020-05-17T10:30:00.5+05",  "2020-05-17T10.5",           "2020-05-17T10:30.5",
    "2020-05-17T1030.5Z",             "2020-05-17T10:3000",        "2020-05-17T10:30+0",        "2020-05-17T10:30+05:3",
    "2020-05-17T",                    "2020-05-17T1",              "2020-05-17T105",            "0000-01-01",
    "00:00",                          "23:59",                     "24:00",                     "0000",
    "2359",                           "2400",                      "12:60",                     "1:00",
    "01:0",                           "12:345",                    "12:5",                      "1259",
    "19:59",                          "20:00",                     "09:09",                     "29:00",
};

/// Calendar dates around every month end, in leap and common years.
fn appendDates(arena: Allocator, list: *std.ArrayList([]const u8)) !void {
    const years = [_][]const u8{ "0000", "0004", "0100", "0400", "1600", "1700", "1900", "2000", "2001", "2004", "2023", "2024", "2100", "2400", "9996", "9999" };
    const months = [_][]const u8{ "00", "01", "02", "03", "04", "06", "09", "10", "11", "12", "13" };
    const days = [_][]const u8{ "00", "01", "09", "10", "19", "20", "28", "29", "30", "31", "32" };
    for (years) |y| {
        for (months) |m| {
            for (days) |d| {
                const day = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ y, m, d });
                try list.append(arena, day);
                // The month ends as date-times too.
                if (std.mem.eql(u8, d, "29") or std.mem.eql(u8, d, "30") or std.mem.eql(u8, d, "31"))
                    try list.append(arena, try std.fmt.allocPrint(arena, "{s}T12:00:00Z", .{day}));
            }
        }
    }
}

/// A domain name of `total` bytes: labels of `a` of at most 63 bytes, then
/// ".com".
fn longName(arena: Allocator, total: usize) ![]const u8 {
    const out = try arena.alloc(u8, total);
    @memset(out, 'a');
    @memcpy(out[total - 4 ..], ".com");
    var at: usize = 0;
    var left = total - 4;
    while (left > 63) {
        // At least one byte stays for the label after the dot.
        const label: usize = @min(63, left - 2);
        out[at + label] = '.';
        at += label + 1;
        left -= label + 1;
    }
    return out;
}

/// The lengths that `isFqdn` and `isEmail` bound: labels of 63 and 64
/// bytes, names of 253 to 255 bytes with and without a trailing dot or a
/// wildcard, and addresses of 254 and 255 bytes.
fn appendLongNames(arena: Allocator, list: *std.ArrayList([]const u8)) !void {
    const label63 = try arena.alloc(u8, 63);
    @memset(label63, 'b');
    try list.append(arena, try std.mem.concat(arena, u8, &.{ label63, ".com" }));
    try list.append(arena, try std.mem.concat(arena, u8, &.{ label63, "b.com" }));
    try list.append(arena, try std.mem.concat(arena, u8, &.{ "x.", label63 }));
    try list.append(arena, try std.mem.concat(arena, u8, &.{ "x.", label63, "b" }));
    try list.append(arena, try std.mem.concat(arena, u8, &.{ "x.xn--", label63[0..57] }));
    try list.append(arena, try std.mem.concat(arena, u8, &.{ "x.xn--", label63[0..58] }));
    for ([_]usize{ 251, 252, 253, 254, 255 }) |total| {
        const name = try longName(arena, total);
        try list.append(arena, name);
        try list.append(arena, try std.mem.concat(arena, u8, &.{ name, "." }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ "*.", name }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ "u@", name[0 .. total - 2] }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ label63[0..62], "@", name[0 .. total - 63] }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ label63, "bb@", name[0 .. total - 66] }));
    }
}

/// Every string literal of the Zig source `source`.
fn appendLiterals(arena: Allocator, list: *std.ArrayList([]const u8), source: [:0]const u8) !void {
    var tokenizer: std.zig.Tokenizer = .init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return,
            .string_literal => {
                const text = std.zig.string_literal.parseAlloc(arena, source[token.loc.start..token.loc.end]) catch continue;
                try list.append(arena, text);
            },
            else => {},
        }
    }
}

/// The inputs of the records of a vector file that are strings, with `hex`
/// decoded; the items of list inputs are not taken.
fn appendVectorInputs(arena: Allocator, list: *std.ArrayList([]const u8), json_text: []const u8) !void {
    const records = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
    for (records.array.items) |record| {
        const object = record.object;
        if (object.get("hex")) |hex| {
            const bytes = try arena.alloc(u8, hex.string.len / 2);
            _ = std.fmt.hexToBytes(bytes, hex.string) catch continue;
            try list.append(arena, bytes);
            continue;
        }
        switch (object.get("input") orelse continue) {
            .string => |s| try list.append(arena, s),
            else => {},
        }
    }
}

/// Each code point of `boundary_code_points` alone; when `around`, also
/// between letters, twice, around a letter, and in a password.
fn appendCodePoints(arena: Allocator, list: *std.ArrayList([]const u8), around: bool) !void {
    for (boundary_code_points) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        const c = buf[0..n];
        try list.append(arena, try arena.dupe(u8, c));
        if (!around) continue;
        try list.append(arena, try std.mem.concat(arena, u8, &.{ "a", c, "b" }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ c, c }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ c, "a", c }));
        try list.append(arena, try std.mem.concat(arena, u8, &.{ "Aa1!", c, "aaa" }));
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: regex_vectors <out.json>\n", .{});
        std.process.exit(2);
    }

    var shared: std.ArrayList([]const u8) = .empty;
    inline for (vector_files) |text| try appendVectorInputs(arena, &shared, text);
    for (common_edges) |s| try shared.append(arena, s);
    try appendCodePoints(arena, &shared, false);

    var per_family: [@typeInfo(Family).@"enum".field_names.len]std.ArrayList([]const u8) = @splat(.empty);
    inline for (comptime @typeInfo(Family).@"enum".field_names) |name| {
        const list = &per_family[@backingInt(@field(Family, name))];
        inline for (@field(family_sources, name)) |source| try appendLiterals(arena, list, source);
    }
    for (strings_edges) |s| try per_family[@backingInt(Family.strings)].append(arena, s);
    try appendCodePoints(arena, &per_family[@backingInt(Family.strings)], true);
    for (formats_edges) |s| try per_family[@backingInt(Family.formats)].append(arena, s);
    try appendLongNames(arena, &per_family[@backingInt(Family.formats)]);
    for (encodings_edges) |s| try per_family[@backingInt(Family.encodings)].append(arena, s);
    for (identifiers_edges) |s| try per_family[@backingInt(Family.identifiers)].append(arena, s);
    for (dates_edges) |s| try per_family[@backingInt(Family.dates)].append(arena, s);
    try appendDates(arena, &per_family[@backingInt(Family.dates)]);

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("[\n");
    var records: usize = 0;
    for (cases) |c| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const sources = [_][]const []const u8{ c.edges, per_family[@backingInt(c.family)].items, shared.items };
        for (sources) |inputs| {
            for (inputs) |input| {
                if (!std.unicode.utf8ValidateSlice(input)) continue;
                const entry = try seen.getOrPut(arena, input);
                if (entry.found_existing) continue;
                if (records > 0) try w.writeAll(",\n");
                try w.writeAll("{\"rule\":");
                try std.json.Stringify.encodeJsonString(c.label, .{}, w);
                try w.print(",\"schema\":{s},\"input\":", .{c.schema});
                try std.json.Stringify.encodeJsonString(input, .{}, w);
                try w.print(",\"pass\":{},\"exact\":{}}}", .{ c.passes(input), c.exact });
                records += 1;
            }
        }
    }
    try w.writeAll("\n]\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = out.written() });
}
