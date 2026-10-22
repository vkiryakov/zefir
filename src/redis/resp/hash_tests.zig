//! Tests of a hash and a struct both ways, by the rules of the design's
//! §3.3, on the struct `Profile`: the fields that are written and those
//! that are not, defaults, optionals and extra fields on the way back,
//! binary values, and `[]const redis.FieldValue` in place of a struct.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const hash = @import("hash.zig");
const FieldValue = @import("../cmd/types.zig").FieldValue;
const Diagnostics = @import("../errors.zig").Diagnostics;

const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro },
    note: ?[]const u8 = null,
    @"created-at": i64 = 0,
};

/// The bytes that `hash.write` gives for `fields`. The caller frees them
/// with `testing.allocator`.
fn written(fields: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try hash.write(.init(&out.writer), fields);
    return out.toOwnedSlice();
}

/// Reads the reply of `bytes` into `T` in `arena`; the reply must end
/// where `bytes` do.
fn read(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, diagnostics: ?*Diagnostics) !T {
    var in: std.Io.Reader = .fixed(bytes);
    var reader: resp.Reader = .init(&in, 1 << 20);
    const result = try resp.decode(T, &reader, arena, diagnostics);
    try testing.expectEqual(bytes.len, in.seek);
    return result;
}

test "a struct is written as its fields in order, and a null optional is left out" {
    const profile: Profile = .{ .name = "Ann", .age = 30, .plan = .pro };
    const bytes = try written(profile);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n$4\r\nplan\r\n$3\r\npro\r\n$10\r\ncreated-at\r\n$1\r\n0\r\n", bytes);
    try testing.expectEqual(@as(usize, 4), hash.fieldCount(profile));
    try hash.check(profile, "redis.cmd.hset", null);
}

test "an empty string is written as a field, not left out" {
    const profile: Profile = .{ .name = "Ann", .age = 30, .plan = .free, .note = "" };
    const bytes = try written(profile);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n$4\r\nplan\r\n$4\r\nfree\r\n$4\r\nnote\r\n$0\r\n\r\n$10\r\ncreated-at\r\n$1\r\n0\r\n", bytes);
    try testing.expectEqual(@as(usize, 5), hash.fieldCount(profile));
}

test "a literal is written as its fields, numbers and enums by the rules of arguments" {
    const bytes = try written(.{ .score = 12.5, .active = true, .plan = .pro, .visits = 3 });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("$5\r\nscore\r\n$4\r\n12.5\r\n$6\r\nactive\r\n$1\r\n1\r\n$4\r\nplan\r\n$3\r\npro\r\n$6\r\nvisits\r\n$1\r\n3\r\n", bytes);
}

test "no field to write is InvalidArgument, and so is NaN" {
    const Optional = struct { a: ?[]const u8 = null, b: ?i64 = null };
    var d: Diagnostics = .{};
    try testing.expectEqual(@as(usize, 0), hash.fieldCount(Optional{}));
    try testing.expectError(error.InvalidArgument, hash.check(Optional{}, "redis.cmd.hset", &d));
    try testing.expectEqualStrings("redis.cmd.hset: no field to write: a hash takes at least one", d.message());
    try testing.expectEqualStrings("", d.code());
    try hash.check(Optional{ .b = 1 }, "redis.cmd.hset", null);

    const none: []const FieldValue = &.{};
    try testing.expectError(error.InvalidArgument, hash.check(none, "redis.cmd.hset", null));

    const Scores = struct { score: f64, best: ?f64 = null };
    try testing.expectError(error.InvalidArgument, hash.check(Scores{ .score = std.math.nan(f64) }, "redis.cmd.hset", &d));
    try testing.expectEqualStrings("redis.cmd.hset: field 'score' is NaN, which a server does not take", d.message());
    try testing.expectError(error.InvalidArgument, hash.check(Scores{ .score = 1, .best = std.math.nan(f64) }, "redis.cmd.hset", &d));
    try testing.expectEqualStrings("redis.cmd.hset: field 'best' is NaN, which a server does not take", d.message());
    try hash.check(Scores{ .score = std.math.inf(f64) }, "redis.cmd.hset", null);
}

test "a slice of redis.FieldValue is written as it is" {
    const fields: []const FieldValue = &.{ .{ .field = "b", .value = "2" }, .{ .field = "a", .value = "" } };
    const bytes = try written(fields);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("$1\r\nb\r\n$1\r\n2\r\n$1\r\na\r\n$0\r\n\r\n", bytes);
    try testing.expectEqual(@as(usize, 2), hash.fieldCount(fields));
    try hash.check(fields, "redis.cmd.hset", null);
    const array = [_]FieldValue{.{ .field = "k", .value = "v" }};
    try testing.expectEqual(@as(usize, 1), hash.fieldCount(&array));
}

test "binary names and values go and come back byte for byte" {
    const Binary = struct { @"a\r\nb": []const u8, value: []const u8 };
    const sent: Binary = .{ .@"a\r\nb" = "x\x00y\r\n", .value = "\r\n" };
    const bytes = try written(sent);
    defer testing.allocator.free(bytes);
    // The fields as written are bulk strings, which a map of a reply holds
    // the same way.
    const reply = try std.mem.concat(testing.allocator, u8, &.{ "%2\r\n", bytes });
    defer testing.allocator.free(reply);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const back = try read(Binary, arena.allocator(), reply, null);
    try testing.expectEqualStrings(sent.@"a\r\nb", back.@"a\r\nb");
    try testing.expectEqualStrings(sent.value, back.value);
    const pairs = try read([]const FieldValue, arena.allocator(), reply, null);
    try testing.expectEqualStrings("a\r\nb", pairs[0].field);
    try testing.expectEqualStrings("x\x00y\r\n", pairs[0].value);
}

test "a map reads into a struct by the names of its fields, with defaults and null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expected: Profile = .{ .name = "Ann", .age = 30, .plan = .pro, .note = null, .@"created-at" = 0 };
    const map = "%3\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n$4\r\nplan\r\n$3\r\npro\r\n";
    try testing.expectEqualDeep(expected, try read(Profile, arena.allocator(), map, null));
    try testing.expectEqualDeep(@as(?Profile, expected), try read(?Profile, arena.allocator(), map, null));
    // The fields of an entry of a stream: a flat array of pairs.
    const flat = "*6\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n$4\r\nplan\r\n$3\r\npro\r\n";
    try testing.expectEqualDeep(expected, try read(Profile, arena.allocator(), flat, null));
    // Any order; a field the hash has overrides the default.
    const all = "%5\r\n$10\r\ncreated-at\r\n$2\r\n-5\r\n$4\r\nnote\r\n$2\r\nhi\r\n$4\r\nplan\r\n$4\r\nfree\r\n$3\r\nage\r\n:7\r\n$4\r\nname\r\n+Bo\r\n";
    try testing.expectEqualDeep(Profile{ .name = "Bo", .age = 7, .plan = .free, .note = "hi", .@"created-at" = -5 }, try read(Profile, arena.allocator(), all, null));
}

test "an empty string in a field is an empty string, not null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const map = "%4\r\n$4\r\nname\r\n$0\r\n\r\n$3\r\nage\r\n$1\r\n1\r\n$4\r\nplan\r\n$3\r\npro\r\n$4\r\nnote\r\n$0\r\n\r\n";
    const profile = try read(Profile, arena.allocator(), map, null);
    try testing.expectEqualStrings("", profile.name);
    try testing.expectEqualDeep(@as(?[]const u8, ""), profile.note);
}

test "extra fields are skipped, whatever they hold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const map = "%5\r\n$1\r\nx\r\n$5\r\nextra\r\n$4\r\nname\r\n$3\r\nAnn\r\n$22\r\nlonger-than-any-field-\r\n*2\r\n:1\r\n:2\r\n$3\r\nage\r\n$2\r\n30\r\n$4\r\nplan\r\n$3\r\npro\r\n";
    const profile = try read(Profile, arena.allocator(), map, null);
    try testing.expectEqualStrings("Ann", profile.name);
    try testing.expectEqual(@as(u8, 30), profile.age);
}

test "a missing field without a default, or a value that does not fit, is UnexpectedReply naming the field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostics = .{};
    const no_age = "%2\r\n$4\r\nname\r\n$3\r\nAnn\r\n$4\r\nplan\r\n$3\r\npro\r\n";
    try testing.expectError(error.UnexpectedReply, read(Profile, arena.allocator(), no_age, &d));
    try testing.expectEqualStrings("the hash lacks the field 'age' of resp.hash_tests.Profile, which has no default value", d.message());

    const big_age = "%3\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$3\r\n300\r\n$4\r\nplan\r\n$3\r\npro\r\n";
    try testing.expectError(error.UnexpectedReply, read(Profile, arena.allocator(), big_age, &d));
    try testing.expectEqualStrings("field 'age' of the reply is a bulk string of 3 bytes, and the call asked for u8", d.message());

    const odd = "*3\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n";
    try testing.expectError(error.UnexpectedReply, read(Profile, arena.allocator(), odd, &d));
    try testing.expectEqualStrings("the reply is an array of 3 elements, and the call asked for resp.hash_tests.Profile", d.message());
    try testing.expectError(error.UnexpectedReply, read(Profile, arena.allocator(), "$3\r\nAnn\r\n", &d));
    try testing.expectError(error.ServerError, read(Profile, arena.allocator(), "%1\r\n$4\r\nname\r\n-ERR inside\r\n", &d));
    try testing.expectEqualStrings("ERR", d.code());
}

test "an empty hash is null in an optional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?Profile, null), try read(?Profile, arena.allocator(), "%0\r\n", null));
    try testing.expectEqual(@as(?Profile, null), try read(?Profile, arena.allocator(), "*0\r\n", null));
    try testing.expectEqual(@as(?Profile, null), try read(?Profile, arena.allocator(), "_\r\n", null));
    try testing.expectEqual(@as(?[]const FieldValue, null), try read(?[]const FieldValue, arena.allocator(), "%0\r\n", null));
    // Without the optional, an empty hash is a hash without fields.
    const Defaults = struct { a: i64 = 1, b: ?[]const u8 = null };
    try testing.expectEqualDeep(Defaults{}, try read(Defaults, arena.allocator(), "%0\r\n", null));
    try testing.expectError(error.UnexpectedReply, read(Profile, arena.allocator(), "%0\r\n", null));
    // An empty list is still a list.
    try testing.expectEqualDeep(@as(?[]const i64, &.{}), try read(?[]const i64, arena.allocator(), "*0\r\n", null));
}

test "a hash of any fields reads into a slice of redis.FieldValue in the server's order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expected: []const FieldValue = &.{ .{ .field = "b", .value = "2" }, .{ .field = "a", .value = "" } };
    try testing.expectEqualDeep(expected, try read([]const FieldValue, arena.allocator(), "%2\r\n$1\r\nb\r\n$1\r\n2\r\n$1\r\na\r\n$0\r\n\r\n", null));
    try testing.expectEqualDeep(expected, try read([]const FieldValue, arena.allocator(), "*4\r\n$1\r\nb\r\n:2\r\n+a\r\n$0\r\n\r\n", null));
    try testing.expectEqual(@as(usize, 0), (try read([]const FieldValue, arena.allocator(), "%0\r\n", null)).len);
    try testing.expectError(error.UnexpectedReply, read([]const FieldValue, arena.allocator(), "*3\r\n$1\r\nb\r\n$1\r\n2\r\n$1\r\na\r\n", null));
    try testing.expectError(error.UnexpectedReply, read([]const FieldValue, arena.allocator(), "%1\r\n$1\r\nb\r\n*0\r\n", null));
}

test "what a hash holds, as the comptime checks see it" {
    comptime {
        resp.checkReply(Profile, "test");
        resp.checkReply(?Profile, "test");
        resp.checkReply([]const Profile, "test");
        resp.checkReply([]const FieldValue, "test");
        hash.checkWrite(Profile, "test");
        hash.checkWrite([]const FieldValue, "test");
        hash.checkWrite(*const [1]FieldValue, "test");
        hash.checkWrite(@TypeOf(.{ .name = "Ann", .age = 30, .score = 1.5, .plan = .pro, .ok = true }), "test");
        std.debug.assert(hash.isHash(Profile));
        std.debug.assert(hash.isHash([]const FieldValue));
        std.debug.assert(!hash.isHash(struct { i64, i64 }));
        std.debug.assert(!hash.isHash([]const []const u8));
    }
}
