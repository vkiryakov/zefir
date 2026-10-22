//! Tests of the filters of models: each literal is encoded against its
//! model, and the bytes are compared with those that `bson.encode` writes
//! for the same filter spelled without types, under the BSON keys and the
//! `$` operators. tests/compile_errors.zig holds the filters that must not
//! compile.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const filter = @import("../query/filter.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;
const Gen = models.Gen;

const id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;
const since: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };

/// The filter `literal` of the model `T` is the document `expected`,
/// byte for byte.
fn expectFilter(comptime T: type, literal: anytype, expected: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try filter.encode(T, arena.allocator(), literal);
    const want = try bson.encode(arena.allocator(), expected, .{});
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

test "fields go under their BSON keys, as values of the field's type" {
    try expectFilter(User, .{}, .{});
    try expectFilter(User, .{ .status = .active }, .{ .status = "active" });
    try expectFilter(User, .{ .id = id }, .{ ._id = id });
    try expectFilter(User, .{ .created_at = .{ .gte = since } }, .{ .createdAt = .{ .@"$gte" = since } });
    // A number for a u32 field is an int64, as the codec writes the field;
    // for an i32 field an int32.
    try expectFilter(User, .{ .age = 30 }, .{ .age = @as(i64, 30) });
    try expectFilter(Gen, .{ .n = 5 }, .{ .n = @as(i32, 5) });
    // An operator literal of eq alone is the value itself.
    try expectFilter(User, .{ .age = .{ .eq = 5 } }, .{ .age = @as(i64, 5) });
    // Several fields, in the order of the literal.
    try expectFilter(User, .{ .status = .blocked, .email = "ann@example.com" }, .{ .status = "blocked", .email = "ann@example.com" });
}

test "comparisons take values of the field's type, known at compile time or at run time" {
    try expectFilter(User, .{ .age = .{ .gte = 18, .lt = 65 } }, .{ .age = .{ .@"$gte" = @as(i64, 18), .@"$lt" = @as(i64, 65) } });
    var min: u16 = 18;
    _ = &min;
    try expectFilter(User, .{ .age = .{ .gte = min, .lt = 65 } }, .{ .age = .{ .@"$gte" = @as(i64, 18), .@"$lt" = @as(i64, 65) } });
    try expectFilter(User, .{ .email = .{ .gt = "m" } }, .{ .email = .{ .@"$gt" = "m" } });
    try expectFilter(Account, .{ .score = .{ .gt = 1.5 } }, .{ .score = .{ .@"$gt" = 1.5 } });
    try expectFilter(User, .{ .age = .{ .ne = 3 } }, .{ .age = .{ .@"$ne" = @as(i64, 3) } });
    try expectFilter(User, .{ .age = .{ .exists = true } }, .{ .age = .{ .@"$exists" = true } });
    var exists = false;
    _ = &exists;
    try expectFilter(Account, .{ .nickname = .{ .exists = exists } }, .{ .nickname = .{ .@"$exists" = false } });
    // A runtime value of an optional field, with a value and without.
    var nickname: ?[]const u8 = "ann";
    try expectFilter(Account, .{ .nickname = nickname }, .{ .nickname = "ann" });
    nickname = null;
    try expectFilter(Account, .{ .nickname = nickname }, .{ .nickname = null });
}

test "in and nin take a tuple or a slice of values of the field" {
    try expectFilter(User, .{ .status = .{ .in = .{ .active, .blocked } } }, .{ .status = .{ .@"$in" = .{ "active", "blocked" } } });
    const statuses: []const User.Status = &.{ .active, .blocked };
    try expectFilter(User, .{ .status = .{ .in = statuses } }, .{ .status = .{ .@"$in" = .{ "active", "blocked" } } });
    try expectFilter(User, .{ .age = .{ .nin = .{ 1, 2 } } }, .{ .age = .{ .@"$nin" = .{ @as(i64, 1), @as(i64, 2) } } });
    // A tuple of a runtime value and a value known at compile time.
    var x: u32 = 7;
    _ = &x;
    try expectFilter(User, .{ .age = .{ .in = .{ x, 2 } } }, .{ .age = .{ .@"$in" = .{ @as(i64, 7), @as(i64, 2) } } });
    // null among the values of an optional field.
    try expectFilter(Account, .{ .nickname = .{ .in = .{ null, "ann" } } }, .{ .nickname = .{ .@"$in" = .{ null, "ann" } } });
}

test "regex takes a pattern or a bson.Regex, and not a literal of operators" {
    try expectFilter(User, .{ .email = .{ .regex = "@example\\.com$" } }, .{ .email = .{ .@"$regex" = "@example\\.com$" } });
    const re: bson.Regex = .{ .pattern = "@example\\.com$", .options = "i" };
    try expectFilter(User, .{ .email = .{ .regex = re } }, .{ .email = .{ .@"$regex" = re } });
    try expectFilter(User, .{ .age = .{ .not = .{ .gt = 5 } } }, .{ .age = .{ .@"$not" = .{ .@"$gt" = @as(i64, 5) } } });
    // Inside not, eq keeps its operator.
    try expectFilter(User, .{ .age = .{ .not = .{ .eq = 5 } } }, .{ .age = .{ .@"$not" = .{ .@"$eq" = @as(i64, 5) } } });
    try expectFilter(User, .{ .email = .{ .not = re } }, .{ .email = .{ .@"$not" = re } });
}

test "null matches a field that is null or missing" {
    try expectFilter(User, .{ .profile = null }, .{ .profile = null });
    try expectFilter(Account, .{ .nickname = null, .score = .{ .exists = false } }, .{ .nickname = null, .score = .{ .@"$exists" = false } });
}

test "and, or and nor take a tuple of filters" {
    try expectFilter(User, .{ .@"or" = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }, .{
        .@"$or" = .{ .{ .age = .{ .@"$lt" = @as(i64, 18) } }, .{ .status = "blocked" } },
    });
    try expectFilter(User, .{ .@"and" = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }, .{
        .@"$and" = .{ .{ .age = .{ .@"$lt" = @as(i64, 18) } }, .{ .status = "blocked" } },
    });
    try expectFilter(User, .{ .nor = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }, .{
        .@"$nor" = .{ .{ .age = .{ .@"$lt" = @as(i64, 18) } }, .{ .status = "blocked" } },
    });
    // Next to fields, one filter alone, an empty one, and one inside another.
    try expectFilter(User, .{ .status = .active, .@"or" = .{.{ .email = "a@b" }} }, .{
        .status = "active",
        .@"$or" = .{.{ .email = "a@b" }},
    });
    try expectFilter(User, .{ .@"or" = .{ .{}, .{ .@"and" = .{.{ .age = 1 }} } } }, .{
        .@"$or" = .{ .{}, .{ .@"$and" = .{.{ .age = @as(i64, 1) }} } },
    });
}

test "values that BSON cannot hold are EncodeFailed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "\xff";
    _ = &bad;
    try testing.expectError(error.EncodeFailed, filter.encode(User, arena.allocator(), .{ .email = bad }));
    try testing.expectError(error.EncodeFailed, filter.encode(User, arena.allocator(), .{ .email = .{ .in = .{ "a", bad } } }));
    // A regular expression with a NUL byte, as a pattern or a bson.Regex.
    var nul: []const u8 = "a\x00b";
    _ = &nul;
    try testing.expectError(error.EncodeFailed, filter.encode(User, arena.allocator(), .{ .email = .{ .regex = nul } }));
    const re: bson.Regex = .{ .pattern = nul, .options = "" };
    try testing.expectError(error.EncodeFailed, filter.encode(User, arena.allocator(), .{ .email = .{ .regex = re } }));
}

const paris: User.Profile = .{ .city = "Paris", .country = "FR" };

test "a literal on a struct is conditions on the paths of its fields" {
    try expectFilter(User, .{ .profile = .{ .city = "Paris" } }, .{ .@"profile.city" = "Paris" });
    try expectFilter(User, .{ .profile = .{ .city = .{ .in = .{ "Paris", "Lyon" } } } }, .{ .@"profile.city" = .{ .@"$in" = .{ "Paris", "Lyon" } } });
    try expectFilter(Account, .{ .address = .{ .city = "Lyon", .country = "FR" } }, .{ .@"address.city" = "Lyon", .@"address.country" = "FR" });
    // A path into an optional struct may be missing, so it takes null.
    try expectFilter(User, .{ .profile = .{ .city = null } }, .{ .@"profile.city" = null });
    try expectFilter(Account, .{ .address = .{ .zip = .{ .exists = false } } }, .{ .@"address.zip" = .{ .@"$exists" = false } });
}

test "a whole document only with eq, written without its null optionals" {
    try expectFilter(User, .{ .profile = .{ .eq = paris } }, .{ .profile = .{ .city = "Paris", .country = "FR" } });
    const lyon: models.Address = .{ .city = "Lyon", .country = "FR" };
    try expectFilter(Account, .{ .address = .{ .eq = lyon } }, .{ .address = .{ .city = "Lyon", .country = "FR" } });
    try expectFilter(Account, .{ .address = .{ .ne = lyon } }, .{ .address = .{ .@"$ne" = .{ .city = "Lyon", .country = "FR" } } });
    // The operators of the struct field itself.
    try expectFilter(User, .{ .profile = .{ .exists = false } }, .{ .profile = .{ .@"$exists" = false } });
    var maybe: ?User.Profile = null;
    try expectFilter(User, .{ .profile = .{ .eq = maybe } }, .{ .profile = null });
    maybe = paris;
    try expectFilter(User, .{ .profile = .{ .eq = maybe } }, .{ .profile = .{ .city = "Paris", .country = "FR" } });
}

test "a list matches by an item, by all items, by its size or as a whole" {
    try expectFilter(Account, .{ .tags = "admin" }, .{ .tags = "admin" });
    try expectFilter(Account, .{ .tags = .{ .all = .{ "a", "b" } } }, .{ .tags = .{ .@"$all" = .{ "a", "b" } } });
    try expectFilter(Account, .{ .tags = .{ .size = 2 } }, .{ .tags = .{ .@"$size" = @as(i64, 2) } });
    try expectFilter(Account, .{ .tags = .{ .in = .{ "a", "b" } } }, .{ .tags = .{ .@"$in" = .{ "a", "b" } } });
    const list: []const []const u8 = &.{ "a", "b" };
    try expectFilter(Account, .{ .tags = .{ .eq = list } }, .{ .tags = .{ "a", "b" } });
    try expectFilter(Account, .{ .tags = .{ .eq = .{ "a", "b" } } }, .{ .tags = .{ "a", "b" } });
    try expectFilter(Account, .{ .tags = .{ .gt = "m", .not = .{ .size = 0 } } }, .{ .tags = .{ .@"$gt" = "m", .@"$not" = .{ .@"$size" = @as(i64, 0) } } });
    var n: u16 = 3;
    _ = &n;
    try expectFilter(Account, .{ .tags = .{ .size = n } }, .{ .tags = .{ .@"$size" = @as(i64, 3) } });
    // An optional list takes null; its items are strings still.
    try expectFilter(Account, .{ .labels = null }, .{ .labels = null });
    try expectFilter(Account, .{ .labels = "x" }, .{ .labels = "x" });
}

test "a literal on a list of structs is paths through it, and elem_match one item" {
    try expectFilter(Account, .{ .items = .{ .sku = "x" } }, .{ .@"items.sku" = "x" });
    try expectFilter(Account, .{ .items = .{ .elem_match = .{ .sku = "x", .qty = .{ .gt = 5 } } } }, .{
        .items = .{ .@"$elemMatch" = .{ .sku = "x", .qty = .{ .@"$gt" = @as(i64, 5) } } },
    });
    try expectFilter(Account, .{ .tags = .{ .elem_match = .{ .regex = "^a" } } }, .{ .tags = .{ .@"$elemMatch" = .{ .@"$regex" = "^a" } } });
    // Inside elem_match, eq keeps its operator on an item of values.
    try expectFilter(Account, .{ .tags = .{ .elem_match = .{ .eq = "a" } } }, .{ .tags = .{ .@"$elemMatch" = .{ .@"$eq" = "a" } } });
    // An item that a list holds, as a whole document.
    const item: models.Item = .{ .sku = "x", .qty = 2 };
    try expectFilter(Account, .{ .items = item }, .{ .items = .{ .sku = "x", .qty = @as(i64, 2) } });
    try expectFilter(Account, .{ .items = .{ .in = .{item} } }, .{ .items = .{ .@"$in" = .{.{ .sku = "x", .qty = @as(i64, 2) }} } });
}
