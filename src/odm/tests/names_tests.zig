//! Tests of the names that a provisioning brings: the id of a tenant and
//! the name of its database.

const std = @import("std");
const testing = std.testing;
const names = @import("../registry/names.zig");

test "a database name follows MongoDB's rules and is never a system one" {
    for ([_][]const u8{ "admin", "Admin", "ADMIN", "local", "Local", "config", "CONFIG" }) |name| {
        try testing.expectEqualStrings("the database name is a system one: admin, local or config", names.database(name).?);
    }
    try testing.expect(names.database(&@as([63]u8, @splat('a'))) == null);
    try testing.expectEqualStrings("the database name is longer than 63 bytes", names.database(&@as([64]u8, @splat('a'))).?);
    // A character of two bytes at the end: 63 bytes in all, then 64.
    try testing.expect(names.database(&@as([61]u8, @splat('a')) ++ "я") == null);
    try testing.expectEqualStrings("the database name is longer than 63 bytes", names.database(&@as([62]u8, @splat('a')) ++ "я").?);
    for ([_][]const u8{ "a.b", "a b", "a$b", "a/b", "a\\b", "a\"b", "a\x00b" }) |name| {
        try testing.expectEqualStrings("the database name holds one of / \\ . \" $, a space or NUL", names.database(name).?);
    }
    try testing.expectEqualStrings("the database name is empty", names.database("").?);
    try testing.expectEqualStrings("the database name is not UTF-8", names.database("\xff").?);
    try testing.expect(names.database("acme_prod-1") == null);
}

test "a tenant id is 1 to 128 bytes of visible ASCII" {
    try testing.expect(names.tenantId(&@as([128]u8, @splat('a'))) == null);
    try testing.expect(names.tenantId("acme:eu/1") == null);
    try testing.expectEqualStrings("the tenant id is longer than 128 bytes", names.tenantId(&@as([129]u8, @splat('a'))).?);
    try testing.expectEqualStrings("the tenant id is empty", names.tenantId("").?);
    for ([_][]const u8{ "a b", "a\x7f", "я" }) |id| {
        try testing.expectEqualStrings("the tenant id holds a byte outside visible ASCII, 0x21 to 0x7E", names.tenantId(id).?);
    }
}
