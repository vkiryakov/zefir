//! Tests of odm.Collection on odm.testing.FakeDriver: what each operation
//! sends to the driver (the journal of the fake), what it gives back, and
//! the diagnostics of the session after it.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
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
    try testing.expect(d.cause == null);
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
