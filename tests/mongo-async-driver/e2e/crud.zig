//! The collection API against mongod. Each scenario takes only a
//! `mongo.Database`, so that every driver runs the same ones; here they
//! run on `FakeDriver` through `Proxy` against mongo-plain, with a
//! `maxWriteBatchSize` of 3, so that writes go out in several batches.
//! Each scenario works in a collection of its own, which it drops before
//! and after.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;
const e2e = @import("root.zig");
const Proxy = @import("Proxy.zig");

pub const Scenario = struct {
    name: []const u8,
    run: *const fn (io: Io, db: mongo.Database) anyerror!void,
};

/// The scenarios, in their order.
pub const scenarios = [_]Scenario{
    .{ .name = "the _ids that inserts made are read back", .run = madeIds },
    .{ .name = "a unique index refuses a duplicate: WriteFailed 11000 at its index", .run = duplicateKey },
    .{ .name = "an unordered insertMany inserts all but its duplicates", .run = unorderedDuplicates },
    .{ .name = "findOneAndUpdate before and after, findOneAndReplace, findOneAndDelete", .run = findAndModify },
    .{ .name = "upserts, updates, replaces and deletes", .run = upserts },
};

/// Runs every scenario on `db`, and names the one that fails.
pub fn runAll(io: Io, db: mongo.Database) !void {
    for (scenarios) |scenario| {
        scenario.run(io, db) catch |err| {
            std.debug.print("scenario '{s}': {t}\n", .{ scenario.name, err });
            return err;
        };
    }
}

test "the collection API on FakeDriver through the proxy against mongo-plain, at a maxWriteBatchSize of 3" {
    try e2e.onZio(onFakeDriver);
}

fn onFakeDriver(io: Io) !void {
    var proxy: Proxy = .init(testing.allocator, e2e.servers.plain_port);
    defer proxy.deinit(io);
    var script: Script = .init(testing.allocator, proxy.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    defer fake.close(io);
    var ids: bson.ObjectId.Generator = .init(io);
    try runAll(io, .init(fake.client(), e2e.database, &ids));

    // The writes went out in batches of 3 items at most, and some in
    // batches of exactly 3.
    var full: usize = 0;
    for (0..script.received(io)) |i| {
        const entry = script.entry(io, i);
        const sequence = entry.sequence orelse continue;
        var docs = sequence.documents();
        var n: usize = 0;
        while (docs.next()) |_| n += 1;
        try testing.expect(n <= 3);
        if (n == 3) full += 1;
    }
    try testing.expect(full >= 3);
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

fn madeIds(io: Io, db: mongo.Database) anyerror!void {
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

fn duplicateKey(io: Io, db: mongo.Database) anyerror!void {
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

    // Ordered: the duplicate at index 5 stops the write in its batch.
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
    try testing.expectEqual(@as(usize, 6), many.answered);
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

fn unorderedDuplicates(io: Io, db: mongo.Database) anyerror!void {
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

fn findAndModify(io: Io, db: mongo.Database) anyerror!void {
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

fn upserts(io: Io, db: mongo.Database) anyerror!void {
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
