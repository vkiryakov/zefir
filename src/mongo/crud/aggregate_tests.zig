//! Tests of `aggregate`, `countDocuments`, `estimatedDocumentCount` and
//! `distinct` on `mongo.testing.FakeDriver`: the exact commands and
//! pipelines in the script's journal, and what their replies give.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;

const ann = bson.literal(.{ ._id = 1, .n = 1 });
const bob = bson.literal(.{ ._id = 2, .n = 2 });
const batches = [_][]const bson.RawDocument{ &.{ann}, &.{bob} };

/// A script whose handler is `handler`, and the fake on it.
const Fixture = struct {
    script: Script = undefined,
    fake: FakeDriver = undefined,
    ids: bson.ObjectId.Generator = .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) },

    /// Lives where it is: the fake points into it.
    fn init(f: *Fixture, handler: Script.Handler) void {
        f.script = .init(testing.allocator, handler);
        f.fake = .init(testing.allocator, &f.script);
    }

    fn deinit(f: *Fixture) void {
        f.fake.deinit();
        f.script.deinit();
    }

    fn users(f: *Fixture) mongo.Collection {
        return mongo.Database.init(f.fake.client(), "app", &f.ids).collection("users");
    }

    fn body(f: *Fixture, i: usize) bson.RawDocument {
        return f.script.entry(testing.io, i).body;
    }
};

/// Answers every command with `reply`.
const Same = struct {
    reply: bson.RawDocument,

    fn handler(s: *Same) Script.Handler {
        return .init(s);
    }

    pub fn answer(s: *Same, io: std.Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        _ = request;
        return .{ .reply = s.reply };
    }
};

fn expectBody(expected: bson.RawDocument, got: bson.RawDocument) !void {
    if (!std.mem.eql(u8, expected.bytes, got.bytes)) {
        std.debug.print("expected {f}\n     got {f}\n", .{ expected, got });
        return error.TestUnexpectedCommand;
    }
}

fn matchByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.beginDocument("$match");
    try b.putInt32("n", 1);
    try b.end();
    return b.finish();
}

test "aggregate sends its pipeline with cursor: {}, the list and its stages in any form, and its cursor gives every batch" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &batches };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const users = f.users();

    const built = try matchByBuilder();
    defer built.deinit();
    const Sort = struct { @"$sort": struct { n: i32 } };
    const Match = struct { @"$match": struct { n: i32 } };
    const raws = [_]bson.RawDocument{ bson.literal(.{ .@"$match" = .{ .n = 1 } }), bson.literal(.{ .@"$sort" = .{ .n = -1 } }) };
    inline for (.{
        .{ .{ .@"$match" = .{ .n = 1 } }, .{ .@"$sort" = .{ .n = -1 } } },
        .{ built, Sort{ .@"$sort" = .{ .n = -1 } } },
        &.{ raws[0], .{ .@"$sort" = .{ .n = -1 } } },
        @as([]const bson.RawDocument, &raws),
        [_]bson.RawDocument{ raws[0], raws[1] },
        .{ Match{ .@"$match" = .{ .n = 1 } }, raws[1] },
    }, 0..) |pipeline, i| {
        const docs = try users.aggregate(io, .of(.root), pipeline, .{ .allocator = testing.allocator });
        defer docs.deinit(io);
        try testing.expectEqualSlices(u8, ann.bytes, (try docs.next(io, .of(.root))).?.bytes);
        try testing.expectEqualSlices(u8, bob.bytes, (try docs.next(io, .of(.root))).?.bytes);
        try testing.expect(try docs.next(io, .of(.root)) == null);
        try expectBody(bson.literal(.{
            .aggregate = "users",
            .pipeline = .{ .{ .@"$match" = .{ .n = 1 } }, .{ .@"$sort" = .{ .n = -1 } } },
            .cursor = .{},
            .@"$db" = "app",
        }), f.body(2 * i));
        try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .@"$db" = "app" }), f.body(2 * i + 1));
    }
}

test "aggregate(.{}) sends pipeline: []" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{} };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const docs = try f.users().aggregate(io, .of(.root), .{}, .{ .allocator = testing.allocator });
    defer docs.deinit(io);
    try testing.expect(try docs.next(io, .of(.root)) == null);
    try expectBody(bson.literal(.{ .aggregate = "users", .pipeline = [0]i32{}, .cursor = .{}, .@"$db" = "app" }), f.body(0));
}

test "the options of aggregate go out in their order, the batch size in cursor and with the comment to each getMore" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &batches };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const docs = try f.users().aggregate(io, .of(.root), .{.{ .@"$match" = .{} }}, .{
        .allocator = testing.allocator,
        .batch_size = 1,
        .allow_disk_use = true,
        .hint = .{ .name = "n_1" },
        .collation = bson.literal(.{ .locale = "en" }),
        .let = bson.literal(.{ .x = 1 }),
        .bypass_document_validation = true,
        .comment = .{ .string = "report" },
    });
    defer docs.deinit(io);
    while (try docs.next(io, .of(.root))) |_| {}
    try expectBody(bson.literal(.{
        .aggregate = "users",
        .pipeline = .{.{ .@"$match" = .{} }},
        .allowDiskUse = true,
        .cursor = .{ .batchSize = 1 },
        .bypassDocumentValidation = true,
        .collation = .{ .locale = "en" },
        .hint = "n_1",
        .comment = "report",
        .let = .{ .x = 1 },
        .@"$db" = "app",
    }), f.body(0));
    try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .batchSize = 1, .comment = "report", .@"$db" = "app" }), f.body(1));
}

test "a pipeline that ends in $out or $merge sends no batch size in its cursor, so that a batch size of 0 cannot keep it from running" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{} };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const users = f.users();
    const out = try users.aggregate(io, .of(.root), .{ .{ .@"$match" = .{} }, .{ .@"$out" = "archive" } }, .{ .allocator = testing.allocator, .batch_size = 0 });
    out.deinit(io);
    try expectBody(bson.literal(.{ .aggregate = "users", .pipeline = .{ .{ .@"$match" = .{} }, .{ .@"$out" = "archive" } }, .cursor = .{}, .@"$db" = "app" }), f.body(0));
    const merge = try users.aggregate(io, .of(.root), .{.{ .@"$merge" = .{ .into = "archive" } }}, .{ .allocator = testing.allocator, .batch_size = 5 });
    merge.deinit(io);
    try expectBody(bson.literal(.{ .aggregate = "users", .pipeline = .{.{ .@"$merge" = .{ .into = "archive" } }}, .cursor = .{}, .@"$db" = "app" }), f.body(1));
    // $out in the middle is not the end of the pipeline.
    const middle = try users.aggregate(io, .of(.root), .{ .{ .@"$out" = "x" }, .{ .@"$match" = .{} } }, .{ .allocator = testing.allocator, .batch_size = 0 });
    middle.deinit(io);
    try expectBody(bson.literal(.{ .aggregate = "users", .pipeline = .{ .{ .@"$out" = "x" }, .{ .@"$match" = .{} } }, .cursor = .{ .batchSize = 0 }, .@"$db" = "app" }), f.body(2));
}

fn countReply(comptime n: anytype) bson.RawDocument {
    return bson.literal(.{ .cursor = .{ .firstBatch = .{.{ ._id = 1, .n = n }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 });
}

test "countDocuments sends $match, $skip, $limit and $group, the filter in any form, and returns n of the first document" {
    const io = testing.io;
    var same: Same = .{ .reply = countReply(3) };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const users = f.users();

    var b: bson.Builder = .init(testing.allocator);
    try b.beginDocument("n");
    try b.putInt32("$gte", 1);
    try b.end();
    const built = try b.finish();
    defer built.deinit();
    const Filter = struct { n: struct { @"$gte": i32 } };
    inline for (.{ bson.literal(.{ .n = .{ .@"$gte" = 1 } }), built, Filter{ .n = .{ .@"$gte" = 1 } }, .{ .n = .{ .@"$gte" = 1 } } }, 0..) |filter, i| {
        try testing.expectEqual(@as(u64, 3), try users.countDocuments(io, .of(.root), filter, .{ .allocator = testing.allocator }));
        try expectBody(bson.literal(.{
            .aggregate = "users",
            .pipeline = .{ .{ .@"$match" = .{ .n = .{ .@"$gte" = 1 } } }, .{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } } },
            .cursor = .{},
            .@"$db" = "app",
        }), f.body(i));
    }

    try testing.expectEqual(@as(u64, 3), try users.countDocuments(io, .of(.root), .{}, .{
        .allocator = testing.allocator,
        .skip = 1,
        .limit = 10,
        .hint = .{ .keys = bson.literal(.{ .n = 1 }) },
        .collation = bson.literal(.{ .locale = "en" }),
        .comment = .{ .string = "how many" },
    }));
    try expectBody(bson.literal(.{
        .aggregate = "users",
        .pipeline = .{ .{ .@"$match" = .{} }, .{ .@"$skip" = 1 }, .{ .@"$limit" = 10 }, .{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } } },
        .cursor = .{},
        .collation = .{ .locale = "en" },
        .hint = .{ .n = 1 },
        .comment = "how many",
        .@"$db" = "app",
    }), f.body(4));
    // The cursor held a single batch: no getMore, no killCursors.
    try testing.expectEqual(@as(usize, 5), f.script.received(io));
}

test "countDocuments(.{}) sends $match: {}, and an empty cursor counts 0" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{} };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    try testing.expectEqual(@as(u64, 0), try f.users().countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator }));
    try expectBody(bson.literal(.{
        .aggregate = "users",
        .pipeline = .{ .{ .@"$match" = .{} }, .{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } } },
        .cursor = .{},
        .@"$db" = "app",
    }), f.body(0));
}

test "a count is n as an int32, an int64 or a whole double; anything else is a protocol violation" {
    const io = testing.io;
    var same: Same = .{ .reply = countReply(@as(i64, 5_000_000_000)) };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const users = f.users();
    try testing.expectEqual(@as(u64, 5_000_000_000), try users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator }));
    same.reply = countReply(7.0);
    try testing.expectEqual(@as(u64, 7), try users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator }));

    var d: mongo.Diagnostics = .{};
    same.reply = countReply(-1);
    try testing.expectError(error.ProtocolViolation, users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the result of countDocuments holds an n that is not a count: a whole number, 0 or more", d.message());
    same.reply = countReply(2.5);
    try testing.expectError(error.ProtocolViolation, users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    same.reply = countReply("three");
    try testing.expectError(error.ProtocolViolation, users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    same.reply = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ ._id = 1 }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 });
    try testing.expectError(error.ProtocolViolation, users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the result of countDocuments holds no n", d.message());

    same.reply = bson.literal(.{ .n = -3, .ok = 1.0 });
    try testing.expectError(error.ProtocolViolation, users.estimatedDocumentCount(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of count holds an n that is not a count: a whole number, 0 or more", d.message());
    same.reply = Script.ok;
    try testing.expectError(error.ProtocolViolation, users.estimatedDocumentCount(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of count holds no n", d.message());
}

test "estimatedDocumentCount sends count without a query, and returns n" {
    const io = testing.io;
    var same: Same = .{ .reply = bson.literal(.{ .n = 7, .ok = 1.0 }) };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const users = f.users();
    try testing.expectEqual(@as(u64, 7), try users.estimatedDocumentCount(io, .of(.root), .{ .allocator = testing.allocator }));
    try expectBody(bson.literal(.{ .count = "users", .@"$db" = "app" }), f.body(0));
    try testing.expectEqual(@as(u64, 7), try users.estimatedDocumentCount(io, .of(.root), .{ .allocator = testing.allocator, .comment = .{ .string = "size" } }));
    try expectBody(bson.literal(.{ .count = "users", .comment = "size", .@"$db" = "app" }), f.body(1));
}

test "distinct sends key and query, the filter in any form, and returns values as an array" {
    const io = testing.io;
    var same: Same = .{ .reply = bson.literal(.{ .values = .{ "Ann", "Bob" }, .ok = 1.0 }) };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const users = f.users();

    var b: bson.Builder = .init(testing.allocator);
    try b.putBoolean("active", true);
    const built = try b.finish();
    defer built.deinit();
    const Filter = struct { active: bool };
    inline for (.{ bson.literal(.{ .active = true }), built, Filter{ .active = true }, .{ .active = true } }, 0..) |filter, i| {
        const values = try users.distinct(io, .of(.root), "name", filter, .{ .allocator = testing.allocator });
        defer values.deinit();
        var it = values.raw().iterator();
        try testing.expectEqualStrings("Ann", (try it.next()).?.value.string);
        try testing.expectEqualStrings("Bob", (try it.next()).?.value.string);
        try testing.expect(try it.next() == null);
        try expectBody(bson.literal(.{ .distinct = "users", .key = "name", .query = .{ .active = true }, .@"$db" = "app" }), f.body(i));
    }

    const values = try users.distinct(io, .of(.root), "name", .{}, .{
        .allocator = testing.allocator,
        .collation = bson.literal(.{ .locale = "en", .strength = 1 }),
        .comment = .{ .string = "names" },
    });
    values.deinit();
    try expectBody(bson.literal(.{ .distinct = "users", .key = "name", .query = .{}, .collation = .{ .locale = "en", .strength = 1 }, .comment = "names", .@"$db" = "app" }), f.body(4));

    var d: mongo.Diagnostics = .{};
    same.reply = Script.ok;
    try testing.expectError(error.ProtocolViolation, users.distinct(io, .of(.root), "name", .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of distinct holds no values", d.message());
    same.reply = bson.literal(.{ .values = "Ann", .ok = 1.0 });
    try testing.expectError(error.ProtocolViolation, users.distinct(io, .of(.root), "name", .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("values in the reply of distinct is not an array", d.message());
}

test "ok 0 is CommandFailed, with the reply in failure_reply, for the counts, distinct and aggregate" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "ns does not exist", .code = 26, .codeName = "NamespaceNotFound" });
    var same: Same = .{ .reply = refused };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;

    try testing.expectError(error.CommandFailed, users.estimatedDocumentCount(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    failure.?.deinit();
    failure = null;
    try testing.expectEqual(@as(i32, 26), d.server.?.code);
    try testing.expectError(error.CommandFailed, users.distinct(io, .of(.root), "n", .{}, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    failure.?.deinit();
    failure = null;
    try testing.expectError(error.CommandFailed, users.countDocuments(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    failure.?.deinit();
    failure = null;
    try testing.expectError(error.CommandFailed, users.aggregate(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    failure.?.deinit();
    try testing.expectEqualStrings("ns does not exist", d.message());
}

test "a bad collection name, filter or stage is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var same: Same = .{ .reply = Script.ok };
    var f: Fixture = .{};
    f.init(same.handler());
    defer f.deinit();
    const db: mongo.Database = .init(f.fake.client(), "app", &f.ids);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, db.collection("").aggregate(io, .of(.root), .{}, .{ .allocator = a, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("$x").countDocuments(io, .of(.root), .{}, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, db.collection("$x").estimatedDocumentCount(io, .of(.root), .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, db.collection("$x").distinct(io, .of(.root), "n", .{}, .{ .allocator = a }));

    const bad: []const u8 = "\xff";
    const users = db.collection("users");
    try testing.expectError(error.InvalidArgument, users.aggregate(io, .of(.root), .{.{ .@"$match" = .{ .name = bad } }}, .{ .allocator = a, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pipeline cannot be written as BSON"));
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, users.aggregate(io, .of(.root), .{ bson.literal(.{ .@"$match" = .{} }), broken }, .{ .allocator = a, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the pipeline cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, users.countDocuments(io, .of(.root), .{ .name = bad }, .{ .allocator = a, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the filter cannot be written as BSON"));
    try testing.expectError(error.InvalidArgument, users.distinct(io, .of(.root), "n", broken, .{ .allocator = a, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the filter cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
