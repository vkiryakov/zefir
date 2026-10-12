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
const alphabet = "0123456789abcdefABCDEF" ++ "-_" ++ "ghxzGXZ" ++ " \x00\x7f\x80\xff";

/// The lengths the rules check for, give or take one byte.
const lengths = [_]usize{ 8, 20, 24, 32, 36, 40, 48, 64, 96, 128 };

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
