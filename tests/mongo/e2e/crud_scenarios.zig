//! The collection API against mongod: scenarios that take a
//! `mongo.Database` and the limit its client batches writes by. crud.zig
//! runs them on a client of mongod and on one of a FakeServer that relays
//! to mongod. Each scenario works in collections of its own, which it
//! drops before and after.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;

pub const Scenario = struct {
    name: []const u8,
    run: *const fn (io: Io, db: mongo.Database, server: Server) anyerror!void,
};

/// What the server of the client says in its hello.
pub const Server = struct {
    /// The most items of a write in one batch: mongod's own, or that of the
    /// script of a FakeServer.
    max_write_batch_size: usize = 100_000,
};

/// The scenarios, in their order.
pub const scenarios = [_]Scenario{
    .{ .name = "the _ids that inserts made are read back", .run = madeIds },
    .{ .name = "a unique index refuses a duplicate: WriteFailed 11000 at its index", .run = duplicateKey },
    .{ .name = "an unordered insertMany inserts all but its duplicates", .run = unorderedDuplicates },
    .{ .name = "findOneAndUpdate before and after, findOneAndReplace, findOneAndDelete", .run = findAndModify },
    .{ .name = "upserts, updates, replaces and deletes", .run = upserts },
    .{ .name = "find of 250 documents in batches of 7, with a filter, a projection, a skip and a limit; findOne", .run = findMany },
    .{ .name = "countDocuments, estimatedDocumentCount, distinct and aggregate", .run = counts },
    .{ .name = "createIndexes names its indexes, listIndexes lists them, dropIndex and dropIndexes drop them", .run = indexes },
    .{ .name = "listCollections, runCommand, runCursorCommand, a drop twice and Database.drop", .run = collections },
};

/// Runs every scenario on `db`, whose client talks to `server`, and names
/// the one that fails.
pub fn runAll(io: Io, db: mongo.Database, server: Server) !void {
    for (scenarios) |scenario| {
        scenario.run(io, db, server) catch |err| {
            std.debug.print("scenario '{s}': {t}\n", .{ scenario.name, err });
            return err;
        };
    }
}

/// Under a deadline, so that every command takes maxTimeMS to mongod and
/// a server that stops answering fails the scenario.
fn op(io: Io) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(30))));
}

/// Prints the diagnostics of `err`, and returns it.
fn report(err: anyerror, d: *const mongo.Diagnostics, comptime what: []const u8) anyerror {
    std.debug.print(what ++ ": {t}: {s}\n", .{ err, d.message() });
    return err;
}

/// Runs `body` through the client of `db`, and frees the reply.
fn command(io: Io, db: mongo.Database, body: bson.RawDocument) !void {
    var d: mongo.Diagnostics = .{};
    const reply = db.client.runCommand(io, op(io), .{ .database = db.name, .body = body }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "a command");
    reply.deinit();
}

/// Drops the collection `name`; one that is not there is no error.
fn drop(io: Io, db: mongo.Database, name: []const u8) !void {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putString("drop", name);
    const body = try b.finish();
    defer body.deinit();
    var d: mongo.Diagnostics = .{};
    if (db.client.runCommand(io, op(io), .{ .database = db.name, .body = body.raw() }, .{ .allocator = testing.allocator, .diagnostics = &d })) |reply| {
        reply.deinit();
    } else |err| {
        if (err == error.CommandFailed and d.server != null and d.server.?.code == 26) return;
        return report(err, &d, "drop");
    }
}

/// The documents of `name`, sorted by `n`, copied into `arena`.
fn all(io: Io, db: mongo.Database, arena: std.mem.Allocator, name: []const u8) ![]const bson.RawDocument {
    const body = try bson.encode(arena, .{ .find = name, .filter = .{}, .sort = .{ .n = 1, ._id = 1 } }, .{});
    var d: mongo.Diagnostics = .{};
    const cursor = db.client.openCursor(io, op(io), .{ .database = db.name, .body = body.raw() }, .{ .diagnostics = &d }) catch |err|
        return report(err, &d, "find");
    defer cursor.deinit(io);
    var found: std.ArrayList(bson.RawDocument) = .empty;
    while (cursor.next(io, op(io)) catch |err| return report(err, &d, "next")) |doc| {
        try found.append(arena, .{ .bytes = try arena.dupe(u8, doc.bytes) });
    }
    return found.items;
}

fn expectDocument(expected: bson.RawDocument, got: ?bson.OwnedDocument) !void {
    const doc = got orelse {
        std.debug.print("expected {f}, got null\n", .{expected});
        return error.TestExpectedDocument;
    };
    defer doc.deinit();
    if (!std.mem.eql(u8, expected.bytes, doc.bytes)) {
        std.debug.print("expected {f}, got {f}\n", .{ expected, doc.raw() });
        return error.TestUnexpectedDocument;
    }
}

fn madeIds(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_ids";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    const users = db.collection(name);
    var d: mongo.Diagnostics = .{};

    const Doc = struct { _id: ?bson.ObjectId = null, n: i32 };
    var docs: [10]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ .n = @intCast(i) };
    var many = users.insertMany(io, op(io), &docs, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertMany");
    defer many.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 10), many.inserted);
    try testing.expectEqual(@as(usize, 10), many.answered);
    var raw_one = users.insertOne(io, op(io), bson.literal(.{ .n = 10 }), .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertOne of a RawDocument");
    defer raw_one.deinit(testing.allocator);
    var named = users.insertOne(io, op(io), .{ ._id = "eleven", .n = 11 }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertOne with an _id");
    defer named.deinit(testing.allocator);
    try testing.expectEqualStrings("eleven", named.inserted_id.string);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stored = try all(io, db, arena.allocator(), name);
    try testing.expectEqual(@as(usize, 12), stored.len);
    for (stored, 0..) |doc, i| {
        // mongod stores the _id first.
        const first = (try doc.first()).?;
        try testing.expectEqualStrings("_id", first.key);
        try testing.expectEqual(@as(i64, @intCast(i)), try (try doc.get("n")).?.asI64());
        switch (i) {
            0...9 => {
                try testing.expectEqualSlices(u8, &many.inserted_ids[i].object_id.bytes, &first.value.object_id.bytes);
                for (many.inserted_ids[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, &earlier.object_id.bytes, &first.value.object_id.bytes));
            },
            10 => try testing.expectEqualSlices(u8, &raw_one.inserted_id.object_id.bytes, &first.value.object_id.bytes),
            else => try testing.expectEqualStrings("eleven", first.value.string),
        }
    }
}

fn duplicateKey(io: Io, db: mongo.Database, server: Server) anyerror!void {
    const name = "crud_unique";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    try command(io, db, bson.literal(.{ .createIndexes = name, .indexes = .{.{ .key = .{ .email = 1 }, .name = "email_1", .unique = true }} }));
    const users = db.collection(name);
    var d: mongo.Diagnostics = .{};

    var ann = users.insertOne(io, op(io), .{ .email = "ann@example.com", .n = 0 }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertOne");
    ann.deinit(testing.allocator);
    var partial: mongo.Collection.InsertOneResult = .{};
    defer partial.deinit(testing.allocator);
    try testing.expectError(error.WriteFailed, users.insertOne(io, op(io), .{ .email = "ann@example.com", .n = 1 }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .partial = &partial,
    }));
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
    try testing.expect(std.mem.find(u8, d.message(), "E11000") != null);
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 0), partial.write_errors[0].index);
    try testing.expect(partial.inserted_id == .object_id);

    // Ordered: the duplicate at index 5 stops the write in its batch, and
    // no batch goes after it, so answered ends with that batch: 6 at a
    // maxWriteBatchSize of 3, all 10 in the one batch of mongod's limit.
    const batch = server.max_write_batch_size;
    const Doc = struct { email: []const u8, n: i32 };
    var docs: [10]Doc = undefined;
    var emails: [10][16]u8 = undefined;
    for (&docs, &emails, 0..) |*doc, *email, i| {
        doc.* = .{ .email = try std.fmt.bufPrint(email, "user{d}@x.org", .{i}), .n = @intCast(i + 1) };
    }
    docs[5].email = "ann@example.com";
    var many: mongo.Collection.InsertManyResult = .{};
    defer many.deinit(testing.allocator);
    try testing.expectError(error.WriteFailed, users.insertMany(io, op(io), &docs, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &many }));
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
    try testing.expectEqual(@as(u64, 5), many.inserted);
    try testing.expectEqual(@min(docs.len, (5 / batch + 1) * batch), many.answered);
    try testing.expectEqual(@as(usize, 1), many.write_errors.len);
    try testing.expectEqual(@as(usize, 5), many.write_errors[0].index);
    try testing.expectEqual(@as(i32, 11000), many.write_errors[0].code);
    try testing.expectEqual(@as(usize, 10), many.inserted_ids.len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stored = try all(io, db, arena.allocator(), name);
    try testing.expectEqual(@as(usize, 6), stored.len);
    for (stored[1..], many.inserted_ids[0..5]) |doc, made| {
        try testing.expectEqualSlices(u8, &made.object_id.bytes, &(try doc.get("_id")).?.object_id.bytes);
    }
}

fn unorderedDuplicates(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_unordered";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    try command(io, db, bson.literal(.{ .createIndexes = name, .indexes = .{.{ .key = .{ .email = 1 }, .name = "email_1", .unique = true }} }));
    const users = db.collection(name);

    const Doc = struct { email: []const u8, n: i32 };
    var docs: [10]Doc = undefined;
    var emails: [10][16]u8 = undefined;
    for (&docs, &emails, 0..) |*doc, *email, i| {
        doc.* = .{ .email = try std.fmt.bufPrint(email, "u{d}@x.org", .{i}), .n = @intCast(i) };
    }
    docs[2].email = docs[0].email;
    docs[7].email = docs[4].email;
    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.WriteFailed, users.insertMany(io, op(io), &docs, .{
        .allocator = testing.allocator,
        .ordered = false,
        .diagnostics = &d,
        .partial = &partial,
    }));
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
    try testing.expectEqual(@as(u64, 8), partial.inserted);
    try testing.expectEqual(@as(usize, 10), partial.answered);
    try testing.expectEqual(@as(usize, 2), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 2), partial.write_errors[0].index);
    try testing.expectEqual(@as(usize, 7), partial.write_errors[1].index);
    for (partial.write_errors) |refused| try testing.expectEqual(@as(i32, 11000), refused.code);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stored = try all(io, db, arena.allocator(), name);
    try testing.expectEqual(@as(usize, 8), stored.len);
    var at: usize = 0;
    for (partial.inserted_ids, 0..) |made, i| {
        if (i == 2 or i == 7) continue;
        try testing.expectEqualSlices(u8, &made.object_id.bytes, &(try stored[at].get("_id")).?.object_id.bytes);
        at += 1;
    }
}

fn findAndModify(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_find_and_modify";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    const users = db.collection(name);
    var d: mongo.Diagnostics = .{};
    var seeded = users.insertMany(io, op(io), .{ .{ ._id = 1, .n = 1 }, .{ ._id = 2, .n = 5 } }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertMany");
    seeded.deinit(testing.allocator);
    const a = testing.allocator;

    try expectDocument(bson.literal(.{ ._id = 1, .n = 1 }), try users.findOneAndUpdate(io, op(io), .{ ._id = 1 }, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = a }));
    try expectDocument(bson.literal(.{ ._id = 1, .n = 3 }), try users.findOneAndUpdate(io, op(io), .{ ._id = 1 }, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = a, .return_document = .after }));
    try expectDocument(bson.literal(.{ .n = 4 }), try users.findOneAndUpdate(io, op(io), .{ ._id = 1 }, .{ .@"$inc" = .{ .n = 1 } }, .{
        .allocator = a,
        .return_document = .after,
        .projection = bson.literal(.{ ._id = 0, .n = 1 }),
    }));
    // Of the two, the one that the sort puts first.
    try expectDocument(bson.literal(.{ ._id = 2, .n = 6 }), try users.findOneAndUpdate(io, op(io), .{}, .{ .@"$inc" = .{ .n = 1 } }, .{
        .allocator = a,
        .sort = bson.literal(.{ .n = -1 }),
        .return_document = .after,
    }));
    // A pipeline.
    try expectDocument(bson.literal(.{ ._id = 1, .n = 4, .tag = "four" }), try users.findOneAndUpdate(io, op(io), .{ ._id = 1 }, .{.{ .@"$set" = .{ .tag = "four" } }}, .{
        .allocator = a,
        .return_document = .after,
    }));
    try testing.expect(try users.findOneAndUpdate(io, op(io), .{ ._id = 9 }, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = a }) == null);

    try expectDocument(bson.literal(.{ ._id = 2, .n = 6 }), try users.findOneAndReplace(io, op(io), .{ ._id = 2 }, .{ .n = 100 }, .{ .allocator = a }));
    try expectDocument(bson.literal(.{ ._id = 2, .n = 100 }), try users.findOneAndReplace(io, op(io), .{ ._id = 2 }, .{ .n = 200 }, .{ .allocator = a, .return_document = .before }));
    try expectDocument(bson.literal(.{ ._id = 2, .n = 200 }), try users.findOneAndDelete(io, op(io), .{ ._id = 2 }, .{ .allocator = a }));
    try testing.expect(try users.findOneAndDelete(io, op(io), .{ ._id = 2 }, .{ .allocator = a }) == null);

    // An upsert: before is null, after is the new document, its _id made by
    // the server from the filter.
    try testing.expect(try users.findOneAndUpdate(io, op(io), .{ ._id = 3 }, .{ .@"$set" = .{ .n = 30 } }, .{ .allocator = a, .upsert = true }) == null);
    try expectDocument(bson.literal(.{ ._id = 4, .n = 40 }), try users.findOneAndUpdate(io, op(io), .{ ._id = 4 }, .{ .@"$set" = .{ .n = 40 } }, .{
        .allocator = a,
        .upsert = true,
        .return_document = .after,
    }));

    // A change of the _id is the server's ok 0: ImmutableField.
    try testing.expectError(error.CommandFailed, users.findOneAndUpdate(io, op(io), .{ ._id = 3 }, .{ .@"$set" = .{ ._id = 4 } }, .{ .allocator = a, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 66), d.server.?.code);
}

fn upserts(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_upserts";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    const users = db.collection(name);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};

    var made = users.updateOne(io, op(io), .{ .email = "new@example.com" }, .{ .@"$set" = .{ .name = "New" } }, .{ .allocator = a, .upsert = true, .diagnostics = &d }) catch |err|
        return report(err, &d, "updateOne with upsert");
    defer made.deinit(a);
    try testing.expectEqual(@as(u64, 0), made.matched);
    try testing.expectEqual(@as(u64, 0), made.modified);
    try testing.expect(made.upserted_id.? == .object_id);

    var same = try users.updateOne(io, op(io), .{ .email = "new@example.com" }, .{ .@"$set" = .{ .name = "New" } }, .{ .allocator = a, .upsert = true });
    defer same.deinit(a);
    try testing.expectEqual(@as(u64, 1), same.matched);
    try testing.expectEqual(@as(u64, 0), same.modified);
    try testing.expect(same.upserted_id == null);

    var renamed = try users.updateOne(io, op(io), .{ ._id = made.upserted_id.? }, .{ .@"$set" = .{ .name = "Newer" } }, .{ .allocator = a });
    defer renamed.deinit(a);
    try testing.expectEqual(@as(u64, 1), renamed.matched);
    try testing.expectEqual(@as(u64, 1), renamed.modified);

    var replaced = try users.replaceOne(io, op(io), .{ ._id = "r1" }, .{ .name = "R" }, .{ .allocator = a, .upsert = true });
    defer replaced.deinit(a);
    try testing.expectEqual(@as(u64, 0), replaced.matched);
    try testing.expectEqualStrings("r1", replaced.upserted_id.?.string);

    var flagged = try users.updateMany(io, op(io), .{}, .{ .@"$set" = .{ .flag = true } }, .{ .allocator = a });
    defer flagged.deinit(a);
    try testing.expectEqual(@as(u64, 2), flagged.matched);
    try testing.expectEqual(@as(u64, 2), flagged.modified);

    // A null in a filter matches the documents without the field only.
    var no_email = try users.insertOne(io, op(io), .{ .name = "no email" }, .{ .allocator = a });
    no_email.deinit(a);
    const missing: ?[]const u8 = null;
    var deleted_null = try users.deleteMany(io, op(io), .{ .email = missing }, .{ .allocator = a });
    defer deleted_null.deinit(a);
    // "no email" and "R", which has no email either.
    try testing.expectEqual(@as(u64, 2), deleted_null.deleted);

    var one = try users.deleteOne(io, op(io), .{}, .{ .allocator = a });
    defer one.deinit(a);
    try testing.expectEqual(@as(u64, 1), one.deleted);
    var rest = try users.deleteMany(io, op(io), .{}, .{ .allocator = a });
    defer rest.deinit(a);
    try testing.expectEqual(@as(u64, 0), rest.deleted);
}

/// Inserts `count` documents `{n, even, tag}` into `name`, `n` from 0 and
/// `tag` "t0" to "t4" in turn.
fn seed(io: Io, db: mongo.Database, name: []const u8, count: usize) !void {
    const Doc = struct { n: i32, even: bool, tag: []const u8 };
    const docs = try testing.allocator.alloc(Doc, count);
    defer testing.allocator.free(docs);
    for (docs, 0..) |*doc, i| doc.* = .{ .n = @intCast(i), .even = i % 2 == 0, .tag = tags[i % tags.len] };
    var d: mongo.Diagnostics = .{};
    var result = db.collection(name).insertMany(io, op(io), docs, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err|
        return report(err, &d, "insertMany");
    result.deinit(testing.allocator);
}

const tags = [_][]const u8{ "t0", "t1", "t2", "t3", "t4" };

fn nOf(doc: bson.RawDocument) !i64 {
    return (try doc.get("n") orelse return error.TestNoN).asI64();
}

fn findMany(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_find";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    try seed(io, db, name, 250);
    const users = db.collection(name);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};

    // All of them, in the order of the sort, batch by batch.
    {
        const cursor = users.find(io, op(io), .{}, .{ .allocator = a, .sort = bson.literal(.{ .n = 1 }), .batch_size = 7, .diagnostics = &d }) catch |err|
            return report(err, &d, "find");
        defer cursor.deinit(io);
        var expected: i64 = 0;
        while (cursor.next(io, op(io)) catch |err| return report(err, &d, "next of find")) |doc| : (expected += 1) {
            try testing.expectEqual(expected, try nOf(doc));
        }
        try testing.expectEqual(@as(i64, 250), expected);
    }
    // A limit equal to the batch size: the server ends the cursor with
    // the first batch, and the cursor gives no more than the limit.
    {
        const cursor = try users.find(io, op(io), .{ .even = true }, .{
            .allocator = a,
            .sort = bson.literal(.{ .n = -1 }),
            .projection = bson.literal(.{ ._id = 0, .n = 1 }),
            .skip = 1,
            .limit = 10,
            .batch_size = 10,
        });
        defer cursor.deinit(io);
        var got: i64 = 0;
        while (try cursor.next(io, op(io))) |doc| : (got += 1) {
            // The even ones from the top, the first skipped: 246, 244, …
            try testing.expectEqual(246 - 2 * got, try nOf(doc));
            try testing.expect(try doc.get("_id") == null);
            try testing.expect(try doc.get("tag") == null);
        }
        try testing.expectEqual(@as(i64, 10), got);
    }
    const top = (try users.findOne(io, op(io), .{}, .{ .allocator = a, .sort = bson.literal(.{ .n = -1 }) })) orelse return error.TestNoDocument;
    defer top.deinit();
    try testing.expectEqual(@as(i64, 249), try nOf(top.raw()));
    const second_t3 = (try users.findOne(io, op(io), .{ .tag = "t3" }, .{ .allocator = a, .sort = bson.literal(.{ .n = 1 }), .skip = 1 })) orelse return error.TestNoDocument;
    defer second_t3.deinit();
    try testing.expectEqual(@as(i64, 8), try nOf(second_t3.raw()));
    try testing.expect(try users.findOne(io, op(io), .{ .n = 1000 }, .{ .allocator = a }) == null);
}

fn counts(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_count";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    try seed(io, db, name, 250);
    const users = db.collection(name);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};

    try testing.expectEqual(@as(u64, 250), users.countDocuments(io, op(io), .{}, .{ .allocator = a, .diagnostics = &d }) catch |err|
        return report(err, &d, "countDocuments"));
    try testing.expectEqual(@as(u64, 125), try users.countDocuments(io, op(io), .{ .even = true }, .{ .allocator = a }));
    try testing.expectEqual(@as(u64, 100), try users.countDocuments(io, op(io), .{}, .{ .allocator = a, .skip = 10, .limit = 100 }));
    try testing.expectEqual(@as(u64, 0), try users.countDocuments(io, op(io), .{ .n = .{ .@"$gt" = 1000 } }, .{ .allocator = a }));
    try testing.expectEqual(@as(u64, 250), users.estimatedDocumentCount(io, op(io), .{ .allocator = a, .diagnostics = &d }) catch |err|
        return report(err, &d, "estimatedDocumentCount"));
    // A collection that is not there counts 0 both ways.
    const none = db.collection("crud_count_none");
    try testing.expectEqual(@as(u64, 0), try none.countDocuments(io, op(io), .{}, .{ .allocator = a }));
    try testing.expectEqual(@as(u64, 0), try none.estimatedDocumentCount(io, op(io), .{ .allocator = a }));

    // Each tag once, in any order.
    const values = users.distinct(io, op(io), "tag", .{}, .{ .allocator = a, .diagnostics = &d }) catch |err| return report(err, &d, "distinct");
    defer values.deinit();
    var seen: [tags.len]bool = @splat(false);
    var it = values.raw().iterator();
    var distinct: usize = 0;
    while (try it.next()) |element| : (distinct += 1) {
        const tag = element.value.string;
        for (tags, &seen) |known, *was| {
            if (std.mem.eql(u8, known, tag)) was.* = true;
        }
    }
    try testing.expectEqual(tags.len, distinct);
    for (seen) |was| try testing.expect(was);
    const flags = try users.distinct(io, op(io), "even", .{ .n = .{ .@"$lt" = 2 } }, .{ .allocator = a });
    defer flags.deinit();
    var flag_count: usize = 0;
    var flag_it = flags.raw().iterator();
    while (try flag_it.next()) |_| flag_count += 1;
    try testing.expectEqual(@as(usize, 2), flag_count);

    // The even ones by tag: 25 of each, in batches of 2.
    const groups = users.aggregate(io, op(io), .{
        .{ .@"$match" = .{ .even = true } },
        .{ .@"$group" = .{ ._id = "$tag", .n = .{ .@"$sum" = 1 } } },
        .{ .@"$sort" = .{ ._id = 1 } },
    }, .{ .allocator = a, .batch_size = 2, .diagnostics = &d }) catch |err| return report(err, &d, "aggregate");
    defer groups.deinit(io);
    var group: usize = 0;
    while (try groups.next(io, op(io))) |doc| : (group += 1) {
        try testing.expectEqualStrings(tags[group], (try doc.get("_id")).?.string);
        try testing.expectEqual(@as(i64, 25), try nOf(doc));
    }
    try testing.expectEqual(tags.len, group);
    // The empty pipeline gives every document.
    const everything = try users.aggregate(io, op(io), .{}, .{ .allocator = a });
    defer everything.deinit(io);
    var all_count: usize = 0;
    while (try everything.next(io, op(io))) |_| all_count += 1;
    try testing.expectEqual(@as(usize, 250), all_count);
}

fn freeNames(names: []const []const u8) void {
    for (names) |name| testing.allocator.free(name);
    testing.allocator.free(names);
}

/// Fails unless the indexes of `users` are those named `expected`, in any
/// order; listed one per batch, so that getMore goes to the namespace of
/// the cursor of listIndexes.
fn expectIndexes(io: Io, users: mongo.Collection, expected: []const []const u8) !void {
    var d: mongo.Diagnostics = .{};
    const cursor = users.listIndexes(io, op(io), .{ .allocator = testing.allocator, .batch_size = 1, .diagnostics = &d }) catch |err|
        return report(err, &d, "listIndexes");
    defer cursor.deinit(io);
    var listed: usize = 0;
    while (cursor.next(io, op(io)) catch |err| return report(err, &d, "next of listIndexes")) |index| : (listed += 1) {
        const name = (try index.get("name")).?.string;
        for (expected) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else {
            std.debug.print("listIndexes gave {s}, which is not among the expected ones\n", .{name});
            return error.TestUnexpectedIndex;
        }
    }
    try testing.expectEqual(expected.len, listed);
}

/// The index `name` of `users`, as listIndexes gives it, copied into
/// `arena`.
fn indexNamed(io: Io, users: mongo.Collection, arena: std.mem.Allocator, name: []const u8) !bson.RawDocument {
    const cursor = try users.listIndexes(io, op(io), .{ .allocator = testing.allocator });
    defer cursor.deinit(io);
    while (try cursor.next(io, op(io))) |index| {
        if (std.mem.eql(u8, (try index.get("name")).?.string, name)) return .{ .bytes = try arena.dupe(u8, index.bytes) };
    }
    return error.TestNoIndex;
}

fn indexes(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const name = "crud_indexes";
    try drop(io, db, name);
    defer drop(io, db, name) catch {};
    const users = db.collection(name);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};

    const models = [_]mongo.Collection.IndexModel{
        .{ .keys = bson.literal(.{ .email = 1 }), .unique = true },
        .{ .keys = bson.literal(.{ .age = -1, .name = 1 }) },
        .{ .keys = bson.literal(.{ .created = 1 }), .expire_after_seconds = 3600 },
        .{ .keys = bson.literal(.{ .tag = 1 }), .name = "by_tag", .partial_filter_expression = bson.literal(.{ .tag = .{ .@"$exists" = true } }), .hidden = true },
    };
    const names = users.createIndexes(io, op(io), &models, .{ .allocator = a, .diagnostics = &d }) catch |err|
        return report(err, &d, "createIndexes");
    defer freeNames(names);
    try testing.expectEqual(models.len, names.len);
    for ([_][]const u8{ "email_1", "age_-1_name_1", "created_1", "by_tag" }, names) |expected, got| try testing.expectEqualStrings(expected, got);
    // The same indexes again: they are there, and that is no error.
    freeNames(users.createIndexes(io, op(io), &models, .{ .allocator = a, .diagnostics = &d }) catch |err|
        return report(err, &d, "createIndexes again"));
    try expectIndexes(io, users, &.{ "_id_", "email_1", "age_-1_name_1", "created_1", "by_tag" });

    // The options went out: mongod lists them with the indexes.
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try testing.expect((try (try indexNamed(io, users, arena.allocator(), "email_1")).get("unique")).?.boolean);
    try testing.expectEqual(@as(i64, 3600), try (try (try indexNamed(io, users, arena.allocator(), "created_1")).get("expireAfterSeconds")).?.asI64());
    const by_tag = try indexNamed(io, users, arena.allocator(), "by_tag");
    try testing.expect((try by_tag.get("hidden")).?.boolean);
    try testing.expect(try by_tag.get("partialFilterExpression") != null);
    // The unique index refuses a duplicate.
    var first = try users.insertOne(io, op(io), .{ .email = "ann@example.com" }, .{ .allocator = a });
    first.deinit(a);
    try testing.expectError(error.WriteFailed, users.insertOne(io, op(io), .{ .email = "ann@example.com" }, .{ .allocator = a, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);

    try users.dropIndex(io, op(io), "by_tag", .{ .allocator = a });
    try expectIndexes(io, users, &.{ "_id_", "email_1", "age_-1_name_1", "created_1" });
    // An index that is not there: mongod 7.0 and 8.0 answer IndexNotFound
    // (27), 9.0 ok.
    if (users.dropIndex(io, op(io), "by_tag", .{ .allocator = a, .diagnostics = &d })) |_| {} else |err| {
        try testing.expectEqual(error.CommandFailed, err);
        try testing.expectEqual(@as(i32, 27), d.server.?.code);
    }
    try testing.expectError(error.InvalidArgument, users.dropIndex(io, op(io), "*", .{ .allocator = a }));
    try users.dropIndexes(io, op(io), .{ .allocator = a, .comment = .{ .string = "e2e" } });
    try expectIndexes(io, users, &.{"_id_"});

    // A collection that is not there has no indexes: every mongod answers
    // NamespaceNotFound (26), which is an empty cursor, with diagnostics and
    // without.
    const none = db.collection("crud_indexes_none");
    try drop(io, db, "crud_indexes_none");
    try expectIndexes(io, none, &.{});
    const cursor = try none.listIndexes(io, op(io), .{ .allocator = a });
    defer cursor.deinit(io);
    try testing.expect(try cursor.next(io, op(io)) == null);
}

/// The names that `listCollections` with `filter` gives in `db`, one per
/// batch, copied into `arena`.
fn collectionNames(io: Io, db: mongo.Database, arena: std.mem.Allocator, filter: ?bson.RawDocument) ![]const []const u8 {
    var d: mongo.Diagnostics = .{};
    const cursor = db.listCollections(io, op(io), .{
        .allocator = testing.allocator,
        .filter = filter,
        .name_only = true,
        .batch_size = 1,
        .comment = .{ .string = "e2e" },
        .diagnostics = &d,
    }) catch |err| return report(err, &d, "listCollections");
    defer cursor.deinit(io);
    var names: std.ArrayList([]const u8) = .empty;
    while (cursor.next(io, op(io)) catch |err| return report(err, &d, "next of listCollections")) |info| {
        try testing.expectEqualStrings("collection", (try info.get("type")).?.string);
        try names.append(arena, try arena.dupe(u8, (try info.get("name")).?.string));
    }
    return names.items;
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |listed| {
        if (std.mem.eql(u8, listed, name)) return true;
    }
    return false;
}

fn collections(io: Io, db: mongo.Database, _: Server) anyerror!void {
    const first = "crud_list_a";
    const second = "crud_list_b";
    try drop(io, db, first);
    try drop(io, db, second);
    defer drop(io, db, first) catch {};
    defer drop(io, db, second) catch {};
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};
    for ([_][]const u8{ first, second }) |name| {
        var made = try db.collection(name).insertOne(io, op(io), .{ .n = 1 }, .{ .allocator = a });
        made.deinit(a);
    }
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const both = bson.literal(.{ .name = .{ .@"$in" = .{ "crud_list_a", "crud_list_b" } } });
    const listed = try collectionNames(io, db, arena.allocator(), both);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expect(has(listed, first) and has(listed, second));

    // Any command, as it is.
    const counted = db.runCommand(io, op(io), .{ .count = first }, .{ .allocator = a, .diagnostics = &d }) catch |err| return report(err, &d, "runCommand");
    defer counted.deinit();
    try testing.expectEqual(@as(i64, 1), try nOf(counted.raw()));
    // A cursor whose first batch is empty: the document comes in a
    // getMore of the batch size given.
    {
        const docs = db.runCursorCommand(io, op(io), .{ .find = second, .filter = .{}, .batchSize = 0 }, .{ .allocator = a, .batch_size = 1, .diagnostics = &d }) catch |err|
            return report(err, &d, "runCursorCommand");
        defer docs.deinit(io);
        try testing.expectEqual(@as(i64, 1), try nOf((try docs.next(io, op(io))).?));
        try testing.expect(try docs.next(io, op(io)) == null);
    }

    // A drop, and a drop of what is gone: no error either time.
    try db.collection(first).drop(io, op(io), .{ .allocator = a, .diagnostics = &d });
    try db.collection(first).drop(io, op(io), .{ .allocator = a, .diagnostics = &d });
    try testing.expect(d.server == null);
    const left = try collectionNames(io, db, arena.allocator(), both);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings(second, left[0]);

    // Database.drop drops every collection of a database, and twice is no
    // error.
    const other: mongo.Database = .init(db.client, "zefir_e2e_drop", db.ids);
    var made = try other.collection("x").insertOne(io, op(io), .{ .n = 1 }, .{ .allocator = a });
    made.deinit(a);
    try testing.expectEqual(@as(usize, 1), (try collectionNames(io, other, arena.allocator(), null)).len);
    try other.drop(io, op(io), .{ .allocator = a });
    try other.drop(io, op(io), .{ .allocator = a });
    try testing.expectEqual(@as(usize, 0), (try collectionNames(io, other, arena.allocator(), null)).len);
}
