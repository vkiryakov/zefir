//! Tests of the rules of upsertOne: an upsert that may insert a document
//! builds when the model reads that document, and gets the id that its
//! literals give. tests/compile_errors.zig holds the upserts that must not
//! compile.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const filter = @import("../query/filter.zig");
const update = @import("../query/update.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;
const Slug = models.Slug;

const now: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const lyon: models.Address = .{ .city = "Lyon", .country = "FR" };

/// The upsert of `T` with the filter `conditions` and the update `changes`
/// builds, as upsertOne checks it, and they encode as `expected_filter` and
/// `expected_update`, byte for byte.
fn expectUpsert(comptime T: type, conditions: anytype, changes: anytype, expected_filter: anytype, expected_update: anytype) !void {
    comptime update.checkUpsert(T, @TypeOf(conditions), @TypeOf(changes));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDoc(a, expected_filter, try filter.encode(T, a, conditions));
    try expectDoc(a, expected_update, try update.encode(T, a, changes, .upsert));
}

fn expectDoc(arena: std.mem.Allocator, expected: anytype, got: bson.RawDocument) !void {
    const want = try bson.encode(arena, expected, .{});
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

test "every required field comes from an equality, set, set_on_insert or a creating operator" {
    var email: []const u8 = "ann@example.com";
    _ = &email;
    const name: []const u8 = "Ann";
    try expectUpsert(Account, .{ .email = email }, .{
        .set = .{ .name = name, .address = lyon },
        .set_on_insert = .{ .created_at = now },
        .inc = .{ .visits = 1 },
    }, .{ .email = "ann@example.com" }, .{
        .@"$set" = .{ .name = "Ann", .address = .{ .city = "Lyon", .country = "FR" } },
        .@"$setOnInsert" = .{ .createdAt = now },
        .@"$inc" = .{ .visits = @as(i64, 1) },
    });
    // An equality with eq counts; conditions of other operators go into no
    // document, and the operators that make no field give none.
    try expectUpsert(Account, .{ .email = .{ .eq = email }, .name = name, .age = .{ .gte = 18 } }, .{
        .max = .{ .created_at = now },
        .mul = .{ .visits = 2 },
        .set = .{ .address = lyon },
        .pull = .{ .tags = "old" },
    }, .{ .email = "ann@example.com", .name = "Ann", .age = .{ .@"$gte" = @as(i64, 18) } }, .{
        .@"$max" = .{ .createdAt = now },
        .@"$mul" = .{ .visits = @as(i64, 2) },
        .@"$set" = .{ .address = .{ .city = "Lyon", .country = "FR" } },
        .@"$pull" = .{ .tags = "old" },
    });
    // A whole list with eq, and conditions on the items of lists.
    const tags: []const []const u8 = &.{"a"};
    try expectUpsert(Account, .{ .email = email, .tags = .{ .eq = tags }, .items = .{ .elem_match = .{ .sku = "x" } } }, .{
        .set = .{ .name = name, .address = lyon, .created_at = now, .visits = 0 },
    }, .{ .email = "ann@example.com", .tags = .{"a"}, .items = .{ .@"$elemMatch" = .{ .sku = "x" } } }, .{
        .@"$set" = .{ .name = "Ann", .address = .{ .city = "Lyon", .country = "FR" }, .createdAt = now, .visits = @as(i64, 0) },
    });
}

test "a subdocument built from paths gets its required fields" {
    const email: []const u8 = "ann@example.com";
    try expectUpsert(Account, .{ .email = email }, .{
        .set = .{ .name = "Ann", .address = .{ .city = "Lyon", .country = "FR" } },
        .set_on_insert = .{ .created_at = now },
        .inc = .{ .visits = 1 },
    }, .{ .email = "ann@example.com" }, .{
        .@"$set" = .{ .name = "Ann", .@"address.city" = "Lyon", .@"address.country" = "FR" },
        .@"$setOnInsert" = .{ .createdAt = now },
        .@"$inc" = .{ .visits = @as(i64, 1) },
    });
    // The paths of the filter and of the update build one subdocument; an
    // optional struct built from paths of the filter gets them all too.
    try expectUpsert(Account, .{ .email = email, .address = .{ .city = "Lyon" }, .profile = .{ .city = "Lyon", .country = "FR" } }, .{
        .set = .{ .name = "Ann", .address = .{ .country = "FR" }, .created_at = now, .visits = 0 },
    }, .{ .email = "ann@example.com", .@"address.city" = "Lyon", .@"profile.city" = "Lyon", .@"profile.country" = "FR" }, .{
        .@"$set" = .{ .name = "Ann", .@"address.country" = "FR", .createdAt = now, .visits = @as(i64, 0) },
    });
}

test "the id of Slug comes from the filter or set_on_insert" {
    try expectUpsert(Slug, .{ .id = "ann" }, .{ .set = .{ .title = "Ann" } }, .{ ._id = "ann" }, .{ .@"$set" = .{ .title = "Ann" } });
    try testing.expectEqualStrings("ann", update.upsertId(Slug, .{ .id = "ann" }, .{ .set = .{ .title = "Ann" } }).?);
    try expectUpsert(Slug, .{ .title = "Ann" }, .{ .set_on_insert = .{ .id = "ann" } }, .{ .title = "Ann" }, .{ .@"$setOnInsert" = .{ ._id = "ann" } });
    try testing.expectEqualStrings("ann", update.upsertId(Slug, .{ .title = "Ann" }, .{ .set_on_insert = .{ .id = "ann" } }).?);
    var slug: []const u8 = "bob";
    _ = &slug;
    comptime update.checkUpsert(Slug, @TypeOf(.{ .id = .{ .eq = slug } }), @TypeOf(.{ .set = .{ .title = "Bob" } }));
    try testing.expectEqualStrings("bob", update.upsertId(Slug, .{ .id = .{ .eq = slug } }, .{ .set = .{ .title = "Bob" } }).?);
    // The server makes the ObjectId of User, unless the filter gives one.
    const changes = .{ .set = .{ .name = "Ann" }, .set_on_insert = .{ .created_at = now } };
    comptime update.checkUpsert(User, @TypeOf(.{ .email = "a@b.c" }), @TypeOf(changes));
    try testing.expectEqual(null, update.upsertId(User, .{ .email = "a@b.c" }, changes));
    const id = try bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293");
    try testing.expectEqual(id, update.upsertId(User, .{ .id = id, .email = "a@b.c" }, changes).?);
}
