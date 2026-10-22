//! Tests of the types that odm makes from a model: `odm.Schema`,
//! `odm.Names`, `odm.Index`, `odm.IndexKey`, `odm.Path`, `odm.Insert` and
//! `odm.Id`.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;
const Gen = models.Gen;
const Slug = models.Slug;

/// The names of the enum `E`, in their order, are `expected`.
fn expectNames(comptime E: type, expected: []const []const u8) !void {
    const names = @typeInfo(E).@"enum".field_names;
    try testing.expectEqual(expected.len, names.len);
    for (expected, names) |want, name| try testing.expectEqualStrings(want, name);
}

test "a model declares a schema typed by itself" {
    try testing.expect(@TypeOf(User.odm_schema) == odm.Schema(User));
    try testing.expectEqualStrings("createdAt", User.odm_schema.names.created_at.?);
    try testing.expectEqual(null, User.odm_schema.names.email);
    try testing.expectEqualStrings("users", User.odm_schema.collection);
    try testing.expectEqual(.id, User.odm_schema.id);
    // The keys of the second index, in their order.
    const keys = User.odm_schema.indexes[1].keys;
    try testing.expectEqual(2, keys.len);
    try testing.expectEqual(odm.IndexOrder.asc, keys[0].status);
    try testing.expectEqual(odm.IndexOrder.desc, keys[1].created_at);
    try testing.expect(User.odm_schema.indexes[0].unique);
    try testing.expect(!User.odm_schema.indexes[1].unique);
}

test "Path lists every path depth-first" {
    try expectNames(odm.Path(User), &.{ "id", "email", "name", "age", "status", "profile", "profile.city", "profile.country", "created_at" });
    try expectNames(odm.Path(Account), &.{
        "id",      "email",        "name",            "age",         "status",
        "profile", "profile.city", "profile.country", "created_at",  "nickname",
        "tags",    "labels",       "items",           "items.sku",   "items.qty",
        "address", "address.city", "address.country", "address.zip", "visits",
        "score",
    });
    try testing.expect(@hasField(odm.Path(Account), "items.sku"));
    try testing.expect(@hasField(odm.Path(Account), "items.qty"));
    try testing.expect(@hasField(odm.Path(Account), "address.zip"));
}

test "IndexKey takes one path and its order" {
    const by_email: odm.IndexKey(User) = .{ .email = .asc };
    const by_city: odm.IndexKey(User) = .{ .@"profile.city" = .desc };
    try testing.expectEqual(odm.Path(User).email, std.meta.activeTag(by_email));
    try testing.expectEqual(odm.IndexOrder.asc, by_email.email);
    try testing.expectEqual(odm.Path(User).@"profile.city", std.meta.activeTag(by_city));
    try testing.expectEqual(odm.IndexOrder.desc, by_city.@"profile.city");
}

test "Insert and Id follow the kind of the id" {
    try testing.expect(odm.Insert(User) == User);
    try testing.expect(odm.Id(User) == bson.ObjectId);
    // The id of Gen is always made by odm: Insert(Gen) has no field for it.
    const info = @typeInfo(odm.Insert(Gen)).@"struct";
    try testing.expectEqual(1, info.field_names.len);
    try testing.expectEqualStrings("n", info.field_names[0]);
    try testing.expect(info.field_types[0] == i32);
    try testing.expectEqual(0, comptime info.field_attrs[0].defaultValue(i32).?);
    const gen: odm.Insert(Gen) = .{};
    try testing.expectEqual(0, gen.n);
    try testing.expect(odm.Id(Gen) == bson.ObjectId);
    try testing.expect(odm.Insert(Slug) == Slug);
    try testing.expect(odm.Id(Slug) == []const u8);
}
