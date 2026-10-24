//! Tests of odm.Collection on odm.testing.FakeDriver: what each operation
//! sends to the driver (the journal of the fake), what it gives back, and
//! the diagnostics of the session after it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const filter = @import("../query/filter.zig");
const update = @import("../query/update.zig");
const models = @import("models.zig");
const support = @import("support.zig");
const User = models.User;
const Gen = models.Gen;
const Slug = models.Slug;
const Shop = support.Shop;
const expectDocument = support.expectDocument;

const at: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const given = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;

fn ann(email: []const u8) User {
    return .{ .email = email, .name = "Ann", .created_at = at };
}

test "insertOne of each kind of id" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    // A null id: odm makes an ObjectId, and the document carries it as _id.
    const users = acme.collection(User);
    const made = try users.insertOne(io, .root, ann("ann@example.com"));
    const first = shop.sent(io)[0].call.insert;
    try testing.expectEqualStrings("acme", first.ns.database);
    try testing.expectEqualStrings("users", first.ns.collection);
    try testing.expectEqual(@as(usize, 1), first.documents.len);
    try expectDocument(.{ ._id = made.id, .email = "ann@example.com", .name = "Ann", .age = @as(i64, 0), .status = "active", .createdAt = at }, first.documents[0]);

    // An id given: that one.
    var with_id = ann("bob@example.com");
    with_id.id = given;
    const kept = try users.insertOne(io, .root, with_id);
    try testing.expectEqualSlices(u8, &given.bytes, &kept.id.bytes);
    try expectDocument(.{ ._id = given, .email = "bob@example.com", .name = "Ann", .age = @as(i64, 0), .status = "active", .createdAt = at }, shop.sent(io)[1].call.insert.documents[0]);

    // An id that is a bson.ObjectId: always made, and new each time.
    const gens = acme.collection(Gen);
    const one = try gens.insertOne(io, .root, .{ .n = 3 });
    const two = try gens.insertOne(io, .root, .{});
    try testing.expect(!std.mem.eql(u8, &one.id.bytes, &two.id.bytes));
    try expectDocument(.{ ._id = one.id, .n = @as(i32, 3) }, shop.sent(io)[2].call.insert.documents[0]);
    try expectDocument(.{ ._id = two.id, .n = @as(i32, 0) }, shop.sent(io)[3].call.insert.documents[0]);
    try testing.expectEqualStrings("gens", shop.sent(io)[3].call.insert.ns.collection);

    // An id that the application gives: the result borrows its bytes.
    const slug: []const u8 = "hello-world";
    const page = try acme.collection(Slug).insertOne(io, .root, .{ .id = slug, .title = "Hello" });
    try testing.expectEqual(slug.ptr, page.id.ptr);
    try expectDocument(.{ ._id = "hello-world", .title = "Hello" }, shop.sent(io)[4].call.insert.documents[0]);
    try testing.expectEqualStrings("", acme.diagnostics().message());
}

test "insertOne checks field_rules first" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try testing.expectError(error.ValidationFailed, acme.collection(User).insertOne(io, .root, ann("a@b")));
    const d = acme.diagnostics();
    try testing.expectEqualStrings("validation.min_length", d.violation.?.code);
    try testing.expectEqualStrings("email", d.path());
    try testing.expectEqual(@as(?usize, null), d.index);
    try testing.expect(std.mem.startsWith(u8, d.message(), "odm: email: "));
    try testing.expectEqual(odm.Outcome.not_sent, odm.outcome(error.ValidationFailed));
    // Nothing went to the driver.
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);
}

test "insertMany checks all, encodes all, sends one request" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    // The third is bad: nothing goes out, and the diagnostics name it.
    const bad = [_]User{ ann("ann@example.com"), ann("bob@example.com"), ann("x@y") };
    try testing.expectError(error.ValidationFailed, users.insertMany(io, .root, &bad, arena.allocator()));
    try testing.expectEqual(@as(?usize, 2), acme.diagnostics().index);
    try testing.expectEqualStrings("email", acme.diagnostics().path());
    try testing.expect(std.mem.startsWith(u8, acme.diagnostics().message(), "odm: document 2: email: "));
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);

    // Three good ones: one insert of three, the ids in their order.
    var three = [_]User{ ann("ann@example.com"), ann("bob@example.com"), ann("cid@example.com") };
    three[1].id = given;
    const result = try users.insertMany(io, .root, &three, arena.allocator());
    try testing.expectEqual(@as(usize, 3), result.ids.len);
    try testing.expectEqualSlices(u8, &given.bytes, &result.ids[1].bytes);
    try testing.expectEqual(@as(usize, 1), shop.sent(io).len);
    const insert = shop.sent(io)[0].call.insert;
    try testing.expectEqual(@as(usize, 3), insert.documents.len);
    for (insert.documents, result.ids, three) |doc, id, user| {
        try expectDocument(.{ ._id = id, .email = user.email, .name = "Ann", .age = @as(i64, 0), .status = "active", .createdAt = at }, doc);
    }

    // No document at all is a mistake of the request.
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .root, &.{}, arena.allocator()));
    try testing.expectEqualStrings("odm: insertMany needs at least one document", acme.diagnostics().message());
    try testing.expectEqual(@as(usize, 1), shop.sent(io).len);
}

test "DuplicateKey keeps the index the driver gives" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .failure = .{ .err = error.DuplicateKey, .code = 11000, .index = 1, .message = "E11000 duplicate key error" } });
    const docs = [_]User{ ann("ann@example.com"), ann("ann@example.com"), ann("bob@example.com") };
    try testing.expectError(error.DuplicateKey, acme.collection(User).insertMany(io, .root, &docs, arena.allocator()));
    const d = acme.diagnostics();
    try testing.expectEqual(@as(?i32, 11000), d.code);
    try testing.expectEqual(@as(?usize, 1), d.index);
    try testing.expectEqualStrings("E11000 duplicate key error", d.message());
    try testing.expectEqual(odm.Outcome.may_have_executed, odm.outcome(error.DuplicateKey));
}

test "every call starts with clean diagnostics" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);

    try shop.fake.reply("fake://shared", .{ .failure = .{ .err = error.DuplicateKey, .code = 11000, .index = 0, .message = "E11000 duplicate key error" } });
    try testing.expectError(error.DuplicateKey, users.insertOne(io, .root, ann("ann@example.com")));
    try testing.expectEqual(@as(?i32, 11000), acme.diagnostics().code);

    // A ValidationFailed after it shows nothing of the DuplicateKey.
    try testing.expectError(error.ValidationFailed, users.insertOne(io, .root, ann("a@b")));
    try testing.expectEqual(@as(?i32, null), acme.diagnostics().code);
    try testing.expectEqual(@as(?usize, null), acme.diagnostics().index);
    try testing.expect(acme.diagnostics().violation != null);

    // And a success shows nothing at all.
    _ = try users.insertOne(io, .root, ann("ann@example.com"));
    const d = acme.diagnostics();
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqualStrings("", d.path());
    try testing.expect(d.violation == null);
    try testing.expectEqual(@as(?anyerror, null), d.cause);
    try testing.expectEqual(@as(?i32, null), d.code);
    try testing.expectEqual(@as(?usize, null), d.index);
}

test "stats counts operations and their errors" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    // The registry's own calls are not operations.
    try testing.expectEqual(@as(u64, 0), shop.registry.stats(io).operations);
    _ = try users.insertOne(io, .root, ann("ann@example.com"));
    try testing.expectError(error.ValidationFailed, users.insertOne(io, .root, ann("a@b")));
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .root, &.{}, arena.allocator()));
    try shop.fake.reply("fake://shared", .{ .failure = .{ .err = error.DuplicateKey, .code = 11000, .index = 0 } });
    try testing.expectError(error.DuplicateKey, users.insertOne(io, .root, ann("ann@example.com")));
    _ = try users.insertMany(io, .root, &.{ann("bob@example.com")}, arena.allocator());
    const s = shop.registry.stats(io);
    try testing.expectEqual(@as(u64, 5), s.operations);
    try testing.expectEqual(@as(u64, 3), s.operation_errors);
}

test "updateOne and updateMany send the encoded update" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = acme.collection(User);

    const change = .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } };
    try shop.fake.reply("fake://shared", .{ .write = .{ .matched = 1, .modified = 1 } });
    const one = try users.updateOne(io, .root, .{ .id = given }, change);
    try testing.expectEqual(odm.UpdateResult{ .matched = 1, .modified = 1 }, one);
    const first = shop.sent(io)[0].call.update;
    try testing.expectEqualStrings("users", first.ns.collection);
    try testing.expectEqual(odm.Client.UpdateMode.one, first.mode);
    try testing.expect(!first.upsert);
    try testing.expectEqualSlices(u8, (try filter.encode(User, a, .{ .id = given })).bytes, first.filter.bytes);
    try testing.expectEqualSlices(u8, (try update.encode(User, a, change, .update)).bytes, first.update.bytes);

    // updateMany, with an odm.Update built at run time.
    try shop.fake.reply("fake://shared", .{ .write = .{ .matched = 3, .modified = 2 } });
    const built = odm.Update(User).init(a).with(.{ .set = .{ .name = "Bob" } }).with(.{ .inc = .{ .age = 2 } });
    const many = try users.updateMany(io, .root, .{ .status = .active }, built);
    try testing.expectEqual(odm.UpdateResult{ .matched = 3, .modified = 2 }, many);
    const second = shop.sent(io)[1].call.update;
    try testing.expectEqual(odm.Client.UpdateMode.many, second.mode);
    try expectDocument(.{ .status = "active" }, second.filter);
    try expectDocument(.{ .@"$set" = .{ .name = "Bob" }, .@"$inc" = .{ .age = @as(i64, 2) } }, second.update);
}

test "upsertOne sends upsert" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);

    // A User that the server inserts gets the server's ObjectId.
    try shop.fake.reply("fake://shared", .{ .write = .{ .upserted_id = .{ .object_id = given } } });
    const inserted = try users.upsertOne(io, .root, .{ .email = "ann@example.com" }, .{ .set = .{ .name = "Ann" }, .set_on_insert = .{ .created_at = at } });
    try testing.expectEqualSlices(u8, &given.bytes, &inserted.upserted_id.?.bytes);
    try testing.expectEqual(@as(u64, 0), inserted.matched);
    const sent = shop.sent(io)[0].call.update;
    try testing.expectEqual(odm.Client.UpdateMode.one, sent.mode);
    try testing.expect(sent.upsert);
    try expectDocument(.{ .email = "ann@example.com" }, sent.filter);
    try expectDocument(.{ .@"$set" = .{ .name = "Ann" }, .@"$setOnInsert" = .{ .createdAt = at } }, sent.update);

    // A Slug gets the id of the filter: the caller's bytes.
    const slug: []const u8 = "hello-world";
    try shop.fake.reply("fake://shared", .{ .write = .{ .upserted_id = .{ .string = "hello-world" } } });
    const page = try acme.collection(Slug).upsertOne(io, .root, .{ .id = slug }, .{ .set = .{ .title = "Hello" } });
    try testing.expectEqual(slug.ptr, page.upserted_id.?.ptr);

    // Nothing inserted: no id.
    try shop.fake.reply("fake://shared", .{ .write = .{ .matched = 1, .modified = 1 } });
    const matched = try users.upsertOne(io, .root, .{ .email = "ann@example.com" }, .{ .set = .{ .name = "Ann" }, .set_on_insert = .{ .created_at = at } });
    try testing.expect(matched.upserted_id == null);
    try testing.expectEqual(@as(u64, 1), matched.modified);
}

test "replaceOne checks field_rules and sends the document without _id and null fields" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);

    var bad = ann("a@b");
    bad.id = given;
    try testing.expectError(error.ValidationFailed, users.replaceOne(io, .root, .{ .id = given }, bad));
    try testing.expectEqualStrings("email", acme.diagnostics().path());
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);

    try shop.fake.reply("fake://shared", .{ .write = .{ .matched = 1, .modified = 1 } });
    var good = ann("ann@example.com");
    good.id = given;
    good.age = 31;
    const result = try users.replaceOne(io, .root, .{ .id = given }, good);
    try testing.expectEqual(odm.UpdateResult{ .matched = 1, .modified = 1 }, result);
    const sent = shop.sent(io)[0].call.update;
    try testing.expectEqual(odm.Client.UpdateMode.replace, sent.mode);
    try testing.expect(!sent.upsert);
    try expectDocument(.{ ._id = given }, sent.filter);
    // No _id, which the server keeps, and no profile, which is null.
    try expectDocument(.{ .email = "ann@example.com", .name = "Ann", .age = @as(i64, 31), .status = "active", .createdAt = at }, sent.update);
}

test "deleteMany of .{} deletes everything" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);

    try shop.fake.reply("fake://shared", .{ .write = .{ .deleted = 5 } });
    try testing.expectEqual(odm.DeleteResult{ .deleted = 5 }, try users.deleteMany(io, .root, .{}));
    const all = shop.sent(io)[0].call.delete;
    try testing.expect(all.many);
    try expectDocument(.{}, all.filter);
    try testing.expectEqualStrings("users", all.ns.collection);

    try shop.fake.reply("fake://shared", .{ .write = .{ .deleted = 1 } });
    try testing.expectEqual(odm.DeleteResult{ .deleted = 1 }, try users.deleteOne(io, .root, .{ .status = .deleted }));
    const one = shop.sent(io)[1].call.delete;
    try testing.expect(!one.many);
    try expectDocument(.{ .status = "deleted" }, one.filter);
}

test "values BSON cannot hold are EncodeFailed and send nothing" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    // Known only at run time, so that the compiler cannot refuse them.
    var not_utf8_buffer = "\xff".*;
    const not_utf8: []const u8 = &not_utf8_buffer;
    var nul_buffer = "a\x00b".*;
    const nul: []const u8 = &nul_buffer;

    var doc = ann("ann@example.com");
    doc.name = not_utf8;
    try testing.expectError(error.EncodeFailed, users.insertOne(io, .root, doc));
    try testing.expect(std.mem.startsWith(u8, acme.diagnostics().message(), "odm: the document did not become BSON"));
    try testing.expectError(error.EncodeFailed, users.updateOne(io, .root, .{ .name = not_utf8 }, .{ .set = .{ .age = 1 } }));
    try testing.expect(std.mem.startsWith(u8, acme.diagnostics().message(), "odm: the filter did not become BSON"));
    try testing.expectError(error.EncodeFailed, users.updateOne(io, .root, .{ .age = 1 }, .{ .set = .{ .name = not_utf8 } }));
    try testing.expect(std.mem.startsWith(u8, acme.diagnostics().message(), "odm: the update did not become BSON"));
    const held = odm.Filter(User).init(arena.allocator()).where(.{ .name = not_utf8 });
    try testing.expectError(error.EncodeFailed, users.find(io, .root, held, .{}));
    try testing.expectError(error.EncodeFailed, users.deleteMany(io, .root, held));
    try testing.expectError(error.EncodeFailed, users.find(io, .root, .{ .email = .{ .regex = nul } }, .{}));
    try testing.expectEqual(odm.Outcome.not_sent, odm.outcome(error.EncodeFailed));
    // Nothing reached the driver, and every lease of the cursors went back.
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).leases);
}

test "InvalidArgument of a builder says why" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = acme.collection(User);

    try testing.expectError(error.InvalidArgument, users.updateOne(io, .root, .{}, odm.Update(User).init(a)));
    try testing.expect(std.mem.indexOf(u8, acme.diagnostics().message(), "changes nothing") != null);
    const twice = odm.Update(User).init(a).with(.{ .set = .{ .name = "Ann" } }).with(.{ .set = .{ .name = "Bob" } });
    try testing.expectError(error.InvalidArgument, users.updateMany(io, .root, .{}, twice));
    try testing.expect(std.mem.indexOf(u8, acme.diagnostics().message(), "two with") != null);
    const none: []const odm.Filter(User) = &.{};
    try testing.expectError(error.InvalidArgument, users.count(io, .root, .{ .@"or" = none }));
    try testing.expect(std.mem.indexOf(u8, acme.diagnostics().message(), "empty []const odm.Filter") != null);
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);
}

/// The results of a $group, by their BSON keys.
const Total = struct { _id: []const u8, total: i64 };

test "aggregateRaw sends the pipeline and decodes R by its field names" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    const sort = bson.literal(.{ .@"$sort" = .{ .total = @as(i32, -1) } });
    try shop.fake.reply("fake://shared", .{ .documents = &.{ bson.literal(.{ ._id = "active", .total = @as(i64, 3) }), bson.literal(.{ ._id = "blocked", .total = @as(i64, 1) }) } });
    var totals = try users.aggregateRaw(Total, io, .root, .{
        .{ .@"$match" = .{ .age = .{ .@"$gte" = 18 } } },
        .{ .@"$group" = .{ ._id = "$status", .total = .{ .@"$sum" = 1 } } },
        sort,
    });
    defer totals.deinit(io);
    const sent = shop.sent(io)[0].call.aggregate;
    try testing.expectEqualStrings("users", sent.ns.collection);
    try testing.expectEqual(@as(usize, 3), sent.pipeline.len);
    try expectDocument(.{ .@"$match" = .{ .age = .{ .@"$gte" = 18 } } }, sent.pipeline[0]);
    try expectDocument(.{ .@"$group" = .{ ._id = "$status", .total = .{ .@"$sum" = 1 } } }, sent.pipeline[1]);
    try testing.expectEqualSlices(u8, sort.bytes, sent.pipeline[2].bytes);
    const first = (try totals.next(io, .root, arena.allocator())).?;
    try testing.expectEqualStrings("active", first._id);
    try testing.expectEqual(@as(i64, 3), first.total);
    try testing.expectEqual(@as(i64, 1), (try totals.next(io, .root, arena.allocator())).?.total);
    try testing.expect(try totals.next(io, .root, arena.allocator()) == null);

    // A slice of stages, and a result that does not fit R.
    try shop.fake.reply("fake://shared", .{ .documents = &.{bson.literal(.{ ._id = "x" })} });
    const stages = [_]bson.RawDocument{sort};
    var short = try users.aggregateRaw(Total, io, .root, &stages);
    defer short.deinit(io);
    try testing.expectEqual(@as(usize, 1), shop.sent(io)[1].call.aggregate.pipeline.len);
    try testing.expectError(error.DecodeFailed, short.next(io, .root, arena.allocator()));
    try testing.expectEqual(@as(?anyerror, error.MissingField), short.diagnostics().cause);
    try testing.expectEqualStrings("total", short.diagnostics().path());
}

/// A model with indexes of every kind.
const Event = struct {
    id: ?bson.ObjectId = null,
    bio: []const u8,
    x: i64,
    at: bson.DateTime,
    nick: ?[]const u8 = null,
    place: Place,

    pub const Place = struct { city: []const u8 };

    pub const odm_schema: odm.Schema(Event) = .{
        .collection = "events",
        .id = .id,
        .names = .{ .at = "happenedAt" },
        .indexes = &.{
            .{ .keys = &.{.{ .nick = .asc }}, .unique = true, .sparse = true },
            .{ .keys = &.{.{ .at = .asc }}, .expire_after_seconds = 3600 },
            .{ .keys = &.{.{ .bio = .text }} },
            .{ .keys = &.{.{ .x = .hashed }} },
            .{ .keys = &.{ .{ .@"place.city" = .asc }, .{ .x = .desc } }, .name = "by_city" },
        },
    };
};

test "ensureIndexes sends the schema's indexes" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try acme.collection(User).ensureIndexes(io, .root);
    const users = shop.sent(io)[0].call.create_indexes;
    try testing.expectEqualStrings("users", users.ns.collection);
    try testing.expectEqual(@as(usize, 2), users.indexes.len);
    try testing.expectEqualStrings("email_1", users.indexes[0].name);
    try testing.expect(users.indexes[0].unique and !users.indexes[0].sparse);
    try expectDocument(.{ .email = @as(i32, 1) }, users.indexes[0].keys);
    try testing.expectEqualStrings("status_1_createdAt_-1", users.indexes[1].name);
    try testing.expect(!users.indexes[1].unique);
    try expectDocument(.{ .status = @as(i32, 1), .createdAt = @as(i32, -1) }, users.indexes[1].keys);

    try acme.collection(Event).ensureIndexes(io, .root);
    const events = shop.sent(io)[1].call.create_indexes.indexes;
    try testing.expectEqual(@as(usize, 5), events.len);
    try testing.expectEqualStrings("nick_1", events[0].name);
    try testing.expect(events[0].unique and events[0].sparse);
    try testing.expectEqualStrings("happenedAt_1", events[1].name);
    try testing.expectEqual(@as(?u32, 3600), events[1].expire_after_seconds);
    try expectDocument(.{ .happenedAt = @as(i32, 1) }, events[1].keys);
    try testing.expectEqualStrings("bio_text", events[2].name);
    try expectDocument(.{ .bio = "text" }, events[2].keys);
    try testing.expectEqualStrings("x_hashed", events[3].name);
    try expectDocument(.{ .x = "hashed" }, events[3].keys);
    try testing.expectEqual(@as(?u32, null), events[3].expire_after_seconds);
    try testing.expectEqualStrings("by_city", events[4].name);
    try expectDocument(.{ .@"place.city" = @as(i32, 1), .x = @as(i32, -1) }, events[4].keys);

    // A model without indexes has nothing to send.
    try acme.collection(Gen).ensureIndexes(io, .root);
    try testing.expectEqual(@as(usize, 2), shop.sent(io).len);
}

test "runCommand copies the reply into the arena" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    const answer = bson.literal(.{ .ok = 1.0, .n = @as(i32, 7) });
    try shop.fake.reply("fake://shared", .{ .command = answer });
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const reply = try acme.runCommand(io, .root, .{ .collStats = "users" }, fixed.allocator());
    try testing.expectEqualSlices(u8, answer.bytes, reply.bytes);
    try testing.expect(fixed.ownsPtr(@constCast(reply.bytes.ptr)));
    const sent = shop.sent(io)[0].call.command;
    try testing.expectEqualStrings("acme", sent.database);
    try expectDocument(.{ .collStats = "users" }, sent.body);
    try testing.expectEqual(@as(u64, 1), shop.registry.stats(io).operations);

    // The diagnostics of the session are those of the command.
    try shop.fake.reply("fake://shared", .{ .failure = .{ .err = error.CommandFailed, .code = 59, .message = "no such command: 'nope'" } });
    try testing.expectError(error.CommandFailed, acme.runCommand(io, .root, .{ .nope = 1 }, fixed.allocator()));
    try testing.expectEqual(@as(?i32, 59), acme.diagnostics().code);
    try testing.expectEqual(@as(u64, 1), shop.registry.stats(io).operation_errors);
}

/// A driver whose clients have only the operations that every driver has.
const Bare = struct {
    client: BareClient = .{},

    pub const name = "bare";

    pub fn open(d: *Bare, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client {
        _ = io;
        _ = config;
        return .init(&d.client);
    }
};

const BareClient = struct {
    n: u8 = 0,

    pub const capabilities: odm.Capabilities = .{};

    pub fn connect(_: *BareClient, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
    pub fn ping(_: *BareClient, _: Io, _: core.Context, _: ?*odm.Diagnostics) odm.DriverError!void {}
    pub fn close(_: *BareClient, _: Io) void {}
    pub fn deinit(_: *BareClient) void {}
    pub fn stats(_: *BareClient) ?odm.Client.PoolStats {
        return null;
    }
    pub fn insert(_: *BareClient, _: Io, _: core.Context, _: *const odm.Client.InsertRequest, _: odm.Client.CallOptions) odm.DriverError!odm.Client.InsertResult {
        return .{ .inserted = 0 };
    }
    pub fn update(_: *BareClient, _: Io, _: core.Context, _: *const odm.Client.UpdateRequest, _: odm.Client.CallOptions) odm.DriverError!odm.Client.UpdateResult {
        return .{ .matched = 0, .modified = 0 };
    }
    pub fn delete(_: *BareClient, _: Io, _: core.Context, _: *const odm.Client.DeleteRequest, _: odm.Client.CallOptions) odm.DriverError!odm.Client.DeleteResult {
        return .{ .deleted = 0 };
    }
    pub fn find(_: *BareClient, _: Io, _: core.Context, _: *const odm.Client.FindRequest, _: odm.Client.CallOptions) odm.DriverError!odm.RawCursor {
        return error.Unavailable;
    }
};

test "a driver without a capability gives Unsupported" {
    const io = testing.io;
    var bare: Bare = .{};
    var registry: odm.Registry = .init(testing.allocator, io, odm.Driver.init(&bare), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "bare-1", .{ .uri = "bare://1" });
    try registry.connect(io, .root, "bare-1");
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "bare-1" }, .database = "acme", .version = 1 });
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    try testing.expectError(error.Unsupported, users.aggregateRaw(Total, io, .root, .{.{ .@"$match" = .{} }}));
    try testing.expectEqualStrings("odm: the driver has no capability 'aggregate'", acme.diagnostics().message());
    try testing.expectError(error.Unsupported, users.count(io, .root, .{}));
    try testing.expectEqualStrings("odm: the driver has no capability 'count'", acme.diagnostics().message());
    try testing.expectError(error.Unsupported, users.ensureIndexes(io, .root));
    try testing.expectEqualStrings("odm: the driver has no capability 'indexes'", acme.diagnostics().message());
    try testing.expectError(error.Unsupported, acme.runCommand(io, .root, .{ .ping = 1 }, arena.allocator()));
    try testing.expectEqualStrings("odm: the driver has no capability 'command'", acme.diagnostics().message());
    try testing.expectEqual(odm.Outcome.not_sent, odm.outcome(error.Unsupported));
    // The cursor of the aggregate that did not open gave its lease back.
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), s.leases);
    try testing.expectEqual(@as(u64, 4), s.operation_errors);
}
