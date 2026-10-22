//! Tests of odm.Collection on odm.testing.FakeDriver: what each operation
//! sends to the driver (the journal of the fake), what it gives back, and
//! the diagnostics of the session after it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
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
