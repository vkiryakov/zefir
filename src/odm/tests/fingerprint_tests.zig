//! Tests of the fingerprints of connection settings and of the rules of
//! connection ids.

const std = @import("std");
const testing = std.testing;
const fingerprint = @import("../fingerprint.zig");
const names = @import("../registry/names.zig");

const key: fingerprint.Key = @splat(7);

test "the same settings give the same fingerprint" {
    const a = fingerprint.of(&key, "mongodb://app@db:27017/", "secret");
    const b = fingerprint.of(&key, "mongodb://app@db:27017/", "secret");
    try testing.expect(fingerprint.eql(&a, &b));
    const none = fingerprint.of(&key, "mongodb://db:27017/", null);
    try testing.expect(fingerprint.eql(&none, &fingerprint.of(&key, "mongodb://db:27017/", null)));
    // A key from io.random fingerprints the same settings alike too.
    const random = fingerprint.newKey(testing.io);
    try testing.expect(fingerprint.eql(&fingerprint.of(&random, "u", "p"), &fingerprint.of(&random, "u", "p")));
}

test "any change gives another" {
    const base = fingerprint.of(&key, "mongodb://app@db:27017/", "secret");
    const changed = [_]fingerprint.Fingerprint{
        fingerprint.of(&key, "mongodb://app@db:27018/", "secret"),
        fingerprint.of(&key, "mongodb://app@db:27017/", "secret2"),
        fingerprint.of(&key, "mongodb://app@db:27017/", null),
    };
    for (&changed) |*other| try testing.expect(!fingerprint.eql(&base, other));
    // No password and an empty one are other settings.
    try testing.expect(!fingerprint.eql(&fingerprint.of(&key, "u", null), &fingerprint.of(&key, "u", "")));
    // The lengths keep the uri and the password apart.
    try testing.expect(!fingerprint.eql(&fingerprint.of(&key, "ab", "c"), &fingerprint.of(&key, "a", "bc")));
    // Another key, another fingerprint of the same settings.
    const other_key: fingerprint.Key = @splat(8);
    try testing.expect(!fingerprint.eql(&base, &fingerprint.of(&other_key, "mongodb://app@db:27017/", "secret")));
}

test "connection ids are 1 to 64 bytes of A-Z a-z 0-9 _ - . :" {
    const max: [64]u8 = @splat('a');
    for ([_][]const u8{ "shared-1", "a_b.c:d", &max, "AZaz09" }) |id| {
        try testing.expectEqual(@as(?[]const u8, null), names.connectionId(id));
    }
    const long: [65]u8 = @splat('a');
    for ([_][]const u8{ "", &long, "a/b", "a b", "я" }) |id| {
        try testing.expect(names.connectionId(id) != null);
    }
    try testing.expectEqualStrings("the connection id is empty", names.connectionId("").?);
    try testing.expectEqualStrings("the connection id is longer than 64 bytes", names.connectionId(&long).?);
    try testing.expectEqualStrings("the connection id holds a byte other than A-Z a-z 0-9 _ - . :", names.connectionId("a/b").?);
}
