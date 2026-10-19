//! Tests of `updateOne`, `updateMany`, `replaceOne`, `deleteOne` and
//! `deleteMany` on the client against `mongo.testing.FakeServer`: the
//! exact commands in the script's journal and the results, in each form
//! of the documents.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// The one item of the write in `entry`, in its section `identifier`.
fn item(entry: Script.Entry, identifier: []const u8) !bson.RawDocument {
    const sequence = entry.sequence orelse return error.TestNoSequence;
    try testing.expectEqualStrings(identifier, sequence.identifier);
    var docs = sequence.documents();
    const doc = docs.next() orelse return error.TestNoItem;
    try testing.expect(docs.next() == null);
    return doc;
}

/// A script that answers each write with `reply`, and the client on it.
const Fixture = struct {
    replies: [16]Script.Answer = undefined,
    queue: Script.Queue = undefined,
    served: Served = undefined,
    /// The script of the server.
    script: *Script = undefined,
    ids: bson.ObjectId.Generator = .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) },

    /// Lives where it is: the server and the client point into it.
    fn init(f: *Fixture, reply: bson.RawDocument) !void {
        for (&f.replies) |*answer| answer.* = .{ .reply = reply };
        f.queue = .{ .answers = &f.replies };
        try f.served.start(testing.io, f.queue.handler(), .{});
        f.script = &f.served.script;
    }

    fn deinit(f: *Fixture) void {
        f.served.stop(testing.io);
    }

    fn users(f: *Fixture) mongo.Collection {
        return mongo.Database.init(f.served.client(), "app", &f.ids).collection("users");
    }
};

fn setTwoByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.beginDocument("$set");
    try b.putInt32("n", 2);
    try b.end();
    return b.finish();
}

fn idOneByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.putInt32("_id", 1);
    return b.finish();
}

test "updateOne sends one statement {q, u} in updates and reports matched and modified, in each of the three forms" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();

    const filter_built = try idOneByBuilder();
    defer filter_built.deinit();
    const update_built = try setTwoByBuilder();
    defer update_built.deinit();
    const Filter = struct { _id: i32 };
    const Set = struct { @"$set": struct { n: i32 } };
    const expected = bson.literal(.{ .q = .{ ._id = 1 }, .u = .{ .@"$set" = .{ .n = 2 } } });
    inline for (.{
        .{ bson.literal(.{ ._id = 1 }), bson.literal(.{ .@"$set" = .{ .n = 2 } }) },
        .{ filter_built, update_built },
        .{ Filter{ ._id = 1 }, Set{ .@"$set" = .{ .n = 2 } } },
        .{ .{ ._id = 1 }, .{ .@"$set" = .{ .n = 2 } } },
    }, 0..) |args, i| {
        var result = try users.updateOne(io, .of(.root), args[0], args[1], .{ .allocator = testing.allocator });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 1), result.matched);
        try testing.expectEqual(@as(u64, 1), result.modified);
        try testing.expect(result.upserted_id == null);
        const entry = try f.script.entry(io, i);
        try testing.expectEqualStrings("update", entry.name);
        try testing.expectEqualSlices(u8, bson.literal(.{ .update = "users", .ordered = true, .@"$db" = "app" }).bytes, entry.body.bytes);
        try testing.expectEqualSlices(u8, expected.bytes, (try item(entry, "updates")).bytes);
    }
}

test "updateMany sends multi: true; updateOne and replaceOne send no multi" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 3, .nModified = 2, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    var many = try users.updateMany(io, .of(.root), .{ .age = .{ .@"$lt" = 18 } }, .{ .@"$set" = .{ .minor = true } }, .{ .allocator = testing.allocator });
    defer many.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3), many.matched);
    try testing.expectEqual(@as(u64, 2), many.modified);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .q = .{ .age = .{ .@"$lt" = 18 } },
        .u = .{ .@"$set" = .{ .minor = true } },
        .multi = true,
    }).bytes, (try item(try f.script.entry(io, 0), "updates")).bytes);

    var replaced = try users.replaceOne(io, .of(.root), .{ ._id = 1 }, .{ .name = "Ann" }, .{ .allocator = testing.allocator });
    defer replaced.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{ ._id = 1 }, .u = .{ .name = "Ann" } }).bytes, (try item(try f.script.entry(io, 1), "updates")).bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .update = "users", .ordered = true, .@"$db" = "app" }).bytes, (try f.script.entry(io, 1)).body.bytes);
}

test "an update that is a list is a pipeline: a tuple, an array or a slice of stages" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    const stages = [_]bson.RawDocument{ bson.literal(.{ .@"$set" = .{ .n = 1 } }), bson.literal(.{ .@"$unset" = "old" }) };
    const expected = bson.literal(.{ .q = .{}, .u = .{ .{ .@"$set" = .{ .n = 1 } }, .{ .@"$unset" = "old" } } });
    inline for (.{
        .{ .{ .@"$set" = .{ .n = 1 } }, .{ .@"$unset" = "old" } },
        stages,
        @as([]const bson.RawDocument, &stages),
        &.{ stages[0], .{ .@"$unset" = "old" } },
    }, 0..) |pipeline, i| {
        var result = try users.updateOne(io, .of(.root), .{}, pipeline, .{ .allocator = testing.allocator });
        result.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, expected.bytes, (try item(try f.script.entry(io, i), "updates")).bytes);
    }
}

test "the options of an update: upsert, arrayFilters, collation and hint in the statement; let, bypassDocumentValidation and comment in the body" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    var result = try users.updateMany(io, .of(.root), .{ .grades = .{ .@"$gte" = 100 } }, .{ .@"$set" = .{ .@"grades.$[high]" = 100 } }, .{
        .allocator = testing.allocator,
        .upsert = true,
        .array_filters = &.{bson.literal(.{ .high = .{ .@"$gte" = 100 } })},
        .collation = bson.literal(.{ .locale = "fr" }),
        .hint = .{ .name = "grades_1" },
        .let = bson.literal(.{ .top = 100 }),
        .bypass_document_validation = true,
        .comment = .{ .string = "cap the grades" },
    });
    result.deinit(testing.allocator);
    const entry = try f.script.entry(io, 0);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .update = "users",
        .let = .{ .top = 100 },
        .bypassDocumentValidation = true,
        .comment = "cap the grades",
        .ordered = true,
        .@"$db" = "app",
    }).bytes, entry.body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .q = .{ .grades = .{ .@"$gte" = 100 } },
        .u = .{ .@"$set" = .{ .@"grades.$[high]" = 100 } },
        .multi = true,
        .upsert = true,
        .arrayFilters = .{.{ .high = .{ .@"$gte" = 100 } }},
        .collation = .{ .locale = "fr" },
        .hint = "grades_1",
    }).bytes, (try item(entry, "updates")).bytes);

    // A hint by the keys of the index; options at their defaults go out
    // not at all.
    var replaced = try users.replaceOne(io, .of(.root), .{ ._id = 1 }, .{ .n = 1 }, .{
        .allocator = testing.allocator,
        .hint = .{ .keys = bson.literal(.{ ._id = 1 }) },
        .upsert = false,
        .bypass_document_validation = false,
    });
    replaced.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .update = "users", .ordered = true, .@"$db" = "app" }).bytes, (try f.script.entry(io, 1)).body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{ ._id = 1 }, .u = .{ .n = 1 }, .hint = .{ ._id = 1 } }).bytes, (try item(try f.script.entry(io, 1), "updates")).bytes);
}

test "an upsert reports the _id that the server made, and matched without it" {
    const io = testing.io;
    const made = try bson.ObjectId.parseHex("eef732123cc60d97791de0cf");
    const reply = try bson.encode(testing.allocator, .{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = made }}, .ok = 1.0 }, .{});
    defer reply.deinit();
    var f: Fixture = .{};
    try f.init(reply.raw());
    defer f.deinit();
    const users = f.users();
    var result = try users.updateOne(io, .of(.root), .{ .email = "ann@example.com" }, .{ .@"$set" = .{ .name = "Ann" } }, .{ .allocator = testing.allocator, .upsert = true });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), result.matched);
    try testing.expectEqual(@as(u64, 0), result.modified);
    try testing.expectEqualSlices(u8, &made.bytes, &result.upserted_id.?.object_id.bytes);

    // A replace that upserts a document whose _id is a string: the result
    // holds a copy.
    const by_name = bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "ann" }}, .ok = 1.0 });
    for (&f.replies) |*answer| answer.* = .{ .reply = by_name };
    var replaced = try users.replaceOne(io, .of(.root), .{ ._id = "ann" }, .{ .name = "Ann" }, .{ .allocator = testing.allocator, .upsert = true });
    defer replaced.deinit(testing.allocator);
    try testing.expectEqualStrings("ann", replaced.upserted_id.?.string);
}

test "an update that does not start with an operator, or is empty, is InvalidArgument; a replacement may not start with one" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    const options: mongo.Collection.UpdateOptions = .{ .allocator = testing.allocator, .diagnostics = &d };

    try testing.expectError(error.InvalidArgument, users.updateOne(io, .of(.root), .{ ._id = 1 }, .{}, options));
    try testing.expectEqualStrings("the update is empty: it starts with an update operator, such as $set, or it is a pipeline", d.message());
    try testing.expectError(error.InvalidArgument, users.updateMany(io, .of(.root), .{}, .{ .name = "Ann" }, options));
    try testing.expectEqualStrings("the update starts with 'name', not with an update operator such as $set: to replace the whole document, use replaceOne", d.message());
    try testing.expectError(error.InvalidArgument, users.updateOne(io, .of(.root), .{}, bson.RawDocument.empty, options));
    try testing.expectError(error.InvalidArgument, users.updateOne(io, .of(.root), .{}, &.{}, options));
    try testing.expectEqualStrings("the update is an empty pipeline: a pipeline needs at least one stage", d.message());
    try testing.expectError(error.InvalidArgument, users.updateOne(io, .of(.root), .{}, @as([]const bson.RawDocument, &.{}), options));

    try testing.expectError(error.InvalidArgument, users.replaceOne(io, .of(.root), .{ ._id = 1 }, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the replacement starts with the update operator '$set': to change fields of the document, use updateOne", d.message());
    try testing.expectEqual(@as(usize, 0), f.script.received(io));

    // An empty replacement leaves the document its _id alone.
    var emptied = try users.replaceOne(io, .of(.root), .{ ._id = 1 }, .{}, .{ .allocator = testing.allocator });
    emptied.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{ ._id = 1 }, .u = .{} }).bytes, (try item(try f.script.entry(io, 0), "updates")).bytes);
}

test "deleteOne sends limit 1 and deleteMany limit 0; deleteMany(.{}) sends q: {}, and the result reports deleted" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 5, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();

    const filter_built = try idOneByBuilder();
    defer filter_built.deinit();
    const Filter = struct { _id: i32 };
    inline for (.{ bson.literal(.{ ._id = 1 }), filter_built, Filter{ ._id = 1 }, .{ ._id = 1 } }, 0..) |filter, i| {
        var result = try users.deleteOne(io, .of(.root), filter, .{ .allocator = testing.allocator });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 5), result.deleted);
        const entry = try f.script.entry(io, i);
        try testing.expectEqualStrings("delete", entry.name);
        try testing.expectEqualSlices(u8, bson.literal(.{ .delete = "users", .ordered = true, .@"$db" = "app" }).bytes, entry.body.bytes);
        try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{ ._id = 1 }, .limit = 1 }).bytes, (try item(entry, "deletes")).bytes);
    }

    var all = try users.deleteMany(io, .of(.root), .{}, .{ .allocator = testing.allocator });
    defer all.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 5), all.deleted);
    try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{}, .limit = 0 }).bytes, (try item(try f.script.entry(io, 4), "deletes")).bytes);

    var with_options = try users.deleteMany(io, .of(.root), .{ .age = .{ .@"$lt" = 18 } }, .{
        .allocator = testing.allocator,
        .collation = bson.literal(.{ .locale = "en" }),
        .hint = .{ .keys = bson.literal(.{ .age = 1 }) },
        .let = bson.literal(.{ .min = 18 }),
        .comment = .{ .string = "minors" },
    });
    defer with_options.deinit(testing.allocator);
    const entry = try f.script.entry(io, 5);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .delete = "users",
        .let = .{ .min = 18 },
        .comment = "minors",
        .ordered = true,
        .@"$db" = "app",
    }).bytes, entry.body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .q = .{ .age = .{ .@"$lt" = 18 } },
        .limit = 0,
        .collation = .{ .locale = "en" },
        .hint = .{ .age = 1 },
    }).bytes, (try item(entry, "deletes")).bytes);
}

test "a filter with a null field sends BSON null, so that it matches only documents without the field" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 0, .ok = 1.0 }));
    defer f.deinit();
    const email: ?[]const u8 = null;
    var result = try f.users().deleteMany(io, .of(.root), .{ .email = email }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .q = .{ .email = null }, .limit = 0 }).bytes, (try item(try f.script.entry(io, 0), "deletes")).bytes);
}

test "a bad collection name, filter, collation or comment is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .n = 0, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    const bad: []const u8 = "\xff";
    const db: mongo.Database = .init(f.served.client(), "app", &f.ids);
    try testing.expectError(error.InvalidArgument, db.collection("").deleteOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("$cmd").updateOne(io, .of(.root), .{}, .{ .@"$set" = .{ .a = 1 } }, .{ .allocator = testing.allocator }));
    try testing.expectError(error.InvalidArgument, users.deleteMany(io, .of(.root), .{ .name = bad }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the filter cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, users.updateOne(io, .of(.root), .{}, .{ .@"$set" = .{ .name = bad } }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the update cannot be written as BSON"));
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, users.deleteOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .collation = broken, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the collation cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, users.replaceOne(io, .of(.root), .{}, .{}, .{ .allocator = testing.allocator, .comment = .{ .string = bad }, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the comment cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
