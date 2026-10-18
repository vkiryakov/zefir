//! Tests of the errors of the collection API's writes on
//! `mongo.testing.FakeDriver`: `WriteFailed` when the server refused items
//! or a write concern, an error of the contract as it is, and `partial`
//! with all that is known, its indexes in the whole list.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;

const Doc = struct { n: i32 };

fn tenDocuments() [10]Doc {
    var docs: [10]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ .n = @intCast(i) };
    return docs;
}

/// The `_id`s of the documents that went out in the inserts of `script`,
/// in their order.
fn sentIds(io: Io, script: *Script, buffer: []bson.ObjectId) ![]bson.ObjectId {
    var n: usize = 0;
    for (0..script.received(io)) |i| {
        var docs = script.entry(io, i).sequence.?.documents();
        while (docs.next()) |doc| : (n += 1) buffer[n] = (try doc.get("_id")).?.object_id;
    }
    return buffer[0..n];
}

test "an unordered insertMany whose items the server refused is WriteFailed; partial holds them by their index in the whole list" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{ .{ .index = 4 }, .{ .index = 7, .errmsg = "E11000 duplicate key error collection: app.users" } } };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");

    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    const docs = tenDocuments();
    try testing.expectError(error.WriteFailed, users.insertMany(io, .of(.root), &docs, .{
        .allocator = testing.allocator,
        .ordered = false,
        .partial = &partial,
        .diagnostics = &d,
    }));
    // The server answered every batch: all but the refused ones are in.
    try testing.expectEqual(@as(usize, 4), script.count(io, "insert"));
    try testing.expectEqual(@as(u64, 8), partial.inserted);
    try testing.expectEqual(@as(usize, 10), partial.answered);
    try testing.expectEqual(@as(usize, 2), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 4), partial.write_errors[0].index);
    try testing.expectEqual(@as(i32, 11000), partial.write_errors[0].code);
    try testing.expectEqual(@as(usize, 7), partial.write_errors[1].index);
    try testing.expectEqualStrings("E11000 duplicate key error collection: app.users", partial.write_errors[1].message);
    var buffer: [10]bson.ObjectId = undefined;
    const sent = try sentIds(io, &script, &buffer);
    try testing.expectEqual(@as(usize, 10), partial.inserted_ids.len);
    for (sent, partial.inserted_ids) |made, reported| try testing.expectEqualSlices(u8, &made.bytes, &reported.object_id.bytes);
    // The first refused item, in the diagnostics.
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
    try testing.expectEqualStrings("E11000 duplicate key error", d.message());
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(error.WriteFailed));
}

test "an ordered insertMany stops at the batch of its first refused item: WriteFailed, with what came before it" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 4 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");

    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    const docs = tenDocuments();
    try testing.expectError(error.WriteFailed, users.insertMany(io, .of(.root), &docs, .{ .allocator = testing.allocator, .partial = &partial }));
    try testing.expectEqual(@as(usize, 2), script.count(io, "insert"));
    try testing.expectEqual(@as(u64, 4), partial.inserted);
    try testing.expectEqual(@as(usize, 6), partial.answered);
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 4), partial.write_errors[0].index);
    try testing.expectEqual(@as(usize, 10), partial.inserted_ids.len);

    // Without partial, nothing is left to free. The handler counts the
    // items of a new write from 0 again.
    write.seen = 0;
    try testing.expectError(error.WriteFailed, users.insertMany(io, .of(.root), &docs, .{ .allocator = testing.allocator }));
}

test "insertOne of a document the server refuses is WriteFailed with its error, and partial reports the _id" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 0 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.InsertOneResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.WriteFailed, users.insertOne(io, .of(.root), .{ ._id = "ann" }, .{ .allocator = testing.allocator, .partial = &partial, .diagnostics = &d }));
    try testing.expectEqualStrings("ann", partial.inserted_id.string);
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 0), partial.write_errors[0].index);
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
}

test "a writeConcernError makes a write that ran WriteFailed: the first one in the diagnostics, all in partial" {
    const io = testing.io;
    const concern = bson.literal(.{
        .n = 1,
        .writeConcernError = .{ .code = 64, .codeName = "WriteConcernFailed", .errmsg = "waiting for replication timed out" },
        .ok = 1.0,
    });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = concern }, .{ .reply = concern }, .{ .reply = concern } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");

    var inserted: mongo.Collection.InsertManyResult = .{};
    defer inserted.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.WriteFailed, users.insertMany(io, .of(.root), .{.{ .n = 1 }}, .{ .allocator = testing.allocator, .partial = &inserted, .diagnostics = &d }));
    try testing.expectEqual(@as(u64, 1), inserted.inserted);
    try testing.expectEqual(@as(usize, 0), inserted.write_errors.len);
    try testing.expectEqual(@as(usize, 1), inserted.write_concern_errors.len);
    try testing.expectEqual(@as(i32, 64), inserted.write_concern_errors[0].code);
    try testing.expectEqual(@as(i32, 64), d.server.?.code);
    try testing.expectEqualStrings("waiting for replication timed out", d.message());

    var updated: mongo.Collection.UpdateResult = .{};
    defer updated.deinit(testing.allocator);
    try testing.expectError(error.WriteFailed, users.updateOne(io, .of(.root), .{}, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = testing.allocator, .partial = &updated }));
    try testing.expectEqual(@as(u64, 1), updated.matched);
    try testing.expectEqual(@as(usize, 1), updated.write_concern_errors.len);

    var deleted: mongo.Collection.DeleteResult = .{};
    defer deleted.deinit(testing.allocator);
    try testing.expectError(error.WriteFailed, users.deleteMany(io, .of(.root), .{}, .{ .allocator = testing.allocator, .partial = &deleted }));
    try testing.expectEqual(@as(u64, 1), deleted.deleted);
    try testing.expectEqual(@as(usize, 1), deleted.write_concern_errors.len);
}

test "an update whose statement the server refuses is WriteFailed, with its code" {
    const io = testing.io;
    const immutable = bson.literal(.{
        .n = 0,
        .nModified = 0,
        .writeErrors = .{.{ .index = 0, .code = 66, .errmsg = "Performing an update on the path '_id' would modify the immutable field '_id'" }},
        .ok = 1.0,
    });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = immutable }, .{ .reply = immutable } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.UpdateResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.WriteFailed, users.replaceOne(io, .of(.root), .{ ._id = 1 }, .{ ._id = 2 }, .{ .allocator = testing.allocator, .partial = &partial, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 66), d.server.?.code);
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(u64, 0), partial.matched);
    try testing.expectError(error.WriteFailed, users.updateMany(io, .of(.root), .{}, .{ .@"$set" = .{ ._id = 2 } }, .{ .allocator = testing.allocator }));
}

/// Answers the batches of an insert, and closes the connection at the
/// third.
const CutAtThird = struct {
    write: Script.Write = .{},
    batches: std.atomic.Value(u32) = .init(0),

    pub fn answer(h: *CutAtThird, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (h.batches.fetchAdd(1, .monotonic) == 2) return .close_connection;
        return h.write.answer(io, arena, request);
    }
};

test "a write cut at its third batch is IncompleteWrite: partial holds the two batches and the _ids of all the documents" {
    const io = testing.io;
    var cut: CutAtThird = .{};
    var script: Script = .init(testing.allocator, .init(&cut));
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");

    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    const docs = tenDocuments();
    try testing.expectError(error.IncompleteWrite, users.insertMany(io, .of(.root), &docs, .{ .allocator = testing.allocator, .partial = &partial, .diagnostics = &d }));
    try testing.expectEqual(@as(?mongo.Error, error.ConnectionLost), d.reason);
    try testing.expectEqual(@as(?usize, 6), d.batch_offset);
    try testing.expectEqual(@as(u64, 6), partial.inserted);
    try testing.expectEqual(@as(usize, 6), partial.answered);
    try testing.expectEqual(@as(usize, 0), partial.write_errors.len);
    // Decision 10: every document has its _id before the first batch, so
    // the batch of unknown outcome can be checked by them.
    try testing.expectEqual(@as(usize, 10), partial.inserted_ids.len);
    var buffer: [10]bson.ObjectId = undefined;
    const sent = try sentIds(io, &script, &buffer);
    try testing.expectEqual(@as(usize, 9), sent.len);
    for (sent, partial.inserted_ids[0..9]) |made, reported| try testing.expectEqualSlices(u8, &made.bytes, &reported.object_id.bytes);
    try testing.expect(partial.inserted_ids[9] == .object_id);
}

/// Cancels its token at the second batch of a write.
const CancelAtSecond = struct {
    write: Script.Write = .{},
    token: core.CancellationToken = .init,
    batches: std.atomic.Value(u32) = .init(0),

    pub fn answer(h: *CancelAtSecond, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (h.batches.fetchAdd(1, .monotonic) == 1) h.token.cancel();
        return h.write.answer(io, arena, request);
    }
};

test "a token canceled while the second batch was out is IncompleteWrite with reason Cancelled; partial holds two batches" {
    const io = testing.io;
    var canceler: CancelAtSecond = .{};
    var script: Script = .init(testing.allocator, .init(&canceler));
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    const docs = tenDocuments();
    const op: mongo.OperationContext = .of(core.Context.root.withCancellation(&canceler.token));
    try testing.expectError(error.IncompleteWrite, users.insertMany(io, op, &docs, .{ .allocator = testing.allocator, .partial = &partial, .diagnostics = &d }));
    try testing.expectEqual(@as(?mongo.Error, error.Cancelled), d.reason);
    try testing.expectEqual(@as(u64, 6), partial.inserted);
    try testing.expectEqual(@as(usize, 2), script.count(io, "insert"));
}

test "an error of the contract at the first batch passes as it is, with partial; a token canceled while the write was out is Interrupted with its result" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{.close_connection} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var lost: mongo.Collection.InsertOneResult = .{};
    defer lost.deinit(testing.allocator);
    try testing.expectError(error.ConnectionLost, users.insertOne(io, .of(.root), .{ .name = "Ann" }, .{ .allocator = testing.allocator, .partial = &lost }));
    try testing.expect(lost.inserted_id == .object_id);
    try testing.expectEqual(@as(usize, 0), lost.write_errors.len);

    var canceler: CancelAtSecond = .{};
    canceler.batches.store(1, .monotonic);
    var other: Script = .init(testing.allocator, .init(&canceler));
    defer other.deinit();
    var second: FakeDriver = .init(testing.allocator, &other);
    defer second.deinit();
    const cancelable = mongo.Database.init(second.client(), "app", &ids).collection("users");
    var interrupted: mongo.Collection.DeleteResult = .{};
    defer interrupted.deinit(testing.allocator);
    const op: mongo.OperationContext = .of(core.Context.root.withCancellation(&canceler.token));
    try testing.expectError(error.Interrupted, cancelable.deleteOne(io, op, .{ ._id = 1 }, .{ .allocator = testing.allocator, .partial = &interrupted }));
    try testing.expectEqual(@as(u64, 1), interrupted.deleted);
}

test "MaxTimeMSExpired in writeErrors is the contract's Timeout, with partial" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 0, .code = 50, .errmsg = "operation exceeded time limit" }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    try testing.expectError(error.Timeout, users.insertMany(io, .of(.root), .{.{ .n = 1 }}, .{ .allocator = testing.allocator, .partial = &partial }));
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(i32, 50), partial.write_errors[0].code);
}

test "an argument the collection API refuses leaves partial as it was" {
    const io = testing.io;
    var write: Script.Write = .{};
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.InsertManyResult = .{};
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), .{}, .{ .allocator = testing.allocator, .partial = &partial }));
    try testing.expectEqual(@as(usize, 0), partial.inserted_ids.len);
}

test "a successful write returns empty lists of errors" {
    const io = testing.io;
    var write: Script.Write = .{};
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");
    var partial: mongo.Collection.InsertManyResult = .{};
    var result = try users.insertMany(io, .of(.root), .{ .{ .n = 1 }, .{ .n = 2 } }, .{ .allocator = testing.allocator, .partial = &partial });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.write_errors.len);
    try testing.expectEqual(@as(usize, 0), result.write_concern_errors.len);
    // partial is for errors only.
    try testing.expectEqual(@as(usize, 0), partial.inserted_ids.len);
}

test "a writeConcernError of findAndModify is WriteFailed, with the reply in failure_reply; code 50 there is Timeout" {
    const io = testing.io;
    const concern = bson.literal(.{
        .lastErrorObject = .{ .n = 1, .updatedExisting = true },
        .value = .{ ._id = 1, .n = 1 },
        .writeConcernError = .{ .code = 64, .codeName = "WriteConcernFailed", .errmsg = "waiting for replication timed out" },
        .ok = 1.0,
    });
    const expired = bson.literal(.{
        .lastErrorObject = .{ .n = 1, .updatedExisting = true },
        .value = .{ ._id = 1, .n = 1 },
        .writeConcernError = .{ .code = 50, .codeName = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" },
        .ok = 1.0,
    });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = concern }, .{ .reply = expired } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(fake.client(), "app", &ids).collection("users");

    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.WriteFailed, users.findOneAndUpdate(io, .of(.root), .{ ._id = 1 }, .{ .@"$inc" = .{ .n = 1 } }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    try testing.expectEqualSlices(u8, concern.bytes, failure.?.bytes);
    failure.?.deinit();
    failure = null;
    try testing.expectEqual(@as(i32, 64), d.server.?.code);
    try testing.expectEqualStrings("WriteConcernFailed", d.server.?.code_name.slice());
    try testing.expectEqualStrings("waiting for replication timed out", d.message());

    try testing.expectError(error.Timeout, users.findOneAndDelete(io, .of(.root), .{ ._id = 1 }, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, expired.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 50), d.server.?.code);
}
