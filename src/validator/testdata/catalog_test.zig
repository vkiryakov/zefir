//! Catalog conformance of the shipped rules: each rule is exported under its
//! catalog name in its catalog form (a rule value or a constructor) with the
//! catalog code and every variant of its catalog default message, which is
//! also what the catalog's text of the message gives through `withMessage`;
//! each placeholder shows its parameter through `withMessage`; a rule with a
//! precondition reports the catalog precondition code and message on every
//! field type it applies to, also under `withMessage`; the module exports
//! exactly its public names and the catalog predicates of the shipped rules,
//! and every rule it exports has a test here; and the limits have their
//! catalog values.
//!
//! In the repository, this file is the source of truth for the contract of
//! the shipped rules. It is generated from the rule catalog, which the
//! maintainer keeps outside the repository together with its generator
//! script: the maintainer regenerates the file when preparing a rule PR. A
//! contributor without the catalog edits it by hand, in the same change as
//! the rule. Any change to this file changes the contract of a rule.

const std = @import("std");
const v = @import("validator");
const testing = std.testing;

/// A DTO with one field `x` of type `T` and the given rules.
fn One(comptime T: type, comptime rules: anytype) type {
    return struct {
        x: T,
        pub const field_rules = .{ .x = rules };
    };
}

/// `v.check` on `.{ .x = value }` reports exactly this violation.
fn expectViolation(comptime T: type, comptime rules: anytype, value: T, code: []const u8, message: []const u8, field: []const u8) !void {
    const dto: One(T, rules) = .{ .x = value };
    var path_buf: [64]u8 = undefined;
    const violation = v.check(&dto, &path_buf) orelse return error.TestExpectedViolation;
    try testing.expectEqualStrings(code, violation.code);
    try testing.expectEqualStrings(message, violation.message);
    try testing.expectEqualStrings(field, violation.field orelse return error.TestExpectedField);
}

/// `v.check` on `.{ .x = value }` reports nothing.
fn expectNoViolation(comptime T: type, comptime rules: anytype, value: T) !void {
    const dto: One(T, rules) = .{ .x = value };
    var path_buf: [64]u8 = undefined;
    if (v.check(&dto, &path_buf)) |violation| {
        std.debug.print("unexpected violation {s}: {s}\n", .{ violation.code, violation.message });
        return error.TestUnexpectedViolation;
    }
}

/// `rule` has this code and default message, and the catalog's `template` of
/// the message gives the same text through `withMessage`: the default message
/// is the template with the rule's placeholders filled in.
fn expectRule(comptime rule: v.Rule, code: []const u8, message: []const u8, comptime template: []const u8) !void {
    try testing.expectEqualStrings(code, rule.code);
    try testing.expectEqualStrings(message, rule.message);
    try testing.expectEqualStrings(message, rule.withMessage(template).message);
}

/// The placeholder `{name}` of `rule` shows `text` through `withMessage`.
fn expectPlaceholder(comptime rule: v.Rule, comptime placeholder: []const u8, text: []const u8) !void {
    try testing.expectEqualStrings(text, rule.withMessage(placeholder).message);
}

/// A string parameter whose default message would be longer than 512 bytes.
const long_string = &@as([600]u8, @splat('x'));

/// Listed values whose default message would be longer than 512 bytes.
const long_values = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

test "equals is a rule constructor with code validation.equals and message \"must be equal to {expected}\", or \"must be equal to the expected value\" when that would be longer than 512 bytes; placeholder {expected}" {
    try testing.expect(@hasDecl(v, "equals"));
    try testing.expect(@typeInfo(@TypeOf(v.equals)).@"fn".return_type == v.Rule);
    try expectRule(v.equals(true), "validation.equals", "must be equal to true", "must be equal to {expected}");
    try expectPlaceholder(v.equals(true), "{expected}", "true");
    try expectViolation(bool, v.equals(true), false, "validation.equals", "must be equal to true", "x");
    try expectRule(v.equals(long_string), "validation.equals", "must be equal to the expected value", "must be equal to the expected value");
    try expectViolation([]const u8, v.equals(long_string), "x", "validation.equals", "must be equal to the expected value", "x");
    try expectNoViolation(bool, v.equals(true), true);
}

test "notEquals is a rule constructor with code validation.not_equals and message \"must not be equal to {forbidden}\", or \"must not be equal to the forbidden value\" when that would be longer than 512 bytes; placeholder {forbidden}" {
    try testing.expect(@hasDecl(v, "notEquals"));
    try testing.expect(@typeInfo(@TypeOf(v.notEquals)).@"fn".return_type == v.Rule);
    try expectRule(v.notEquals(0), "validation.not_equals", "must not be equal to 0", "must not be equal to {forbidden}");
    try expectPlaceholder(v.notEquals(0), "{forbidden}", "0");
    try expectViolation(i32, v.notEquals(0), 0, "validation.not_equals", "must not be equal to 0", "x");
    try expectRule(v.notEquals(long_string), "validation.not_equals", "must not be equal to the forbidden value", "must not be equal to the forbidden value");
    try expectViolation([]const u8, v.notEquals(long_string), long_string, "validation.not_equals", "must not be equal to the forbidden value", "x");
    try expectNoViolation(i32, v.notEquals(0), 1);
}

test "oneOf is a rule constructor with code validation.one_of and message \"must be one of: {values}\", \"must be {values}\" for one value, or \"must be one of the allowed values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "oneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.oneOf)).@"fn".return_type == v.Rule);
    try expectRule(v.oneOf(.{ "a", "b" }), "validation.one_of", "must be one of: a, b", "must be one of: {values}");
    try expectPlaceholder(v.oneOf(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const u8, v.oneOf(.{ "a", "b" }), "c", "validation.one_of", "must be one of: a, b", "x");
    try expectRule(v.oneOf(.{"a"}), "validation.one_of", "must be a", "must be {values}");
    try expectPlaceholder(v.oneOf(.{"a"}), "{values}", "a");
    try expectViolation([]const u8, v.oneOf(.{"a"}), "c", "validation.one_of", "must be a", "x");
    try expectRule(v.oneOf(long_values), "validation.one_of", "must be one of the allowed values", "must be one of the allowed values");
    try expectViolation([]const u8, v.oneOf(long_values), "c", "validation.one_of", "must be one of the allowed values", "x");
    try expectNoViolation([]const u8, v.oneOf(.{ "a", "b" }), "b");
}

test "noneOf is a rule constructor with code validation.none_of and message \"must not be one of: {values}\", \"must not be {values}\" for one value, or \"must not be one of the forbidden values\" when that would be longer than 512 bytes; placeholder {values}" {
    try testing.expect(@hasDecl(v, "noneOf"));
    try testing.expect(@typeInfo(@TypeOf(v.noneOf)).@"fn".return_type == v.Rule);
    try expectRule(v.noneOf(.{ "a", "b" }), "validation.none_of", "must not be one of: a, b", "must not be one of: {values}");
    try expectPlaceholder(v.noneOf(.{ "a", "b" }), "{values}", "a, b");
    try expectViolation([]const u8, v.noneOf(.{ "a", "b" }), "b", "validation.none_of", "must not be one of: a, b", "x");
    try expectRule(v.noneOf(.{"a"}), "validation.none_of", "must not be a", "must not be {values}");
    try expectPlaceholder(v.noneOf(.{"a"}), "{values}", "a");
    try expectViolation([]const u8, v.noneOf(.{"a"}), "a", "validation.none_of", "must not be a", "x");
    try expectRule(v.noneOf(long_values), "validation.none_of", "must not be one of the forbidden values", "must not be one of the forbidden values");
    try expectViolation([]const u8, v.noneOf(long_values), long_values[0], "validation.none_of", "must not be one of the forbidden values", "x");
    try expectNoViolation([]const u8, v.noneOf(.{ "a", "b" }), "c");
}

test "empty is a rule value with code validation.empty and message \"must be empty\"" {
    try testing.expect(@hasDecl(v, "empty"));
    try testing.expect(@TypeOf(v.empty) == v.Rule);
    try expectRule(v.empty, "validation.empty", "must be empty", "must be empty");
    try expectViolation([]const u8, v.empty, "a", "validation.empty", "must be empty", "x");
    try expectNoViolation([]const u8, v.empty, "");
}

test "notEmpty is a rule value with code validation.not_empty and message \"must not be empty\"" {
    try testing.expect(@hasDecl(v, "notEmpty"));
    try testing.expect(@TypeOf(v.notEmpty) == v.Rule);
    try expectRule(v.notEmpty, "validation.not_empty", "must not be empty", "must not be empty");
    try expectViolation([]const u8, v.notEmpty, "", "validation.not_empty", "must not be empty", "x");
    try expectNoViolation([]const u8, v.notEmpty, "a");
}

test "min is a rule constructor with code validation.min and message \"must be at least {min}\"; placeholder {min}" {
    try testing.expect(@hasDecl(v, "min"));
    try testing.expect(@typeInfo(@TypeOf(v.min)).@"fn".return_type == v.Rule);
    try expectRule(v.min(0), "validation.min", "must be at least 0", "must be at least {min}");
    try expectPlaceholder(v.min(0), "{min}", "0");
    try expectViolation(i32, v.min(0), -1, "validation.min", "must be at least 0", "x");
    try expectNoViolation(i32, v.min(0), 0);
}

test "max is a rule constructor with code validation.max and message \"must be at most {max}\"; placeholder {max}" {
    try testing.expect(@hasDecl(v, "max"));
    try testing.expect(@typeInfo(@TypeOf(v.max)).@"fn".return_type == v.Rule);
    try expectRule(v.max(100), "validation.max", "must be at most 100", "must be at most {max}");
    try expectPlaceholder(v.max(100), "{max}", "100");
    try expectViolation(i32, v.max(100), 101, "validation.max", "must be at most 100", "x");
    try expectNoViolation(i32, v.max(100), 100);
}

test "range is a rule constructor with code validation.range and message \"must be from {min} to {max}\", or \"must be {min}\" when min = max; placeholders {min}, {max}" {
    try testing.expect(@hasDecl(v, "range"));
    try testing.expect(@typeInfo(@TypeOf(v.range)).@"fn".return_type == v.Rule);
    try expectRule(v.range(1, 100), "validation.range", "must be from 1 to 100", "must be from {min} to {max}");
    try expectPlaceholder(v.range(1, 100), "{min}", "1");
    try expectPlaceholder(v.range(1, 100), "{max}", "100");
    try expectViolation(i32, v.range(1, 100), 0, "validation.range", "must be from 1 to 100", "x");
    try expectRule(v.range(1, 1), "validation.range", "must be 1", "must be {min}");
    try expectPlaceholder(v.range(1, 1), "{min}", "1");
    try expectViolation(i32, v.range(1, 1), 2, "validation.range", "must be 1", "x");
    try expectNoViolation(i32, v.range(1, 100), 1);
}

test "positive is a rule value with code validation.positive and message \"must be greater than 0\"" {
    try testing.expect(@hasDecl(v, "positive"));
    try testing.expect(@TypeOf(v.positive) == v.Rule);
    try expectRule(v.positive, "validation.positive", "must be greater than 0", "must be greater than 0");
    try expectViolation(i32, v.positive, 0, "validation.positive", "must be greater than 0", "x");
    try expectNoViolation(i32, v.positive, 1);
}

test "nonNegative is a rule value with code validation.non_negative and message \"must not be negative\"" {
    try testing.expect(@hasDecl(v, "nonNegative"));
    try testing.expect(@TypeOf(v.nonNegative) == v.Rule);
    try expectRule(v.nonNegative, "validation.non_negative", "must not be negative", "must not be negative");
    try expectViolation(i32, v.nonNegative, -1, "validation.non_negative", "must not be negative", "x");
    try expectNoViolation(i32, v.nonNegative, 0);
}

test "negative is a rule value with code validation.negative and message \"must be less than 0\"" {
    try testing.expect(@hasDecl(v, "negative"));
    try testing.expect(@TypeOf(v.negative) == v.Rule);
    try expectRule(v.negative, "validation.negative", "must be less than 0", "must be less than 0");
    try expectViolation(i32, v.negative, 0, "validation.negative", "must be less than 0", "x");
    try expectNoViolation(i32, v.negative, -1);
}

test "nonPositive is a rule value with code validation.non_positive and message \"must not be positive\"" {
    try testing.expect(@hasDecl(v, "nonPositive"));
    try testing.expect(@TypeOf(v.nonPositive) == v.Rule);
    try expectRule(v.nonPositive, "validation.non_positive", "must not be positive", "must not be positive");
    try expectViolation(i32, v.nonPositive, 1, "validation.non_positive", "must not be positive", "x");
    try expectNoViolation(i32, v.nonPositive, 0);
}

test "divisibleBy is a rule constructor with code validation.divisible_by and message \"must be divisible by {divisor}\"; placeholder {divisor}" {
    try testing.expect(@hasDecl(v, "divisibleBy"));
    try testing.expect(@typeInfo(@TypeOf(v.divisibleBy)).@"fn".return_type == v.Rule);
    try expectRule(v.divisibleBy(2), "validation.divisible_by", "must be divisible by 2", "must be divisible by {divisor}");
    try expectPlaceholder(v.divisibleBy(2), "{divisor}", "2");
    try expectViolation(i32, v.divisibleBy(2), 3, "validation.divisible_by", "must be divisible by 2", "x");
    try expectNoViolation(i32, v.divisibleBy(2), 4);
}

test "finite is a rule value with code validation.finite and message \"must be a finite number\"" {
    try testing.expect(@hasDecl(v, "finite"));
    try testing.expect(@TypeOf(v.finite) == v.Rule);
    try expectRule(v.finite, "validation.finite", "must be a finite number", "must be a finite number");
    try expectViolation(f64, v.finite, std.math.inf(f64), "validation.finite", "must be a finite number", "x");
    try expectNoViolation(f64, v.finite, 0);
}

test "uuid is a rule value with code validation.uuid and message \"must be a valid UUID\"; no precondition" {
    try testing.expect(@hasDecl(v, "uuid"));
    try testing.expect(@TypeOf(v.uuid) == v.Rule);
    try expectRule(v.uuid, "validation.uuid", "must be a valid UUID", "must be a valid UUID");
    try expectViolation([]const u8, v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf", "validation.uuid", "must be a valid UUID", "x");
    try expectViolation([]const u8, v.uuid.withMessage("another message"), "\xff", "validation.uuid", "another message", "x");
    try expectNoViolation([]const u8, v.uuid, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
}

test "mongoId is a rule value with code validation.mongo_id and message \"must be a valid MongoDB ObjectId\"; no precondition" {
    try testing.expect(@hasDecl(v, "mongoId"));
    try testing.expect(@TypeOf(v.mongoId) == v.Rule);
    try expectRule(v.mongoId, "validation.mongo_id", "must be a valid MongoDB ObjectId", "must be a valid MongoDB ObjectId");
    try expectViolation([]const u8, v.mongoId, "0xaaaaaaaaaaaaaaaaaaaaaa", "validation.mongo_id", "must be a valid MongoDB ObjectId", "x");
    try expectViolation([]const u8, v.mongoId.withMessage("another message"), "\xff", "validation.mongo_id", "another message", "x");
    try expectNoViolation([]const u8, v.mongoId, "507f1f77bcf86cd799439011");
}

test "firebasePushId is a rule value with code validation.firebase_push_id and message \"must be a valid Firebase push ID\"; no precondition" {
    try testing.expect(@hasDecl(v, "firebasePushId"));
    try testing.expect(@TypeOf(v.firebasePushId) == v.Rule);
    try expectRule(v.firebasePushId, "validation.firebase_push_id", "must be a valid Firebase push ID", "must be a valid Firebase push ID");
    try expectViolation([]const u8, v.firebasePushId, "-JhLeOlGIEjaIOFHR0x", "validation.firebase_push_id", "must be a valid Firebase push ID", "x");
    try expectViolation([]const u8, v.firebasePushId.withMessage("another message"), "\xff", "validation.firebase_push_id", "another message", "x");
    try expectNoViolation([]const u8, v.firebasePushId, "-JhLeOlGIEjaIOFHR0xd");
}

test "hash is a rule constructor with code validation.hash and message \"must be a valid {algorithm} hash\" for each of its 13 algorithms; placeholder {algorithm}; no precondition" {
    try testing.expect(@hasDecl(v, "hash"));
    try testing.expect(@typeInfo(@TypeOf(v.hash)).@"fn".return_type == v.Rule);
    const algorithms = [_][]const u8{ "md4", "md5", "sha1", "sha256", "sha384", "sha512", "ripemd128", "ripemd160", "tiger128", "tiger160", "tiger192", "crc32", "crc32b" };
    try testing.expect(@typeInfo(v.HashAlgorithm).@"enum".mode == .exhaustive);
    try testing.expectEqual(algorithms.len, comptime std.meta.fieldNames(v.HashAlgorithm).len);
    inline for (algorithms, comptime std.meta.fieldNames(v.HashAlgorithm)) |name, tag| {
        try testing.expectEqualStrings(name, tag);
        const rule = v.hash(@field(v.HashAlgorithm, name));
        try expectRule(rule, "validation.hash", "must be a valid " ++ name ++ " hash", "must be a valid {algorithm} hash");
        try expectPlaceholder(rule, "{algorithm}", name);
    }
    try expectViolation([]const u8, v.hash(.sha256), "d41d8cd98f00b204e9800998ecf8427e", "validation.hash", "must be a valid sha256 hash", "x");
    try expectViolation([]const u8, v.hash(.md5).withMessage("another message"), "\xff", "validation.hash", "another message", "x");
    try expectNoViolation([]const u8, v.hash(.md5), "d41d8cd98f00b204e9800998ecf8427e");
}

test "creditCard is a rule value with code validation.credit_card and message \"must be a valid credit card number\"; no precondition" {
    try testing.expect(@hasDecl(v, "creditCard"));
    try testing.expect(@TypeOf(v.creditCard) == v.Rule);
    try expectRule(v.creditCard, "validation.credit_card", "must be a valid credit card number", "must be a valid credit card number");
    try expectViolation([]const u8, v.creditCard, "4111111111111112", "validation.credit_card", "must be a valid credit card number", "x");
    try expectViolation([]const u8, v.creditCard.withMessage("another message"), "\xff", "validation.credit_card", "another message", "x");
    try expectNoViolation([]const u8, v.creditCard, "4111111111111111");
}

test "isbn is a rule value with code validation.isbn and message \"must be a valid ISBN\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn"));
    try testing.expect(@TypeOf(v.isbn) == v.Rule);
    try expectRule(v.isbn, "validation.isbn", "must be a valid ISBN", "must be a valid ISBN");
    try expectViolation([]const u8, v.isbn, "978-0-306-40615-7", "validation.isbn", "must be a valid ISBN", "x");
    try expectViolation([]const u8, v.isbn.withMessage("another message"), "\xff", "validation.isbn", "another message", "x");
    try expectNoViolation([]const u8, v.isbn, "9780306406157");
}

test "isbn10 is a rule value with code validation.isbn10 and message \"must be a valid ISBN-10\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn10"));
    try testing.expect(@TypeOf(v.isbn10) == v.Rule);
    try expectRule(v.isbn10, "validation.isbn10", "must be a valid ISBN-10", "must be a valid ISBN-10");
    try expectViolation([]const u8, v.isbn10, "9780306406157", "validation.isbn10", "must be a valid ISBN-10", "x");
    try expectViolation([]const u8, v.isbn10.withMessage("another message"), "\xff", "validation.isbn10", "another message", "x");
    try expectNoViolation([]const u8, v.isbn10, "0306406152");
}

test "isbn13 is a rule value with code validation.isbn13 and message \"must be a valid ISBN-13\"; no precondition" {
    try testing.expect(@hasDecl(v, "isbn13"));
    try testing.expect(@TypeOf(v.isbn13) == v.Rule);
    try expectRule(v.isbn13, "validation.isbn13", "must be a valid ISBN-13", "must be a valid ISBN-13");
    try expectViolation([]const u8, v.isbn13, "0306406152", "validation.isbn13", "must be a valid ISBN-13", "x");
    try expectViolation([]const u8, v.isbn13.withMessage("another message"), "\xff", "validation.isbn13", "another message", "x");
    try expectNoViolation([]const u8, v.isbn13, "9780306406157");
}

test "issn is a rule value with code validation.issn and message \"must be a valid ISSN\"; no precondition" {
    try testing.expect(@hasDecl(v, "issn"));
    try testing.expect(@TypeOf(v.issn) == v.Rule);
    try expectRule(v.issn, "validation.issn", "must be a valid ISSN", "must be a valid ISSN");
    try expectViolation([]const u8, v.issn, "03178471", "validation.issn", "must be a valid ISSN", "x");
    try expectViolation([]const u8, v.issn.withMessage("another message"), "\xff", "validation.issn", "another message", "x");
    try expectNoViolation([]const u8, v.issn, "0317-8471");
}

test "ean is a rule value with code validation.ean and message \"must be a valid EAN\"; no precondition" {
    try testing.expect(@hasDecl(v, "ean"));
    try testing.expect(@TypeOf(v.ean) == v.Rule);
    try expectRule(v.ean, "validation.ean", "must be a valid EAN", "must be a valid EAN");
    try expectViolation([]const u8, v.ean, "036000291452", "validation.ean", "must be a valid EAN", "x");
    try expectViolation([]const u8, v.ean.withMessage("another message"), "\xff", "validation.ean", "another message", "x");
    try expectNoViolation([]const u8, v.ean, "4006381333931");
}

test "isin is a rule value with code validation.isin and message \"must be a valid ISIN\"; no precondition" {
    try testing.expect(@hasDecl(v, "isin"));
    try testing.expect(@TypeOf(v.isin) == v.Rule);
    try expectRule(v.isin, "validation.isin", "must be a valid ISIN", "must be a valid ISIN");
    try expectViolation([]const u8, v.isin, "US0378331006", "validation.isin", "must be a valid ISIN", "x");
    try expectViolation([]const u8, v.isin.withMessage("another message"), "\xff", "validation.isin", "another message", "x");
    try expectNoViolation([]const u8, v.isin, "US0378331005");
}

test "isrc is a rule value with code validation.isrc and message \"must be a valid ISRC\"; no precondition" {
    try testing.expect(@hasDecl(v, "isrc"));
    try testing.expect(@TypeOf(v.isrc) == v.Rule);
    try expectRule(v.isrc, "validation.isrc", "must be a valid ISRC", "must be a valid ISRC");
    try expectViolation([]const u8, v.isrc, "US-RC1-76-07839", "validation.isrc", "must be a valid ISRC", "x");
    try expectViolation([]const u8, v.isrc.withMessage("another message"), "\xff", "validation.isrc", "another message", "x");
    try expectNoViolation([]const u8, v.isrc, "USRC17607839");
}

test "bic is a rule value with code validation.bic and message \"must be a valid BIC\"; no precondition" {
    try testing.expect(@hasDecl(v, "bic"));
    try testing.expect(@TypeOf(v.bic) == v.Rule);
    try expectRule(v.bic, "validation.bic", "must be a valid BIC", "must be a valid BIC");
    try expectViolation([]const u8, v.bic, "deutdeff", "validation.bic", "must be a valid BIC", "x");
    try expectViolation([]const u8, v.bic.withMessage("another message"), "\xff", "validation.bic", "another message", "x");
    try expectNoViolation([]const u8, v.bic, "DEUTDEFF");
}

test "iban is a rule value with code validation.iban and message \"must be a valid IBAN\"; no precondition" {
    try testing.expect(@hasDecl(v, "iban"));
    try testing.expect(@TypeOf(v.iban) == v.Rule);
    try expectRule(v.iban, "validation.iban", "must be a valid IBAN", "must be a valid IBAN");
    try expectViolation([]const u8, v.iban, "DE01370400441000000008", "validation.iban", "must be a valid IBAN", "x");
    try expectViolation([]const u8, v.iban.withMessage("another message"), "\xff", "validation.iban", "another message", "x");
    try expectNoViolation([]const u8, v.iban, "DE89370400440532013000");
}

test "btcAddress is a rule constructor with code validation.btc_address and message \"must be a valid Bitcoin address\", or \"must be a valid Bitcoin testnet address\" for .testnet; placeholder {network}; no precondition" {
    try testing.expect(@hasDecl(v, "btcAddress"));
    try testing.expect(@typeInfo(@TypeOf(v.btcAddress)).@"fn".return_type == v.Rule);
    const networks = [_][]const u8{ "mainnet", "testnet", "any" };
    try testing.expect(@typeInfo(v.BtcNetwork).@"enum".mode == .exhaustive);
    try testing.expectEqual(networks.len, comptime std.meta.fieldNames(v.BtcNetwork).len);
    inline for (networks, comptime std.meta.fieldNames(v.BtcNetwork)) |name, tag| try testing.expectEqualStrings(name, tag);
    try expectRule(v.btcAddress(.mainnet), "validation.btc_address", "must be a valid Bitcoin address", "must be a valid Bitcoin address");
    try expectRule(v.btcAddress(.any), "validation.btc_address", "must be a valid Bitcoin address", "must be a valid Bitcoin address");
    try expectRule(v.btcAddress(.testnet), "validation.btc_address", "must be a valid Bitcoin testnet address", "must be a valid Bitcoin testnet address");
    try expectPlaceholder(v.btcAddress(.mainnet), "{network}", "mainnet");
    try expectPlaceholder(v.btcAddress(.testnet), "{network}", "testnet");
    try expectPlaceholder(v.btcAddress(.any), "{network}", "any");
    try expectViolation([]const u8, v.btcAddress(.mainnet), "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "validation.btc_address", "must be a valid Bitcoin address", "x");
    try expectViolation([]const u8, v.btcAddress(.testnet), "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", "validation.btc_address", "must be a valid Bitcoin testnet address", "x");
    try expectViolation([]const u8, v.btcAddress(.any).withMessage("another message"), "\xff", "validation.btc_address", "another message", "x");
    try expectNoViolation([]const u8, v.btcAddress(.any), "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4");
}

test "ethereumAddress is a rule value with code validation.ethereum_address and message \"must be a valid Ethereum address\"; no precondition" {
    try testing.expect(@hasDecl(v, "ethereumAddress"));
    try testing.expect(@TypeOf(v.ethereumAddress) == v.Rule);
    try expectRule(v.ethereumAddress, "validation.ethereum_address", "must be a valid Ethereum address", "must be a valid Ethereum address");
    try expectViolation([]const u8, v.ethereumAddress, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD", "validation.ethereum_address", "must be a valid Ethereum address", "x");
    try expectViolation([]const u8, v.ethereumAddress.withMessage("another message"), "\xff", "validation.ethereum_address", "another message", "x");
    try expectNoViolation([]const u8, v.ethereumAddress, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
}

test "minItems is a rule constructor with code validation.min_items and message \"must have at least {min} items\", or \"must have at least 1 item\" when min = 1; placeholder {min}" {
    try testing.expect(@hasDecl(v, "minItems"));
    try testing.expect(@typeInfo(@TypeOf(v.minItems)).@"fn".return_type == v.Rule);
    try expectRule(v.minItems(2), "validation.min_items", "must have at least 2 items", "must have at least {min} items");
    try expectPlaceholder(v.minItems(2), "{min}", "2");
    try expectViolation([]const u32, v.minItems(2), &.{1}, "validation.min_items", "must have at least 2 items", "x");
    try expectRule(v.minItems(1), "validation.min_items", "must have at least 1 item", "must have at least 1 item");
    try expectViolation([]const u32, v.minItems(1), &.{}, "validation.min_items", "must have at least 1 item", "x");
    try expectNoViolation([]const u32, v.minItems(2), &.{ 1, 2 });
}

test "maxItems is a rule constructor with code validation.max_items and message \"must have at most {max} items\", or \"must have at most 1 item\" when max = 1; placeholder {max}" {
    try testing.expect(@hasDecl(v, "maxItems"));
    try testing.expect(@typeInfo(@TypeOf(v.maxItems)).@"fn".return_type == v.Rule);
    try expectRule(v.maxItems(2), "validation.max_items", "must have at most 2 items", "must have at most {max} items");
    try expectPlaceholder(v.maxItems(2), "{max}", "2");
    try expectViolation([]const u32, v.maxItems(2), &.{ 1, 2, 3 }, "validation.max_items", "must have at most 2 items", "x");
    try expectRule(v.maxItems(1), "validation.max_items", "must have at most 1 item", "must have at most 1 item");
    try expectViolation([]const u32, v.maxItems(1), &.{ 1, 2 }, "validation.max_items", "must have at most 1 item", "x");
    try expectNoViolation([]const u32, v.maxItems(2), &.{1});
}

test "each is a rule constructor with no code or message of its own; an item reports the inner rule's code and message at its index" {
    try testing.expect(@hasDecl(v, "each"));
    try testing.expect(@typeInfo(@TypeOf(v.each)).@"fn".return_type == v.Rule);
    try testing.expectEqualStrings("", v.each(v.notEmpty).code);
    try testing.expectEqualStrings("", v.each(v.notEmpty).message);
    try expectViolation([]const []const u8, v.each(v.notEmpty), &.{ "a", "" }, "validation.not_empty", "must not be empty", "x[1]");
    try expectViolation([]const u32, v.each(.{ v.positive, v.custom("acme.even", "must be even", isEven) }), &.{ 2, 3 }, "acme.even", "must be even", "x[1]");
    try expectNoViolation([]const []const u8, v.each(v.notEmpty), &.{ "a", "b" });
}

test "custom is a rule constructor whose code and literal message are its arguments" {
    try testing.expect(@hasDecl(v, "custom"));
    try testing.expect(@typeInfo(@TypeOf(v.custom)).@"fn".return_type == v.Rule);
    const literal = v.custom("acme.even", "must be even, not {odd} }}", isEven);
    try testing.expectEqualStrings("acme.even", literal.code);
    try testing.expectEqualStrings("must be even, not {odd} }}", literal.message);
    try expectViolation(u32, v.custom("acme.even", "must be even", isEven), 3, "acme.even", "must be even", "x");
    try expectNoViolation(u32, v.custom("acme.even", "must be even", isEven), 4);
}

test "equals on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.equals(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.equals(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "notEquals on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.notEquals(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.notEquals(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "min on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.min(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.min(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "max on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.max(0), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.max(0).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "range on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.range(0, 1), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.range(0, 1).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "positive on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.positive, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.positive.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "nonNegative on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.nonNegative, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonNegative.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "negative on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.negative, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.negative.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "nonPositive on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.nonPositive, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.nonPositive.withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "divisibleBy on a float field fails nan, inf and -inf with the finite precondition, also under withMessage" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.divisibleBy(2), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.divisibleBy(2).withMessage("another message"), -std.math.inf(F), "validation.finite", "must be a finite number", "x");
    }
}

test "finite has no precondition: nan, inf and -inf on a float field fail its own check, so withMessage changes their message" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expectViolation(F, v.finite, std.math.nan(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), std.math.nan(F), "validation.finite", "another message", "x");
        try expectViolation(F, v.finite, std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), std.math.inf(F), "validation.finite", "another message", "x");
        try expectViolation(F, v.finite, -std.math.inf(F), "validation.finite", "must be a finite number", "x");
        try expectViolation(F, v.finite.withMessage("another message"), -std.math.inf(F), "validation.finite", "another message", "x");
        try expectNoViolation(F, v.finite, std.math.floatMax(F));
    }
}

test "the module exports exactly its 63 public names, and Rule.withMessage" {
    const names = [_][]const u8{ "Violation", "Rule", "Report", "max_code_bytes", "max_message_bytes", "max_report_violations", "check", "checkAll", "assertRules", "fail", "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty", "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite", "uuid", "mongoId", "firebasePushId", "hash", "creditCard", "isbn", "isbn10", "isbn13", "issn", "ean", "isin", "isrc", "bic", "iban", "btcAddress", "ethereumAddress", "isUuid", "isMongoId", "isFirebasePushId", "isHash", "isCreditCard", "isIsbn", "isIsbn10", "isIsbn13", "isIssn", "isEan", "isIsin", "isIsrc", "isBic", "isIban", "isBtcAddress", "isEthereumAddress", "HashAlgorithm", "BtcNetwork", "minItems", "maxItems", "each", "custom" };
    inline for (names) |name| try testing.expect(@hasDecl(v, name));
    try testing.expectEqual(names.len, comptime std.meta.declarations(v).len);
    try testing.expect(@hasDecl(v.Rule, "withMessage"));
}

test "every rule the module exports has a catalog test" {
    @setEvalBranchQuota(100_000);
    const tested = [_][]const u8{ "equals", "notEquals", "oneOf", "noneOf", "empty", "notEmpty", "min", "max", "range", "positive", "nonNegative", "negative", "nonPositive", "divisibleBy", "finite", "uuid", "mongoId", "firebasePushId", "hash", "creditCard", "isbn", "isbn10", "isbn13", "issn", "ean", "isin", "isrc", "bic", "iban", "btcAddress", "ethereumAddress", "minItems", "maxItems", "each", "custom" };
    inline for (comptime std.meta.declarations(v)) |name| {
        const T = @TypeOf(@field(v, name));
        if (comptime T == v.Rule or (@typeInfo(T) == .@"fn" and @typeInfo(T).@"fn".return_type == v.Rule)) {
            const listed = comptime for (tested) |rule| {
                if (std.mem.eql(u8, rule, name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("v.{s} is a rule without a catalog test: add its test to catalog_test.zig and its name to `tested`\n", .{name});
                return error.TestUntestedRule;
            }
        }
    }
}

test "the module exports exactly the catalog predicates of the shipped rules" {
    @setEvalBranchQuota(100_000);
    const predicates = [_][]const u8{ "isUuid", "isMongoId", "isFirebasePushId", "isHash", "isCreditCard", "isIsbn", "isIsbn10", "isIsbn13", "isIssn", "isEan", "isIsin", "isIsrc", "isBic", "isIban", "isBtcAddress", "isEthereumAddress" };
    comptime var exported: usize = 0;
    inline for (comptime std.meta.declarations(v)) |name| {
        if (comptime name.len > 2 and std.mem.startsWith(u8, name, "is") and std.ascii.isUpper(name[2])) {
            exported += 1;
            const listed = comptime for (predicates) |predicate| {
                if (std.mem.eql(u8, predicate, name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("v.{s} is not a catalog predicate of a shipped rule\n", .{name});
                return error.TestUnexpectedPredicate;
            }
        }
    }
    try testing.expectEqual(predicates.len, exported);
}

test "the limits have their catalog values" {
    try testing.expect(@TypeOf(v.max_code_bytes) == comptime_int);
    try testing.expectEqual(128, v.max_code_bytes);
    try testing.expect(@TypeOf(v.max_message_bytes) == comptime_int);
    try testing.expectEqual(512, v.max_message_bytes);
    try testing.expect(@TypeOf(v.max_report_violations) == comptime_int);
    try testing.expectEqual(100, v.max_report_violations);
}
