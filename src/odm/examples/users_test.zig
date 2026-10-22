//! Tests of the users of the shop without MongoDB. Each runs `Users` on a
//! registry whose driver is `odm.testing.FakeDriver`: it runs no query,
//! answers an operation with the reply that the test queued, and keeps a
//! journal of what odm sent it, for the test to check.

const std = @import("std");
const odm = @import("odm");
const bson = @import("mongo-bson");
const models = @import("models.zig");
const Users = @import("Users.zig");
const testing = std.testing;
const FakeDriver = odm.testing.FakeDriver;

const now: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const ann: Users.SignUp = .{ .email = "ann@example.com", .name = "Ann", .address = .{ .city = "Lisbon", .country = "PT" } };

test "the models of the shop are well formed" {
    // Zig checks only the code that is used: this checks every model, used
    // or not, as a build of the service would.
    comptime {
        odm.assertModel(models.User);
        odm.assertModel(models.Visit);
        odm.assertModel(models.Product);
    }
}

/// A registry on the fake, with the tenant acme on the database "acme", as
/// the service sets it up. `init` it in place, and give its sessions back
/// before its `deinit`.
const Shop = struct {
    fake: FakeDriver,
    registry: odm.Registry,

    fn init(shop: *Shop, io: std.Io) !void {
        shop.fake = .init(testing.allocator);
        errdefer shop.fake.deinit();
        shop.registry = .init(testing.allocator, io, shop.fake.driver(), .{});
        errdefer shop.registry.deinit(io);
        try shop.registry.registerConnection(io, "main", .{ .uri = "fake://shop" });
        try shop.registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });
    }

    fn deinit(shop: *Shop, io: std.Io) void {
        shop.registry.deinit(io);
        shop.fake.deinit();
    }

    /// The latest call that odm sent the driver.
    fn last(shop: *Shop, io: std.Io) FakeDriver.Call {
        const journal = shop.fake.journal(io);
        return journal[journal.len - 1].call;
    }
};

test "a sign-up is one insert of one document, with the id that odm made" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io);
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users: Users = .init(&acme);

    const id = try users.signUp(io, .root, ann, now);

    // One insert into acme.users, of one document.
    const insert = shop.last(io).insert;
    try testing.expectEqualStrings("acme", insert.ns.database);
    try testing.expectEqualStrings("users", insert.ns.collection);
    try testing.expectEqual(@as(usize, 1), insert.documents.len);
    // Its _id comes first, and signUp returned it.
    const doc = insert.documents[0];
    const first = (try doc.first()).?;
    try testing.expectEqualStrings("_id", first.key);
    try testing.expectEqualSlices(u8, &id.bytes, &first.value.object_id.bytes);
    try testing.expectEqualStrings("ann@example.com", (try doc.get("email")).?.string);
    // No null went out: Ann has no nickname.
    try testing.expectEqual(@as(?bson.Value, null), try doc.get("nickname"));
}

test "a second sign-up with the same e-mail is EmailTaken" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io);
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users: Users = .init(&acme);

    // The fake refuses the next write, as the unique index of mongod does.
    try shop.fake.reply("fake://shop", .{ .failure = .{
        .err = error.DuplicateKey,
        .code = 11000,
        .index = 0,
        .message = "E11000 duplicate key error collection: acme.users index: email_1",
    } });
    try testing.expectError(error.EmailTaken, users.signUp(io, .root, ann, now));
    // The session keeps what the driver said.
    try testing.expectEqual(@as(?i32, 11000), acme.diagnostics().code);
}

test "a bad e-mail is refused before anything goes out" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io);
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users: Users = .init(&acme);
    const sent = shop.fake.journal(io).len;

    var bad = ann;
    bad.email = "ann at example";
    try testing.expectError(error.ValidationFailed, users.signUp(io, .root, bad, now));
    try testing.expectEqualStrings("email", acme.diagnostics().path());
    try testing.expectEqual(sent, shop.fake.journal(io).len);
}

test "byEmail asks for one user by e-mail, and reads it into a User" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io);
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users: Users = .init(&acme);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The fake answers the next find with Ann, as another program wrote
    // her: without an id or a nickname.
    const doc = try bson.encode(arena.allocator(), .{
        .email = "ann@example.com",
        .name = "Ann",
        .address = .{ .city = "Lisbon", .country = "PT" },
        .createdAt = now,
    }, .{});
    try shop.fake.reply("fake://shop", .{ .documents = &.{doc.raw()} });
    const found = (try users.byEmail(io, .root, arena.allocator(), "ann@example.com")).?;
    try testing.expectEqualStrings("Ann", found.name);
    try testing.expectEqualStrings("Lisbon", found.address.city);
    try testing.expectEqual(@as(?[]const u8, null), found.nickname);

    // findOne is a find of the e-mail, for one document.
    const find = shop.last(io).find;
    try testing.expectEqualStrings("ann@example.com", (try find.filter.get("email")).?.string);
    try testing.expectEqual(@as(u32, 1), find.limit);
}

test "rename says whether the user was there" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io);
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users: Users = .init(&acme);
    const id = try bson.ObjectId.parseHex("6ad571408b9f503e4a218a8b");

    // Without a reply the fake answers a write with zeros: no user matched.
    try testing.expect(!try users.rename(io, .root, id, "Ann B."));
    try shop.fake.reply("fake://shop", .{ .write = .{ .matched = 1, .modified = 1 } });
    try testing.expect(try users.rename(io, .root, id, "Ann B."));

    // An update of the user's id, which sets the name.
    const update = shop.last(io).update;
    try testing.expectEqualSlices(u8, &id.bytes, &(try update.filter.get("_id")).?.object_id.bytes);
    try testing.expectEqualStrings("Ann B.", (try update.update.getPath("$set.name")).?.string);
}
