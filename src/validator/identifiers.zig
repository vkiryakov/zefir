//! Identifier rules: `uuid`, `mongoId`, `firebasePushId` and `hash`, each
//! with its predicate (`v.isUuid`, `v.isMongoId`, `v.isFirebasePushId`,
//! `v.isHash`). The rules take strings only and read bytes, never code
//! points: a byte outside a rule's ASCII alphabet, invalid UTF-8 included,
//! fails under the rule's own code, and `""` fails every rule. Nothing is
//! trimmed, case-folded or normalized: a rule accepts the canonical form of
//! its identifier only. A predicate takes any input, allocates nothing and
//! reads each byte a bounded number of times.
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

/// The field-type check of every rule of this file.
fn stringFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (stringProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of a rule of this file on the unwrapped field type
/// `T`, or null: the field is a string. `[N]u8` gets the hint that it is no
/// string, and a slice or an array of strings the hint to use `v.each`.
fn stringProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    if (core.isString(T)) return null;
    return core.typeErrorText(rule, T, where, "a string", core.isString, null);
}

/// A rule of `kind` without parameters that passes the strings `predicate`
/// accepts.
fn predicateRule(comptime kind: core.Kind, comptime message: []const u8, comptime predicate: fn ([]const u8) bool) Rule {
    return core.define(kind, .{
        .message = message,
        .fits = stringFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(predicate(value.*));
            }
        }.eval,
    });
}

fn allHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ uuid, mongoId, firebasePushId

/// A UUID in the string form of RFC 9562: 36 bytes, `-` at indexes 8, 13, 18
/// and 23 and hex digits of any case elsewhere. The version and the variant
/// are not checked, so the Nil and Max UUIDs pass; braces, `urn:uuid:` and
/// the 32-digit form fail.
pub const uuid: Rule = predicateRule(.uuid, "must be a valid UUID", isUuid);

/// `s` passes `v.uuid`.
pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const ok = switch (i) {
            8, 13, 18, 23 => c == '-',
            else => std.ascii.isHex(c),
        };
        if (!ok) return false;
    }
    return true;
}

/// A MongoDB ObjectId as text: 24 hex digits of any case, as bson's
/// `ObjectId.isValid` takes a string; no `0x` or `0h` prefix.
pub const mongoId: Rule = predicateRule(.mongo_id, "must be a valid MongoDB ObjectId", isMongoId);

/// `s` passes `v.mongoId`.
pub fn isMongoId(s: []const u8) bool {
    return s.len == 24 and allHex(s);
}

/// A Firebase push ID: 20 bytes of the alphabet `-`, `0-9`, `A-Z`, `_`,
/// `a-z`. The timestamp in its first 8 characters is not decoded.
pub const firebasePushId: Rule = predicateRule(.firebase_push_id, "must be a valid Firebase push ID", isFirebasePushId);

/// `s` passes `v.firebasePushId`.
pub fn isFirebasePushId(s: []const u8) bool {
    if (s.len != 20) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

// ------------------------------------------------------------------ hash

/// The algorithms of `v.hash` and `v.isHash`, in class-validator's order. A
/// later release may add tags, which breaks an exhaustive `switch` on this
/// enum; it never removes or renames one.
pub const HashAlgorithm = enum { md4, md5, sha1, sha256, sha384, sha512, ripemd128, ripemd160, tiger128, tiger160, tiger192, crc32, crc32b };

/// The number of hex digits of a digest of `algorithm`.
fn hexLength(algorithm: HashAlgorithm) usize {
    return switch (algorithm) {
        .crc32, .crc32b => 8,
        .md4, .md5, .ripemd128, .tiger128 => 32,
        .sha1, .ripemd160, .tiger160 => 40,
        .tiger192 => 48,
        .sha256 => 64,
        .sha384 => 96,
        .sha512 => 128,
    };
}

/// A hex digest of `algorithm`: exactly its number of hex digits (8 for
/// `crc32` and `crc32b`; 32 for `md4`, `md5`, `ripemd128` and `tiger128`; 40
/// for `sha1`, `ripemd160` and `tiger160`; 48 for `tiger192`; 64, 96 and 128
/// for `sha256`, `sha384` and `sha512`), any case, no `0x` prefix. Nothing is
/// hashed: digests of the same length, such as md4 and md5, look alike.
/// `{algorithm}` is the tag's name: "must be a valid sha256 hash".
pub fn hash(comptime algorithm: HashAlgorithm) Rule {
    return core.define(.hash, .{
        .message = "must be a valid " ++ @tagName(algorithm) ++ " hash",
        .args = core.renderArg(algorithm),
        .params = &.{core.param("algorithm", algorithm)},
        .fits = stringFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isHash(value.*, algorithm));
            }
        }.eval,
    });
}

/// `s` passes `v.hash(algorithm)`. The algorithm may be known at run time
/// only.
pub fn isHash(s: []const u8, algorithm: HashAlgorithm) bool {
    return s.len == hexLength(algorithm) and allHex(s);
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `hash must be called, e.g. v.hash(.sha256)`.
pub const call_examples = .{ .hash = ".sha256" };

// ------------------------------------------------------------------ tests

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// The declaration error of `rule` on a field whose unwrapped type is `T`,
/// or null.
fn typeText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return stringProblem(&rule, T, test_where);
}

/// `predicate` accepts every string of `good` and rejects every one of `bad`.
fn expectPredicate(predicate: fn ([]const u8) bool, good: []const []const u8, bad: []const []const u8) !void {
    for (good) |s| {
        if (!predicate(s)) {
            std.debug.print("expected a pass: \"{f}\"\n", .{std.zig.fmtString(s)});
            return error.TestExpectedPass;
        }
    }
    for (bad) |s| {
        if (predicate(s)) {
            std.debug.print("expected a failure: \"{f}\"\n", .{std.zig.fmtString(s)});
            return error.TestExpectedFailure;
        }
    }
}

test "the rules without parameters have their documented codes and messages and no precondition" {
    const t = std.testing;
    const rules = .{
        .{ uuid, core.Kind.uuid, "validation.uuid", "must be a valid UUID" },
        .{ mongoId, core.Kind.mongo_id, "validation.mongo_id", "must be a valid MongoDB ObjectId" },
        .{ firebasePushId, core.Kind.firebase_push_id, "validation.firebase_push_id", "must be a valid Firebase push ID" },
    };
    inline for (rules) |row| {
        try t.expectEqual(row[1], row[0].kind);
        try t.expectEqualStrings(row[2], row[0].code);
        try t.expectEqualStrings(row[3], row[0].message);
        try t.expectEqual(null, row[0].args);
        try t.expectEqual(0, row[0].params.len);
        try t.expectEqual(null, row[0].precondition);
    }
    try t.expectEqualStrings("firebasePushId", comptime firebasePushId.call());
    try t.expectEqualStrings("firebase_push_id", comptime firebasePushId.label());
}

test "hash names its algorithm in the message and in the placeholder {algorithm}" {
    const t = std.testing;
    const sha = hash(.sha256);
    try t.expectEqual(core.Kind.hash, sha.kind);
    try t.expectEqualStrings("validation.hash", sha.code);
    try t.expectEqualStrings("must be a valid sha256 hash", sha.message);
    try t.expectEqualStrings(".sha256", sha.args.?);
    try t.expectEqual(1, sha.params.len);
    try t.expectEqualStrings("algorithm", sha.params[0].name);
    try t.expectEqualStrings("sha256", sha.params[0].text);
    try t.expectEqualStrings("sha256", sha.params[0].value.tag);
    try t.expect(sha.params[0].placeholder);
    try t.expectEqual(null, sha.precondition);
    try t.expectEqualStrings("hash(.sha256)", comptime sha.call());
    try t.expectEqualStrings("hash(.crc32b)", comptime hash(.crc32b).label());
    inline for (comptime std.enums.values(HashAlgorithm)) |algorithm| {
        try t.expectEqualStrings("must be a valid " ++ @tagName(algorithm) ++ " hash", hash(algorithm).message);
    }
}

test "the rules take strings only: [N]u8 and lists of strings get hints, other types none" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const u8_array = "; [N]u8 is an array of numbers, not a string: use []const u8";
    try expect(head ++ "uuid expects a string, field is u128", comptime typeText(uuid, u128).?);
    try expect(head ++ "uuid expects a string, field is [16]u8" ++ u8_array, comptime typeText(uuid, [16]u8).?);
    try expect(head ++ "uuid expects a string, field is []const []const u8; use v.each(v.uuid)", comptime typeText(uuid, []const []const u8).?);
    try expect(head ++ "mongo_id expects a string, field is u96", comptime typeText(mongoId, u96).?);
    try expect(head ++ "mongo_id expects a string, field is [12]u8" ++ u8_array, comptime typeText(mongoId, [12]u8).?);
    try expect(head ++ "mongo_id expects a string, field is []const []const u8; use v.each(v.mongoId)", comptime typeText(mongoId, []const []const u8).?);
    try expect(head ++ "firebase_push_id expects a string, field is u64", comptime typeText(firebasePushId, u64).?);
    try expect(head ++ "firebase_push_id expects a string, field is [20:0]u8" ++ u8_array, comptime typeText(firebasePushId, [20:0]u8).?);
    try expect(head ++ "firebase_push_id expects a string, field is [2]?[]const u8; use v.each(v.firebasePushId)", comptime typeText(firebasePushId, [2]?[]const u8).?);
    try expect(head ++ "hash expects a string, field is u256", comptime typeText(hash(.sha256), u256).?);
    try expect(head ++ "hash expects a string, field is [32]u8" ++ u8_array, comptime typeText(hash(.sha256), [32]u8).?);
    try expect(head ++ "hash expects a string, field is []const []const u8; use v.each(v.hash(.sha256))", comptime typeText(hash(.sha256), []const []const u8).?);
    try expect(
        head ++ "uuid expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeText(uuid, []volatile u8).?,
    );
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expectEqual(null, comptime typeText(uuid, T));
        try std.testing.expectEqual(null, comptime typeText(hash(.md5), T));
    }
}

test "an uncalled hash shows the call with .sha256; isHash in place of a rule names that call" {
    const expect = std.testing.expectEqualStrings;
    try expect("hash must be called, e.g. v.hash(.sha256)", comptime core.hints.mustBeCalled("hash", @TypeOf(hash)));
    try expect("expected a rule, got the predicate isHash; use the rule v.hash(.sha256)", comptime core.hints.predicateAsRule("isHash", "hash", @TypeOf(hash)));
    try expect("expected a rule, got the predicate isUuid; use the rule v.uuid", comptime core.hints.predicateAsRule("isUuid", "uuid", Rule));
}

test "the rules pass what their predicates accept" {
    try expectOutcome(.pass, uuid, @as([]const u8, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"));
    try expectOutcome(.fail, uuid, @as([]const u8, "f81d4fae7dec11d0a76500a0c91e6bf6"));
    var buffer = "507f1f77bcf86cd799439011".*;
    try expectOutcome(.pass, mongoId, @as([]u8, &buffer));
    try expectOutcome(.fail, mongoId, @as([:0]const u8, "507f1f77bcf86cd79943901"));
    try expectOutcome(.pass, firebasePushId, @as([:0]const u8, "-JhLeOlGIEjaIOFHR0xd"));
    try expectOutcome(.pass, hash(.md5), @as([]const u8, "d41d8cd98f00b204e9800998ecf8427e"));
    try expectOutcome(.fail, hash(.sha256), @as([]const u8, "d41d8cd98f00b204e9800998ecf8427e"));
}

test "uuid: 8-4-4-4-12 hex digits of any case, version and variant unchecked" {
    try expectPredicate(isUuid, &.{
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        "f81D4fae-7DEC-11d0-A765-00a0C91e6bf6",
        "017f22e2-79b0-7cc3-98c4-dc0c0c07398f",
        "00000000-0000-0000-0000-000000000000",
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "00000000-0000-0000-c000-000000000046",
        "919108f7-52d1-3320-5bac-f847db4148a8",
    }, &.{
        "",
        "f81d4fae7dec11d0a76500a0c91e6bf6",
        "{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
        "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf60",
        "f81d4fa-e7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765_00a0c91e6bf6",
        "g81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        " f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6\n",
        "f81d4fae\u{2013}7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0-c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf\xff",
    });
}

test "mongoId: 24 hex digits of any case, no prefix" {
    try expectPredicate(isMongoId, &.{
        "507f1f77bcf86cd799439011",
        "507F1F77BCF86CD799439011",
        "000000000000000000000000",
    }, &.{
        "",
        "507f1f77bcf86cd79943901",
        "507f1f77bcf86cd7994390111",
        "507f1f77bcf86cd79943901g",
        "0xaaaaaaaaaaaaaaaaaaaaaa",
        "0haaaaaaaaaaaaaaaaaaaaaa",
        " 07f1f77bcf86cd799439011",
        "507f1f77-bcf8-6cd7-9943-9011",
        "ObjectId(\"507f1f77bcf86cd799439011\")",
        "507f1f77bcf86cd79943901\u{ff11}",
    });
}

test "firebasePushId: 20 bytes of -0-9A-Z_a-z" {
    try expectPredicate(isFirebasePushId, &.{
        "-JhLeOlGIEjaIOFHR0xd",
        "_JhLeOlGIEjaIOFHR0xd",
        "--------------------",
        "abcdefghijklmnopqrst",
    }, &.{
        "",
        "-JhLeOlGIEjaIOFHR0x",
        "-JhLeOlGIEjaIOFHR0xdd",
        "-JhLeOlGIEjaIOFHR0x.",
        "-JhLeOlGIEjaIOFHR0x+",
        "-JhLeOlGIEjaIOFHR0x ",
        "-JhLeOlGIEjaIOFHR0x\u{e9}",
    });
}

test "hash: each algorithm takes exactly its number of hex digits, any case" {
    const t = std.testing;
    const lengths = .{ .{ .md4, 32 }, .{ .md5, 32 }, .{ .sha1, 40 }, .{ .sha256, 64 }, .{ .sha384, 96 }, .{ .sha512, 128 }, .{ .ripemd128, 32 }, .{ .ripemd160, 40 }, .{ .tiger128, 32 }, .{ .tiger160, 40 }, .{ .tiger192, 48 }, .{ .crc32, 8 }, .{ .crc32b, 8 } };
    try t.expectEqual(std.enums.values(HashAlgorithm).len, lengths.len);
    inline for (lengths) |row| {
        const algorithm: HashAlgorithm = row[0];
        const n = row[1];
        try t.expect(isHash(&@as([n]u8, @splat('F')), algorithm));
        try t.expect(isHash(&@as([n]u8, @splat('9')), algorithm));
        try t.expect(!isHash(&@as([n - 1]u8, @splat('a')), algorithm));
        try t.expect(!isHash(&@as([n + 1]u8, @splat('a')), algorithm));
        try t.expect(!isHash("0x" ++ &@as([n - 2]u8, @splat('a')), algorithm));
        try t.expect(!isHash("g" ++ &@as([n - 1]u8, @splat('a')), algorithm));
    }
    try t.expect(isHash("d41d8cd98f00b204e9800998ecf8427e", .md5));
    try t.expect(isHash("D41D8CD98F00B204E9800998ECF8427E", .md5));
    try t.expect(isHash("31d6cfe0d16ae931b73c59d7e0c089c0", .md4));
    try t.expect(isHash("da39a3ee5e6b4b0d3255bfef95601890afd80709", .sha1));
    try t.expect(isHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", .sha256));
    try t.expect(isHash("38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b", .sha384));
    try t.expect(isHash("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e", .sha512));
    try t.expect(isHash("31d6cfe0d16ae931b73c59d7e0c089c0", .ripemd128));
    try t.expect(isHash("9c1185a5c5e9fc54612808977ee8f548b2258d31", .ripemd160));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e1616", .tiger128));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e16167a4e5849", .tiger160));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e16167a4e58492dde73f3", .tiger192));
    try t.expect(isHash("cbf43926", .crc32) and isHash("CBF43926", .crc32b));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427e", .sha256));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427", .md5));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427g", .md5));
    try t.expect(!isHash("0xd41d8cd98f00b204e9800998ecf842", .md5));
    try t.expect(!isHash(" da39a3ee5e6b4b0d3255bfef95601890afd8070", .sha1));
    try t.expect(!isHash("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", .sha256));
    try t.expect(!isHash("", .crc32));
}
