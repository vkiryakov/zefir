//! Tests of `find` and `findOne` on the client against
//! `mongo.testing.FakeServer`: the exact `find` commands and `getMore`s in
//! the script's journal, and the documents they give, in each form of the
//! filter.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

const ann = bson.literal(.{ ._id = 1, .name = "Ann" });
const bob = bson.literal(.{ ._id = 2, .name = "Bob" });
const cid = bson.literal(.{ ._id = 3, .name = "Cid" });
const batches = [_][]const bson.RawDocument{ &.{ ann, bob }, &.{cid} };

/// A cursor of users on the server, and the client on it.
const Fixture = struct {
    cursor: Script.Cursor = .{ .ns = "app.users", .batches = &batches },
    served: Served = undefined,
    /// The script of the server.
    script: *Script = undefined,
    ids: bson.ObjectId.Generator = .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) },

    /// Lives where it is: the server and the client point into it.
    fn init(f: *Fixture) !void {
        try f.served.start(testing.io, f.cursor.handler(), .{});
        f.script = &f.served.script;
    }

    fn deinit(f: *Fixture) void {
        f.served.stop(testing.io);
    }

    fn users(f: *Fixture) mongo.Collection {
        return mongo.Database.init(f.served.client(), "app", &f.ids).collection("users");
    }
};

/// Reads `cursor` to its end, and fails unless it gives `expected`.
fn expectDocuments(cursor: mongo.Cursor, expected: []const bson.RawDocument) !void {
    const io = testing.io;
    for (expected) |doc| {
        const got = (try cursor.next(io, .of(.root))) orelse return error.TestCursorEndedEarly;
        try testing.expectEqualSlices(u8, doc.bytes, got.bytes);
    }
    try testing.expect(try cursor.next(io, .of(.root)) == null);
}

fn filterByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.beginDocument("age");
    try b.putInt32("$gte", 18);
    try b.end();
    return b.finish();
}

test "find sends find with the filter, in each of the three forms, and its cursor gives the documents of every batch" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.users();

    const built = try filterByBuilder();
    defer built.deinit();
    const Age = struct { @"$gte": i32 };
    const Filter = struct { age: Age };
    inline for (.{ bson.literal(.{ .age = .{ .@"$gte" = 18 } }), built, Filter{ .age = .{ .@"$gte" = 18 } }, .{ .age = .{ .@"$gte" = 18 } } }, 0..) |filter, i| {
        const cursor = try users.find(io, .of(.root), filter, .{ .allocator = testing.allocator });
        defer cursor.deinit(io);
        try expectDocuments(cursor, &.{ ann, bob, cid });
        const sent = try f.script.entry(io, 2 * i);
        try testing.expectEqualStrings("find", sent.name);
        try testing.expect(sent.sequence == null);
        try testing.expectEqualSlices(u8, bson.literal(.{ .find = "users", .filter = .{ .age = .{ .@"$gte" = 18 } }, .@"$db" = "app" }).bytes, sent.body.bytes);
        const more = try f.script.entry(io, 2 * i + 1);
        try testing.expectEqualSlices(u8, bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .@"$db" = "app" }).bytes, more.body.bytes);
    }
    try testing.expectEqual(@as(usize, 8), f.script.received(io));
}

test "find(.{}) sends filter: {}" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const cursor = try f.users().find(io, .of(.root), .{}, .{ .allocator = testing.allocator });
    defer cursor.deinit(io);
    try testing.expectEqualSlices(u8, bson.literal(.{ .find = "users", .filter = .{}, .@"$db" = "app" }).bytes, (try f.script.entry(io, 0)).body.bytes);
}

test "the options of find go out in their order, and the batch size and the comment go to each getMore too" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const cursor = try f.users().find(io, .of(.root), .{ .name = .{ .@"$ne" = "Dan" } }, .{
        .allocator = testing.allocator,
        .sort = bson.literal(.{ .name = 1 }),
        .projection = bson.literal(.{ .name = 1 }),
        .skip = 1,
        .limit = 10,
        .batch_size = 2,
        .hint = .{ .name = "name_1" },
        .collation = bson.literal(.{ .locale = "en" }),
        .let = bson.literal(.{ .x = 1 }),
        .allow_disk_use = false,
        .comment = .{ .string = "list users" },
    });
    defer cursor.deinit(io);
    try expectDocuments(cursor, &.{ ann, bob, cid });
    try testing.expectEqualSlices(u8, bson.literal(.{
        .find = "users",
        .filter = .{ .name = .{ .@"$ne" = "Dan" } },
        .sort = .{ .name = 1 },
        .projection = .{ .name = 1 },
        .hint = "name_1",
        .skip = 1,
        .limit = 10,
        .batchSize = 2,
        .comment = "list users",
        .collation = .{ .locale = "en" },
        .allowDiskUse = false,
        .let = .{ .x = 1 },
        .@"$db" = "app",
    }).bytes, (try f.script.entry(io, 0)).body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .getMore = @as(i64, 42),
        .collection = "users",
        .batchSize = 2,
        .comment = "list users",
        .@"$db" = "app",
    }).bytes, (try f.script.entry(io, 1)).body.bytes);
}

test "find with a limit equal to its batch size asks for one more in the first batch, so that the server closes the cursor" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.users();
    for ([_][2]u32{ .{ 5, 5 }, .{ 0, 0 }, .{ 5, 4 }, .{ std.math.maxInt(u32), std.math.maxInt(u32) } }, 0..) |case, i| {
        const cursor = try users.find(io, .of(.root), .{}, .{ .allocator = testing.allocator, .limit = case[0], .batch_size = case[1] });
        cursor.deinit(io);
        const body = (try f.script.entry(io, 2 * i)).body;
        const expected = switch (i) {
            0 => bson.literal(.{ .find = "users", .filter = .{}, .limit = 5, .batchSize = 6, .@"$db" = "app" }),
            // A limit of 0 is none: the batch size goes as it is.
            1 => bson.literal(.{ .find = "users", .filter = .{}, .batchSize = 0, .@"$db" = "app" }),
            2 => bson.literal(.{ .find = "users", .filter = .{}, .limit = 5, .batchSize = 4, .@"$db" = "app" }),
            else => bson.literal(.{ .find = "users", .filter = .{}, .limit = @as(i64, std.math.maxInt(u32)), .batchSize = @as(i64, 1 << 32), .@"$db" = "app" }),
        };
        try testing.expectEqualSlices(u8, expected.bytes, body.bytes);
        // deinit killed the cursor, open after its first batch.
        try testing.expectEqualStrings("killCursors", (try f.script.entry(io, 2 * i + 1)).name);
    }
}

test "findOne sends limit: 1 and singleBatch: true without a batch size, and returns a copy of the document" {
    const io = testing.io;
    const reply = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ ._id = 1, .name = "Ann" }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = reply }, .{ .reply = reply }, .{ .reply = reply }, .{ .reply = reply } } };
    var served: Served = undefined;
    try served.start(io, queue.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    const built = try filterByBuilder();
    defer built.deinit();
    const Age = struct { @"$gte": i32 };
    const Filter = struct { age: Age };
    inline for (.{ bson.literal(.{ .age = .{ .@"$gte" = 18 } }), built, Filter{ .age = .{ .@"$gte" = 18 } }, .{ .age = .{ .@"$gte" = 18 } } }, 0..) |filter, i| {
        const doc = (try users.findOne(io, .of(.root), filter, .{ .allocator = testing.allocator })) orelse return error.TestNoDocument;
        defer doc.deinit();
        try testing.expectEqualSlices(u8, ann.bytes, doc.bytes);
        try testing.expectEqualSlices(u8, bson.literal(.{
            .find = "users",
            .filter = .{ .age = .{ .@"$gte" = 18 } },
            .limit = 1,
            .singleBatch = true,
            .@"$db" = "app",
        }).bytes, (try script.entry(io, i)).body.bytes);
    }
    // The cursor was closed on the server: no killCursors went out.
    try testing.expectEqual(@as(usize, 4), script.received(io));
}

test "the options of findOne go out in their order" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = (try f.users().findOne(io, .of(.root), .{}, .{
        .allocator = testing.allocator,
        .sort = bson.literal(.{ .name = -1 }),
        .projection = bson.literal(.{ ._id = 0 }),
        .skip = 2,
        .hint = .{ .keys = bson.literal(.{ .name = 1 }) },
        .collation = bson.literal(.{ .locale = "fr" }),
        .let = bson.literal(.{ .y = 2 }),
        .comment = .{ .int32 = 7 },
    })) orelse return error.TestNoDocument;
    defer doc.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{
        .find = "users",
        .filter = .{},
        .sort = .{ .name = -1 },
        .projection = .{ ._id = 0 },
        .hint = .{ .name = 1 },
        .skip = 2,
        .limit = 1,
        .singleBatch = true,
        .comment = 7,
        .collation = .{ .locale = "fr" },
        .let = .{ .y = 2 },
        .@"$db" = "app",
    }).bytes, (try f.script.entry(io, 0)).body.bytes);
}

test "findOne frees its cursor: one left open on the server gets its killCursors" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = (try f.users().findOne(io, .of(.root), .{}, .{ .allocator = testing.allocator })) orelse return error.TestNoDocument;
    defer doc.deinit();
    try testing.expectEqualSlices(u8, ann.bytes, doc.bytes);
    try testing.expectEqual(@as(usize, 2), f.script.received(io));
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "users", .cursors = .{@as(i64, 42)}, .@"$db" = "app" }).bytes, (try f.script.entry(io, 1)).body.bytes);
}

test "findOne of no document is null" {
    const io = testing.io;
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{} };
    var served: Served = undefined;
    try served.start(io, cursor.handler(), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    try testing.expect(try users.findOne(io, .of(.root), .{ .name = "Dan" }, .{ .allocator = testing.allocator }) == null);
    const empty = try users.find(io, .of(.root), .{ .name = "Dan" }, .{ .allocator = testing.allocator });
    defer empty.deinit(io);
    try testing.expect(try empty.next(io, .of(.root)) == null);
}

test "ok 0 of find is CommandFailed, with the reply in failure_reply; a reply without a cursor is a protocol violation" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "unknown operator: $bad", .code = 2, .codeName = "BadValue" });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = refused }, .{ .reply = refused }, .{ .reply = Script.ok } } };
    var served: Served = undefined;
    try served.start(io, queue.handler(), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, users.find(io, .of(.root), .{ .n = .{ .@"$bad" = 1 } }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    failure.?.deinit();
    try testing.expectEqual(@as(i32, 2), d.server.?.code);
    try testing.expectEqualStrings("unknown operator: $bad", d.message());
    try testing.expectError(error.CommandFailed, users.findOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 2), d.server.?.code);
    try testing.expectError(error.ProtocolViolation, users.findOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the reply holds no cursor; the command may have run", d.message());
}

test "a Diagnostics and a failure_reply passed to find serve find alone: the getMores of its cursor leave them alone, and keep their errors in the cursor" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    defer if (failure) |reply| reply.deinit();
    const cursor = try users.find(io, .of(.root), .{}, .{ .allocator = testing.allocator, .batch_size = 1, .diagnostics = &d, .failure_reply = &failure });
    defer cursor.deinit(io);
    // From here on, the caller's own: say, a helper's stack, gone.
    d.set(.wait, null, "the caller's own", .{});
    try expectNextIs(cursor, ann);
    try expectNextIs(cursor, bob);
    // Another find of the same cursor on the server, and its killCursors:
    // the server holds the first cursor no more.
    const other = try users.find(io, .of(.root), .{}, .{ .allocator = testing.allocator });
    other.deinit(io);
    try testing.expectError(error.CommandFailed, cursor.next(io, .of(.root)));
    try testing.expectEqualStrings("the caller's own", d.message());
    try testing.expect(d.server == null);
    try testing.expect(failure == null);
    try testing.expectEqual(@as(?i32, 43), if (cursor.diagnostics().server) |server| server.code else null);
    try testing.expectEqualStrings("cursor id 42 not found", cursor.diagnostics().message());
    const reply = cursor.failureReply() orelse return error.TestNoFailureReply;
    try testing.expectEqual(@as(?i32, 43), if (try reply.get("code")) |code| @as(i32, @intCast(try code.asI64())) else null);
}

fn expectNextIs(cursor: mongo.Cursor, expected: bson.RawDocument) !void {
    const got = (try cursor.next(testing.io, .of(.root))) orelse return error.TestCursorEndedEarly;
    try testing.expectEqualSlices(u8, expected.bytes, got.bytes);
}

test "findOne copies the reply of a refusal into options.allocator, of its find as of a getMore, with the diagnostics of the getMore" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "unknown operator: $bad", .code = 2, .codeName = "BadValue" });
    const pending = bson.literal(.{ .cursor = .{ .firstBatch = [0]i32{}, .id = @as(i64, 9), .ns = "app.users" }, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = refused }, .{ .reply = pending }, .{ .reply = refused }, .{ .reply = Script.ok } } };
    var served: Served = undefined;
    try served.start(io, queue.handler(), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    // An arena frees what it gave; a copy in the client's memory would
    // leak, and the test allocator would say so.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: mongo.Diagnostics = .{};
    for (0..2) |_| {
        var failure: ?bson.OwnedDocument = null;
        try testing.expectError(error.CommandFailed, users.findOne(io, .of(.root), .{}, .{ .allocator = a, .diagnostics = &d, .failure_reply = &failure }));
        const reply = failure orelse return error.TestNoFailureReply;
        try testing.expect(reply.allocator.ptr == a.ptr);
        try testing.expectEqualSlices(u8, refused.bytes, reply.bytes);
        try testing.expectEqual(@as(?i32, 2), if (d.server) |server| server.code else null);
        try testing.expectEqualStrings("unknown operator: $bad", d.message());
    }
    // The second refusal was of the getMore.
    try testing.expectEqual(@as(usize, 1), served.script.count(io, "getMore"));
}

test "a bad collection name, filter or sort is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const db: mongo.Database = .init(f.served.client(), "app", &f.ids);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, db.collection("").find(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("a$b").findOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    const bad: []const u8 = "\xff";
    try testing.expectError(error.InvalidArgument, db.collection("users").find(io, .of(.root), .{ .name = bad }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the filter cannot be written as BSON"));
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, db.collection("users").findOne(io, .of(.root), .{}, .{ .allocator = testing.allocator, .sort = broken, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the sort cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
