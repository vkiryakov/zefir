//! Tests of the updates of models: each literal is encoded against its
//! model, and the bytes are compared with those that `bson.encode` writes
//! for the same update spelled without types, under the BSON keys and the
//! `$` operators. tests/compile_errors.zig holds the updates that must not
//! compile.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const update = @import("../query/update.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;
const Gen = models.Gen;
const Slug = models.Slug;

const now: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const lyon: models.Address = .{ .city = "Lyon", .country = "FR" };
const item: models.Item = .{ .sku = "x", .qty = 2 };

/// The update `literal` of the model `T`, for `use`, is the document
/// `expected`, byte for byte.
fn expectUpdate(comptime T: type, literal: anytype, comptime use: update.Use, expected: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try update.encode(T, arena.allocator(), literal, use);
    const want = try bson.encode(arena.allocator(), expected, .{});
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

test "set takes a value of the field, and a literal on a required struct is paths into it" {
    try expectUpdate(Account, .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } }, .update, .{
        .@"$set" = .{ .status = "blocked" },
        .@"$inc" = .{ .age = @as(i64, 1) },
    });
    try expectUpdate(Account, .{ .set = .{ .address = .{ .city = "Lyon" } } }, .update, .{ .@"$set" = .{ .@"address.city" = "Lyon" } });
    // A value of a struct is the whole subdocument, without its null
    // optionals.
    const p: User.Profile = .{ .city = "Lyon", .country = "FR" };
    try expectUpdate(Account, .{ .set = .{ .profile = p } }, .update, .{ .@"$set" = .{ .profile = .{ .city = "Lyon", .country = "FR" } } });
    try expectUpdate(Account, .{ .set = .{ .address = lyon } }, .update, .{ .@"$set" = .{ .address = .{ .city = "Lyon", .country = "FR" } } });
    // An optional takes a value of its child, known at compile time or at
    // run time.
    try expectUpdate(Account, .{ .set = .{ .nickname = "ann" } }, .update, .{ .@"$set" = .{ .nickname = "ann" } });
    var name: []const u8 = "ann";
    _ = &name;
    try expectUpdate(Account, .{ .set = .{ .nickname = name } }, .update, .{ .@"$set" = .{ .nickname = "ann" } });
    // The key of names, whole lists, a double, in the order of the literal.
    try expectUpdate(Account, .{ .set = .{ .created_at = now, .tags = .{ "a", "b" }, .items = .{}, .score = 2.5 } }, .update, .{
        .@"$set" = .{ .createdAt = now, .tags = .{ "a", "b" }, .items = &.{}, .score = 2.5 },
    });
}

test "unset takes a tuple of paths of optionals and of fields with a default" {
    try expectUpdate(Account, .{ .unset = .{ .profile, .nickname } }, .update, .{ .@"$unset" = .{ .profile = "", .nickname = "" } });
    try expectUpdate(Account, .{ .unset = .{.@"address.zip"} }, .update, .{ .@"$unset" = .{ .@"address.zip" = "" } });
    try expectUpdate(Account, .{ .unset = .{ .age, .tags } }, .update, .{ .@"$unset" = .{ .age = "", .tags = "" } });
}

test "the operators of lists take an item, items, or conditions on the items" {
    try expectUpdate(Account, .{ .push = .{ .tags = "new" } }, .update, .{ .@"$push" = .{ .tags = "new" } });
    try expectUpdate(Account, .{ .push = .{ .items = item } }, .update, .{ .@"$push" = .{ .items = .{ .sku = "x", .qty = @as(i64, 2) } } });
    // An optional list: the server makes the list when a document lacks it.
    try expectUpdate(Account, .{ .push = .{ .labels = "x" } }, .update, .{ .@"$push" = .{ .labels = "x" } });
    try expectUpdate(Account, .{ .add_to_set = .{ .tags = .{ .each = &.{ "a", "b" } } } }, .update, .{
        .@"$addToSet" = .{ .tags = .{ .@"$each" = .{ "a", "b" } } },
    });
    const more: []const []const u8 = &.{ "c", "d" };
    try expectUpdate(Account, .{ .push = .{ .tags = .{ .each = more } } }, .update, .{ .@"$push" = .{ .tags = .{ .@"$each" = .{ "c", "d" } } } });
    try expectUpdate(Account, .{ .pull = .{ .items = .{ .qty = .{ .lt = 1 } } } }, .update, .{
        .@"$pull" = .{ .items = .{ .qty = .{ .@"$lt" = @as(i64, 1) } } },
    });
    try expectUpdate(Account, .{ .pull = .{ .tags = "a" } }, .update, .{ .@"$pull" = .{ .tags = "a" } });
    try expectUpdate(Account, .{ .pull = .{ .tags = .{ .in = .{ "a", "b" } } } }, .update, .{ .@"$pull" = .{ .tags = .{ .@"$in" = .{ "a", "b" } } } });
    // A whole item goes under $eq: the items equal to it go, and not those
    // that only hold its fields.
    try expectUpdate(Account, .{ .pull = .{ .items = item } }, .update, .{
        .@"$pull" = .{ .items = .{ .@"$eq" = .{ .sku = "x", .qty = @as(i64, 2) } } },
    });
    try expectUpdate(Account, .{ .pop = .{ .tags = .last } }, .update, .{ .@"$pop" = .{ .tags = @as(i32, 1) } });
    try expectUpdate(Account, .{ .pop = .{ .items = .first } }, .update, .{ .@"$pop" = .{ .items = @as(i32, -1) } });
}

test "pull of a document or of a value of any type goes under $eq" {
    // A document whose first key starts with '$' stays a value.
    const operators = bson.literal(.{ .@"$ne" = null });
    try expectUpdate(models.Event, .{ .pull = .{ .parts = operators } }, .update, .{ .@"$pull" = .{ .parts = .{ .@"$eq" = operators } } });
    const any: bson.Value = .{ .document = operators };
    try expectUpdate(models.Event, .{ .pull = .{ .values = any } }, .update, .{ .@"$pull" = .{ .values = .{ .@"$eq" = any } } });
}

test "the operators of numbers take an integer of the field's BSON integer, negative too" {
    try expectUpdate(Account, .{ .max = .{ .created_at = now } }, .update, .{ .@"$max" = .{ .createdAt = now } });
    try expectUpdate(Account, .{ .min = .{ .email = "a" } }, .update, .{ .@"$min" = .{ .email = "a" } });
    try expectUpdate(Account, .{ .min = .{ .address = .{ .city = "a" } } }, .update, .{ .@"$min" = .{ .@"address.city" = "a" } });
    // An optional double.
    try expectUpdate(Account, .{ .mul = .{ .score = 1.5 } }, .update, .{ .@"$mul" = .{ .score = 1.5 } });
    // A u32 is an int64 in BSON, an i32 an int32.
    try expectUpdate(Account, .{ .inc = .{ .visits = -1 } }, .update, .{ .@"$inc" = .{ .visits = @as(i64, -1) } });
    try expectUpdate(Gen, .{ .inc = .{ .n = 1 } }, .update, .{ .@"$inc" = .{ .n = @as(i32, 1) } });
    var step: i64 = -3;
    _ = &step;
    try expectUpdate(Account, .{ .inc = .{ .visits = step }, .mul = .{ .age = 2 } }, .update, .{
        .@"$inc" = .{ .visits = @as(i64, -3) },
        .@"$mul" = .{ .age = @as(i64, 2) },
    });
}

test "a literal known at run time keeps the values known at compile time in it" {
    var step: i64 = -3;
    _ = &step;
    try expectUpdate(Account, .{ .inc = .{ .visits = step, .age = 1 } }, .update, .{ .@"$inc" = .{ .visits = @as(i64, -3), .age = @as(i64, 1) } });
    var name: []const u8 = "ann";
    _ = &name;
    try expectUpdate(Account, .{ .set = .{ .nickname = name, .address = .{ .city = "Lyon" }, .status = .blocked } }, .update, .{
        .@"$set" = .{ .nickname = "ann", .@"address.city" = "Lyon", .status = "blocked" },
    });
}

test "set_on_insert works in an upsert, and gives the id there" {
    try expectUpdate(Account, .{ .set_on_insert = .{ .status = .active } }, .upsert, .{ .@"$setOnInsert" = .{ .status = "active" } });
    try expectUpdate(Slug, .{ .set_on_insert = .{ .id = "ann" } }, .upsert, .{ .@"$setOnInsert" = .{ ._id = "ann" } });
}

test "values that BSON cannot hold are EncodeFailed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "\xff";
    _ = &bad;
    try testing.expectError(error.EncodeFailed, update.encode(Account, arena.allocator(), .{ .set = .{ .nickname = bad } }, .update));
    try testing.expectError(error.EncodeFailed, update.encode(Account, arena.allocator(), .{ .push = .{ .tags = bad } }, .update));
    var nul: []const u8 = "a\x00b";
    _ = &nul;
    try testing.expectError(error.EncodeFailed, update.encode(Account, arena.allocator(), .{ .pull = .{ .tags = .{ .regex = nul } } }, .update));
}
