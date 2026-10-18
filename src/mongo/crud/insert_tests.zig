//! Tests of `insertOne` and `insertMany` on the client against
//! `mongo.testing.FakeServer`: the exact commands in the script's journal
//! and the results, in each form of the documents.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// A generator whose ids differ only in their seconds and counters.
fn generator() bson.ObjectId.Generator {
    return .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) };
}

fn annByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.putInt32("_id", 1);
    try b.putString("name", "Ann");
    return b.finish();
}

/// The documents of the section of kind 1 of `entry`, which must be
/// "documents".
fn sent(entry: Script.Entry, buffer: []bson.RawDocument) ![]bson.RawDocument {
    const sequence = entry.sequence orelse return error.TestNoSequence;
    try testing.expectEqualStrings("documents", sequence.identifier);
    var docs = sequence.documents();
    var n: usize = 0;
    while (docs.next()) |doc| : (n += 1) buffer[n] = doc;
    return buffer[0..n];
}

test "insertOne sends insert with the document in a section of kind 1 and reports its _id, in each of the three forms" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    const ann = bson.literal(.{ ._id = 1, .name = "Ann" });
    const built = try annByBuilder();
    defer built.deinit();
    const User = struct { _id: i32, name: []const u8 };
    inline for (.{ ann, built, User{ ._id = 1, .name = "Ann" }, .{ ._id = 1, .name = "Ann" } }, 0..) |doc, i| {
        var result = try users.insertOne(io, .of(.root), doc, .{ .allocator = testing.allocator });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(i32, 1), result.inserted_id.int32);
        const entry = script.entry(io, i);
        try testing.expectEqualStrings("insert", entry.name);
        try testing.expectEqualStrings("app", entry.database);
        try testing.expectEqualSlices(u8, bson.literal(.{ .insert = "users", .ordered = true, .@"$db" = "app" }).bytes, entry.body.bytes);
        var buffer: [1]bson.RawDocument = undefined;
        const docs = try sent(entry, &buffer);
        try testing.expectEqual(@as(usize, 1), docs.len);
        try testing.expectEqualSlices(u8, ann.bytes, docs[0].bytes);
    }
    // A given _id is not made.
    try testing.expectEqual(@as(u32, 0), ids.counter.load(.monotonic));
}

test "insertOne gives a document without _id the next ObjectId of the database first, and reports it" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    const User = struct { _id: ?bson.ObjectId = null, name: []const u8 };
    inline for (.{ bson.literal(.{ .name = "Ann" }), User{ .name = "Ann" }, .{ .name = "Ann" } }, 0..) |doc, i| {
        var result = try users.insertOne(io, .of(.root), doc, .{ .allocator = testing.allocator });
        defer result.deinit(testing.allocator);
        const made = result.inserted_id.object_id;
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, made.bytes[4..9]);
        try testing.expectEqual(@as(u24, @intCast(i)), std.mem.readInt(u24, made.bytes[9..12], .big));
        var buffer: [1]bson.RawDocument = undefined;
        const docs = try sent(script.entry(io, i), &buffer);
        const expected = try bson.encode(testing.allocator, .{ ._id = made, .name = "Ann" }, .{});
        defer expected.deinit();
        try testing.expectEqualSlices(u8, expected.bytes, docs[0].bytes);
    }
}

test "insertOne sends bypassDocumentValidation only when true, and the comment" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    var result = try users.insertOne(io, .of(.root), .{ ._id = 1 }, .{
        .allocator = testing.allocator,
        .bypass_document_validation = true,
        .comment = .{ .string = "seed" },
    });
    result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .insert = "users",
        .bypassDocumentValidation = true,
        .comment = "seed",
        .ordered = true,
        .@"$db" = "app",
    }).bytes, script.entry(io, 0).body.bytes);
    var other = try users.insertOne(io, .of(.root), .{ ._id = 2 }, .{ .allocator = testing.allocator, .bypass_document_validation = false });
    other.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .insert = "users", .ordered = true, .@"$db" = "app" }).bytes, script.entry(io, 1).body.bytes);
}

test "insertMany of 10 documents at a maxWriteBatchSize of 3 goes out as four commands, with the _ids it made" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{ .max_write_batch_size = 3 });
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    const Doc = struct { n: i32 };
    var docs: [10]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ .n = @intCast(i) };
    var result = try users.insertMany(io, .of(.root), &docs, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 10), result.inserted);
    try testing.expectEqual(@as(usize, 10), result.answered);
    try testing.expectEqual(@as(usize, 10), result.inserted_ids.len);
    try testing.expectEqual(@as(usize, 4), script.received(io));

    var at: usize = 0;
    for ([_]usize{ 3, 3, 3, 1 }, 0..) |count, i| {
        const entry = script.entry(io, i);
        try testing.expectEqualSlices(u8, bson.literal(.{ .insert = "users", .ordered = true, .@"$db" = "app" }).bytes, entry.body.bytes);
        var buffer: [3]bson.RawDocument = undefined;
        const batch = try sent(entry, &buffer);
        try testing.expectEqual(count, batch.len);
        for (batch) |doc| {
            // Each document went out with the _id of its index first.
            const made = result.inserted_ids[at].object_id;
            try testing.expectEqual(@as(u24, @intCast(at)), std.mem.readInt(u24, made.bytes[9..12], .big));
            const expected = try bson.encode(testing.allocator, .{ ._id = made, .n = @as(i32, @intCast(at)) }, .{});
            defer expected.deinit();
            try testing.expectEqualSlices(u8, expected.bytes, doc.bytes);
            at += 1;
        }
    }
}

test "insertMany takes a slice, an array and a tuple, of documents in any of the three forms, and sends ordered as given" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    const ann = bson.literal(.{ ._id = 1, .name = "Ann" });
    const bob = bson.literal(.{ ._id = 2, .name = "Bob" });
    const built = try annByBuilder();
    defer built.deinit();
    const User = struct { _id: i32, name: []const u8 };
    const raws = [_]bson.RawDocument{ ann, bob };
    const structs = [_]User{ .{ ._id = 1, .name = "Ann" }, .{ ._id = 2, .name = "Bob" } };
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, ann.bytes);
    try expected.appendSlice(testing.allocator, bob.bytes);

    var calls: usize = 0;
    inline for (.{
        @as([]const bson.RawDocument, &raws),
        raws,
        &structs,
        @as([]const User, &structs),
        .{ built, .{ ._id = 2, .name = "Bob" } },
        &.{ ann, User{ ._id = 2, .name = "Bob" } },
    }) |list| {
        var result = try users.insertMany(io, .of(.root), list, .{ .allocator = testing.allocator, .ordered = calls % 2 == 0 });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 2), result.inserted);
        try testing.expectEqual(@as(usize, 2), result.answered);
        try testing.expectEqual(@as(i32, 1), result.inserted_ids[0].int32);
        try testing.expectEqual(@as(i32, 2), result.inserted_ids[1].int32);
        const entry = script.entry(io, calls);
        const body = if (calls % 2 == 0)
            bson.literal(.{ .insert = "users", .ordered = true, .@"$db" = "app" })
        else
            bson.literal(.{ .insert = "users", .ordered = false, .@"$db" = "app" });
        try testing.expectEqualSlices(u8, body.bytes, entry.body.bytes);
        try testing.expectEqualSlices(u8, expected.items, entry.sequence.?.bytes);
        calls += 1;
    }
}

test "an empty insertMany, .{} among them, is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("insertMany has no documents: it needs at least one", d.message());
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), &.{}, .{ .allocator = testing.allocator }));
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), @as([]const bson.RawDocument, &.{}), .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(usize, 0), script.received(io));
}

test "a bad collection name or a document the codec cannot write is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids = generator();
    const db: mongo.Database = .init(served.client(), "app", &ids);

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, db.collection("").insertOne(io, .of(.root), .{ .a = 1 }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("a$").insertMany(io, .of(.root), .{.{ .a = 1 }}, .{ .allocator = testing.allocator }));

    const bad: []const u8 = "\xff";
    try testing.expectError(error.InvalidArgument, db.collection("users").insertOne(io, .of(.root), .{ .name = bad }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the document cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, db.collection("users").insertMany(io, .of(.root), .{ .{ .a = 1 }, .{ .name = bad } }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "document 1 of the list cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, db.collection("users").insertOne(io, .of(.root), .{ ._id = 1 }, .{
        .allocator = testing.allocator,
        .comment = .{ .string = bad },
        .diagnostics = &d,
    }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the comment cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), script.received(io));
}

test "an insert that the server refuses is WriteFailed" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 0 }} };
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    try testing.expectError(error.WriteFailed, users.insertOne(io, .of(.root), .{ ._id = 1 }, .{ .allocator = testing.allocator }));
}

test "an error of the contract passes as it is" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{.close_connection} };
    var served: Served = undefined;
    try served.start(io, queue.handler(), .{});
    defer served.stop(io);
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    try testing.expectError(error.ConnectionLost, users.insertOne(io, .of(.root), .{ ._id = 1 }, .{ .allocator = testing.allocator }));
    served.driver.close(io);
    try testing.expectError(error.Closed, users.insertMany(io, .of(.root), .{.{ ._id = 1 }}, .{ .allocator = testing.allocator }));
}

test "the documents of an insert are freed before it returns: only the result is left, and it frees" {
    const io = testing.io;
    var write: Script.Write = .{};
    var served: Served = undefined;
    try served.start(io, write.handler(), .{});
    defer served.stop(io);
    var ids = generator();
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    // testing.allocator fails the test on a leak; a string _id is copied
    // into the result.
    var result = try users.insertMany(io, .of(.root), .{ .{ ._id = "ann" }, .{ .name = "Bob" } }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("ann", result.inserted_ids[0].string);
    try testing.expect(result.inserted_ids[1] == .object_id);
}
