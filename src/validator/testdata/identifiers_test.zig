//! The identifier rules through `v.check` and `v.checkAll`: every string
//! type, `?T` and `??T`, the items of `v.each`, codes and messages,
//! `.withMessage` and its placeholders, and the predicates, which give the
//! rules' verdicts and never crash, whatever the input.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const S = []const u8;

/// One rule in use: a value it passes, a value it fails, and the code and
/// message of the failure.
fn Case(comptime rule: v.Rule, comptime good: S, comptime bad: S, comptime code: S, comptime message: S) type {
    return struct {
        const r = rule;
        const ok = good;
        const no = bad;
        /// The same values as sentinel-terminated strings.
        const ok_z: [:0]const u8 = std.fmt.comptimePrint("{s}", .{good});
        const no_z: [:0]const u8 = std.fmt.comptimePrint("{s}", .{bad});
        const c = code;
        const m = message;
    };
}

const cases = .{
    Case(v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "f81d4fae-7dec-11d0-a765-00a0c91e6bf", "validation.uuid", "must be a valid UUID"),
    Case(v.mongoId, "507f1f77bcf86cd799439011", "507f1f77bcf86cd79943901", "validation.mongo_id", "must be a valid MongoDB ObjectId"),
    Case(v.firebasePushId, "-JhLeOlGIEjaIOFHR0xd", "-JhLeOlGIEjaIOFHR0x.", "validation.firebase_push_id", "must be a valid Firebase push ID"),
    Case(v.hash(.sha256), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha256 hash"),
    Case(v.hash(.md5), "d41d8cd98f00b204e9800998ecf8427e", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "validation.hash", "must be a valid md5 hash"),
    Case(v.creditCard, "4111111111111111", "4111111111111112", "validation.credit_card", "must be a valid credit card number"),
    Case(v.isin, "US0378331005", "US0378331006", "validation.isin", "must be a valid ISIN"),
    Case(v.bic, "DEUTDEFF", "deutdeff", "validation.bic", "must be a valid BIC"),
    Case(v.iban, "DE89370400440532013000", "DE89370400440532013001", "validation.iban", "must be a valid IBAN"),
};

test "every string type: []const u8, []u8, [:0]const u8, [:0]u8" {
    inline for (cases) |c| {
        try h.expectPass(S, c.r, c.ok);
        try h.expectFail(S, c.r, c.no, c.c, c.m);
        var good = c.ok[0..c.ok.len].*;
        var bad = c.no[0..c.no.len].*;
        try h.expectPass([]u8, c.r, &good);
        try h.expectFail([]u8, c.r, &bad, c.c, c.m);
        try h.expectPass([:0]const u8, c.r, c.ok_z);
        try h.expectFail([:0]const u8, c.r, c.no_z, c.c, c.m);
        var good_z = c.ok_z[0..c.ok_z.len :0].*;
        var bad_z = c.no_z[0..c.no_z.len :0].*;
        try h.expectPass([:0]u8, c.r, &good_z);
        try h.expectFail([:0]u8, c.r, &bad_z, c.c, c.m);
    }
}

test "?T and ??T check the string inside; null skips the rule" {
    inline for (cases) |c| {
        try h.expectPass(?S, c.r, null);
        try h.expectPass(?S, c.r, c.ok);
        try h.expectFail(?S, c.r, c.no, c.c, c.m);
        try h.expectPass(??S, c.r, @as(?S, null));
        try h.expectFail(??[:0]const u8, c.r, c.no_z, c.c, c.m);
    }
}

test "inside each: slices and arrays of strings, null items skipped, the item's path" {
    inline for (cases) |c| {
        const List = h.One([]const S, v.each(c.r));
        try h.expectValid(&List{ .x = &.{ c.ok, c.ok } });
        try h.expectAt(&List{ .x = &.{ c.ok, c.no, c.no } }, c.c, c.m, "x[1]");
        try h.expectAll(&List{ .x = &.{ c.no, c.ok, c.no } }, &.{ .{ .code = c.c, .field = "x[0]" }, .{ .code = c.c, .field = "x[2]" } });
        const Optional = h.One([]const ?S, v.each(c.r));
        try h.expectAt(&Optional{ .x = &.{ null, c.ok, c.no } }, c.c, c.m, "x[2]");
        const Array = h.One([2][:0]const u8, v.each(c.r));
        try h.expectAt(&Array{ .x = .{ c.ok_z, c.no_z } }, c.c, c.m, "x[1]");
    }
}

test "the empty string and invalid UTF-8 fail under the rule's own code: there is no precondition" {
    inline for (cases) |c| {
        try testing.expectEqual(null, c.r.precondition);
        try h.expectFail(S, c.r, "", c.c, c.m);
        try h.expectFail(S, c.r, "\xff", c.c, c.m);
        try h.expectFail(S, c.r, c.ok[0 .. c.ok.len - 1] ++ "\xc3", c.c, c.m);
        try h.expectFail(S, c.r.withMessage("bad bytes"), "\xff\xfe", c.c, "bad bytes");
    }
}

test "withMessage keeps the code and replaces the message, in any language" {
    inline for (cases) |c| {
        const custom = comptime c.r.withMessage("неверное значение");
        try h.expectRule(custom, c.c, "неверное значение");
        try h.expectFail(S, custom, c.no, c.c, "неверное значение");
        try h.expectPass(S, custom, c.ok);
    }
}

test "hash shows its algorithm through {algorithm}" {
    inline for (comptime std.enums.values(v.HashAlgorithm)) |algorithm| {
        const rule = comptime v.hash(algorithm).withMessage("expected a {algorithm} digest ({{algorithm}})");
        try h.expectRule(rule, "validation.hash", "expected a " ++ @tagName(algorithm) ++ " digest ({algorithm})");
        try h.expectFail(S, rule, "xyz", "validation.hash", "expected a " ++ @tagName(algorithm) ++ " digest ({algorithm})");
    }
}

test "the selector of isHash may be known at run time only" {
    var algorithm: v.HashAlgorithm = .md5;
    _ = &algorithm;
    try testing.expect(v.isHash("d41d8cd98f00b204e9800998ecf8427e", algorithm));
    algorithm = .sha1;
    try testing.expect(!v.isHash("d41d8cd98f00b204e9800998ecf8427e", algorithm));
}

/// The examples of the SWIFT IBAN registry: 97 official ones and 24 of
/// countries outside it.
const registry_ibans = [_]S{
    "AL47212110090000000235698741",   "AD1200012030200359100100",          "AT611904300234573201",             "AZ21NABZ00000000137010001944",
    "BH67BMAG00001299123456",         "BE68539007547034",                  "BA391290079401028494",             "BR9700360305000010009795493P1",
    "VG96VPVG0000012345678901",       "BG80BNBG96611020345678",            "BI4210000100010000332045181",      "BY13NBRB3600900000002Z00AB00",
    "CG3930013020003710721836132",    "CR05015202001026284066",            "HR1210010051863000160",            "CY17002001280000001200527600",
    "CZ6508000000192000145399",       "DK5000400440116243",                "FO2000400440116243",               "GL2000400440116243",
    "DJ2100010000000154000100186",    "DO28BAGR00000001212453611324",      "SV62CENR00000000000000700025",     "EE382200221020145685",
    "FI2112345600000785",             "AX2112345600000785",                "FR1420041010050500013M02606",      "GF4120041010050500013M02606",
    "PF5720041010050500013M02606",    "TF2120041010050500013M02606",       "GP1120041010050500013M02606",      "MQ5120041010050500013M02606",
    "YT3120041010050500013M02606",    "NC8420041010050500013M02606",       "RE4220041010050500013M02606",      "BL6820041010050500013M02606",
    "MF8420041010050500013M02606",    "PM3620041010050500013M02606",       "WF9120041010050500013M02606",      "GE29NB0000000101904917",
    "DE89370400440532013000",         "GI75NWBK000000007099453",           "GR1601101250000000012300695",      "GT82TRAJ01020000001210029690",
    "HN88CABF00000000000250005469",   "HU42117730161111101800000000",      "IS140159260076545510730339",       "IQ98NBIQ850123456789012",
    "IE29AIBK93115212345678",         "IL620108000000099999999",           "IT60X0542811101000000123456",      "JO94CBJO0010000000000131000302",
    "KZ86125KZT5004100100",           "XK051212012345678906",              "KW81CBKU0000000000001234560101",   "LV80BANK0000435195001",
    "LB62099900000001001901229114",   "LI21088100002324013AA",             "LT121000011101001000",             "LU280019400644750000",
    "MK07250120000058984",            "MT84MALT011000012345MTLCAST001S",   "MR1300020001010000123456753",      "MU17BOMM0101101030300200000MUR",
    "MD24AG000225100013104168",       "MC5811222000010123456789030",       "ME25505000012345678951",           "NL91ABNA0417164300",
    "NI45BAPR00000013000003558124",   "NO9386011117947",                   "OM810180000001299123456",          "PK36SCBL0000001123456702",
    "PS92PALS000000000400123456702",  "PL61109010140000071219812874",      "PT50000201231234567890154",        "QA58DOHB00001234567890ABCDEFG",
    "RO49AAAA1B31007593840000",       "RU0304452522540817810538091310419", "LC55HEMM000100010012001200023015", "SM86U0322509800000000270100",
    "ST68000100010051845310112",      "SA0380000000608010167519",          "RS35260005601001611379",           "SC18SSCB11010000000000001497USD",
    "SK3112000000198742637541",       "SI56191000000123438",               "ES9121000418450200051332",         "SD2129010501234001",
    "SE4550000000058398257466",       "CH9300762011623852957",             "TL380080012345678910157",          "TN5910006035183598478831",
    "TR330006100519786457841326",     "AE070331234567890123456",           "GB29NWBK60161331926819",           "VA59001123000012345678",
    "YE15CBYE0001018861234567891234", "DZ3512341234123412341234",          "AO44123412341234123412341",        "BJ83A12312341234123412341234",
    "BF4512341234123412341234123",    "CM1512341234123412341234123",       "CV05123412341234123412341",        "CF4220001000010120069700160",
    "TD8960003000203710253860174",    "KM4600005000010010904400137",       "CI77A12312341234123412341234",     "EG380019000500000000263180002",
    "GQ7050002001003715228190196",    "GA2142001007341520000106963",       "GW04GW1430010181800637601",        "AA110011123Z5678",
    "IR081234123412341234123412",     "MG4012341234123412341234123",       "ML75A12312341234123412341234",     "MA64011519000001205000534921",
    "MZ97123412341234123412341",      "NE58NE0380100100130305000268",      "SN15A12312341234123412341234",     "TG53TG0090604310346500400070",
    "UA213996220000026007233566001",
};

test "iban passes every example of the IBAN registry, and no single wrong digit in them" {
    try testing.expectEqual(121, registry_ibans.len);
    var buf: [34]u8 = undefined;
    for (registry_ibans) |example| {
        try h.expectPass(S, v.iban, example);
        const s = buf[0..example.len];
        for (example, 0..) |c, i| {
            if (!std.ascii.isDigit(c)) continue;
            for ("0123456789") |d| {
                if (d == c) continue;
                @memcpy(s, example);
                s[i] = d;
                try testing.expect(!v.isIban(s));
            }
        }
    }
}

test "the Luhn check of creditCard and isin catches every single wrong digit" {
    var buf: [19]u8 = undefined;
    for ([_]S{ "4111111111111111", "378282246310005", "2200700000000009", "0000000000000", "4000000000000000006" }) |number| {
        try testing.expect(v.isCreditCard(number));
        const s = buf[0..number.len];
        for (0..number.len) |i| {
            for ("0123456789") |d| {
                if (d == number[i]) continue;
                @memcpy(s, number);
                s[i] = d;
                try testing.expect(!v.isCreditCard(s));
            }
        }
    }
    for ([_]S{ "US0378331005", "AU0000XVGZA3", "DE000BAY0017" }) |code| {
        try testing.expect(v.isIsin(code));
        const s = buf[0..code.len];
        for (code, 0..) |c, i| {
            if (!std.ascii.isDigit(c)) continue;
            for ("0123456789") |d| {
                if (d == c) continue;
                @memcpy(s, code);
                s[i] = d;
                try testing.expect(!v.isIsin(s));
            }
        }
    }
}

test "the first failing rule is the value's only violation" {
    try h.expectFail(S, .{ v.notEmpty, v.uuid }, "", "validation.not_empty", "must not be empty");
    try h.expectFail(S, .{ v.uuid, v.notEmpty }, "", "validation.uuid", "must be a valid UUID");
    try h.expectFail(S, .{ v.mongoId, v.noneOf(.{"000000000000000000000000"}) }, "000000000000000000000000", "validation.none_of", "must not be 000000000000000000000000");
    try h.expectFail(S, .{ v.hash(.md5), v.hash(.sha1) }, "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha1 hash");
}

// ------------------------------------------------------------------ random input

/// Random input per run of the test below, from each of its three sources.
const iterations = 20_000;

/// The bytes that the grammars of the rules care about, and some they reject.
const alphabet = "0123456789abcdefABCDEF" ++ "0123456789" ++ "GHKLMNPQRSTUVWXYZ" ++ "-_" ++ "ghxz" ++ " \x00\x7f\x80\xff";

/// The lengths the rules check for, give or take one byte.
const lengths = [_]usize{ 8, 11, 12, 13, 16, 19, 15, 20, 22, 24, 32, 34, 36, 40, 48, 64, 96, 128 };

/// Valid identifiers: edits of them reach checks that random bytes rarely
/// reach.
const seeds = [_]S{
    "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
    "507f1f77bcf86cd799439011",
    "-JhLeOlGIEjaIOFHR0xd",
    "cbf43926",
    "d41d8cd98f00b204e9800998ecf8427e",
    "da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "3293ac630c13f0245f92bbb1766e16167a4e58492dde73f3",
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b",
    "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
    "4111111111111111",
    "675900000000",
    "4000000000000000006",
    "US0378331005",
    "AU0000XVGZA3",
    "DEUTDEFF",
    "DEUTDEFF500",
    "DE89370400440532013000",
    "NO9386011117947",
    "XX621234567890ABCDEFGHIJ1234567890",
};

/// `rule` passes `s` exactly when `predicate` accepts it.
fn agree(comptime rule: v.Rule, comptime predicate: fn (S) bool, s: S) !void {
    const dto: h.One(S, rule) = .{ .x = s };
    var path_buf: [8]u8 = undefined;
    const passed = v.check(&dto, &path_buf) == null;
    if (passed != predicate(s)) {
        std.debug.print("{s} passes \"{f}\": {}, its predicate says {}\n", .{ comptime rule.call(), std.zig.fmtString(s), passed, !passed });
        return error.TestRuleDisagreesWithPredicate;
    }
}

/// `v.isHash(s, algorithm)` as a predicate of one argument.
fn isHashOf(comptime algorithm: v.HashAlgorithm) fn (S) bool {
    return struct {
        fn f(s: S) bool {
            return v.isHash(s, algorithm);
        }
    }.f;
}

/// Every predicate on `s`, each against its rule.
fn agreeAll(s: S) !void {
    try agree(v.uuid, v.isUuid, s);
    try agree(v.mongoId, v.isMongoId, s);
    try agree(v.firebasePushId, v.isFirebasePushId, s);
    try agree(v.creditCard, v.isCreditCard, s);
    try agree(v.isin, v.isIsin, s);
    try agree(v.bic, v.isBic, s);
    try agree(v.iban, v.isIban, s);
    inline for (comptime std.enums.values(v.HashAlgorithm)) |algorithm| try agree(v.hash(algorithm), isHashOf(algorithm), s);
}

/// Random bytes; or bytes of `alphabet` at one of `lengths`, sometimes one
/// byte off; or a seed with 1 to 3 random edits.
fn randomInput(random: std.Random, buf: []u8) S {
    switch (random.uintLessThan(u8, 3)) {
        0 => {
            const len = random.uintAtMost(usize, buf.len);
            random.bytes(buf[0..len]);
            return buf[0..len];
        },
        1 => {
            var len = lengths[random.uintLessThan(usize, lengths.len)];
            switch (random.uintLessThan(u8, 4)) {
                0 => len -= 1,
                1 => len += 1,
                else => {},
            }
            for (buf[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            return buf[0..len];
        },
        else => {
            const seed = seeds[random.uintLessThan(usize, seeds.len)];
            var len = seed.len;
            @memcpy(buf[0..len], seed);
            for (0..1 + random.uintLessThan(u8, 3)) |_| {
                switch (random.uintLessThan(u8, 4)) {
                    0 => buf[random.uintLessThan(usize, len)] = alphabet[random.uintLessThan(usize, alphabet.len)],
                    1 => buf[random.uintLessThan(usize, len)] = random.int(u8),
                    2 => if (len < buf.len) {
                        const at = random.uintAtMost(usize, len);
                        std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                        buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                        len += 1;
                    },
                    else => if (len > 1) {
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

test "random input never crashes a predicate, and each rule agrees with its predicate" {
    for (seeds) |seed| try agreeAll(seed);
    var prng = std.Random.DefaultPrng.init(0x1de7_7f1e);
    var buf: [160]u8 = undefined;
    for (0..3 * iterations) |_| try agreeAll(randomInput(prng.random(), &buf));
}
