//! Tests of `Collection.drop` and of the operations of `mongo.Database` on
//! `mongo.testing.FakeDriver`: `listCollections`, `drop`, `runCommand` and
//! `runCursorCommand`, their exact commands in the script's journal and
//! what their replies give.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;

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

    fn db(f: *Fixture) mongo.Database {
        return .init(f.fake.client(), "app", &f.ids);
    }

    fn body(f: *Fixture, i: usize) bson.RawDocument {
        return f.script.entry(testing.io, i).body;
    }
};

fn expectBody(expected: bson.RawDocument, got: bson.RawDocument) !void {
    if (!std.mem.eql(u8, expected.bytes, got.bytes)) {
        std.debug.print("expected {f}\n     got {f}\n", .{ expected, got });
        return error.TestUnexpectedCommand;
    }
}

const not_found = bson.literal(.{ .ok = 0.0, .errmsg = "ns not found", .code = 26, .codeName = "NamespaceNotFound" });
const unauthorized = bson.literal(.{ .ok = 0.0, .errmsg = "not authorized on app to execute command", .code = 13, .codeName = "Unauthorized" });

test "Collection.drop sends drop; a collection that is not there, code 26, is no error and leaves no trace" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = bson.literal(.{ .ns = "app.users", .nIndexesWas = 1, .ok = 1.0 }) }, .{ .reply = not_found }, .{ .reply = unauthorized } } };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const users = f.db().collection("users");
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;

    try users.drop(io, .of(.root), .{ .allocator = testing.allocator });
    try expectBody(bson.literal(.{ .drop = "users", .@"$db" = "app" }), f.body(0));
    try users.drop(io, .of(.root), .{ .allocator = testing.allocator, .comment = .{ .string = "clean" }, .diagnostics = &d, .failure_reply = &failure });
    try expectBody(bson.literal(.{ .drop = "users", .comment = "clean", .@"$db" = "app" }), f.body(1));
    try testing.expect(d.server == null);
    try testing.expectEqualStrings("", d.message());
    try testing.expect(failure == null);

    try testing.expectError(error.CommandFailed, users.drop(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, unauthorized.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
    try testing.expectEqualStrings("not authorized on app to execute command", d.message());
}

test "listCollections sends listCollections: 1 with its options, and its comment never goes to getMore" {
    const io = testing.io;
    const users = bson.literal(.{ .name = "users", .type = "collection" });
    const posts = bson.literal(.{ .name = "posts", .type = "collection" });
    var cursor: Script.Cursor = .{ .ns = "app.$cmd.listCollections", .batches = &.{ &.{users}, &.{posts} } };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const db = f.db();
    {
        const collections = try db.listCollections(io, .of(.root), .{ .allocator = testing.allocator });
        defer collections.deinit(io);
        try testing.expectEqualSlices(u8, users.bytes, (try collections.next(io, .of(.root))).?.bytes);
        try testing.expectEqualSlices(u8, posts.bytes, (try collections.next(io, .of(.root))).?.bytes);
        try testing.expect(try collections.next(io, .of(.root)) == null);
        try expectBody(bson.literal(.{ .listCollections = 1, .cursor = .{}, .@"$db" = "app" }), f.body(0));
        try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "$cmd.listCollections", .@"$db" = "app" }), f.body(1));
    }
    const collections = try db.listCollections(io, .of(.root), .{
        .allocator = testing.allocator,
        .filter = bson.literal(.{ .name = .{ .@"$in" = .{ "users", "posts" } } }),
        .name_only = true,
        .authorized_collections = true,
        .batch_size = 1,
        .comment = .{ .string = "tables" },
    });
    defer collections.deinit(io);
    while (try collections.next(io, .of(.root))) |_| {}
    try expectBody(bson.literal(.{
        .listCollections = 1,
        .filter = .{ .name = .{ .@"$in" = .{ "users", "posts" } } },
        .nameOnly = true,
        .authorizedCollections = true,
        .cursor = .{ .batchSize = 1 },
        .comment = "tables",
        .@"$db" = "app",
    }), f.body(2));
    try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "$cmd.listCollections", .batchSize = 1, .@"$db" = "app" }), f.body(3));
}

test "Database.drop sends dropDatabase: 1" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = bson.literal(.{ .dropped = "app", .ok = 1.0 }) }, .{ .reply = Script.ok }, .{ .reply = unauthorized } } };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const db = f.db();
    try db.drop(io, .of(.root), .{ .allocator = testing.allocator });
    try expectBody(bson.literal(.{ .dropDatabase = 1, .@"$db" = "app" }), f.body(0));
    try db.drop(io, .of(.root), .{ .allocator = testing.allocator, .comment = .{ .string = "reset" } });
    try expectBody(bson.literal(.{ .dropDatabase = 1, .comment = "reset", .@"$db" = "app" }), f.body(1));
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.CommandFailed, db.drop(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
}

test "runCommand sends the command as it is, in each of the three forms, with the database's $db, and returns the reply" {
    const io = testing.io;
    const reply = bson.literal(.{ .n = 3, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = reply }, .{ .reply = reply }, .{ .reply = reply }, .{ .reply = reply } } };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const db = f.db();

    var b: bson.Builder = .init(testing.allocator);
    try b.putString("count", "users");
    try b.beginDocument("query");
    try b.putBoolean("active", true);
    try b.end();
    const built = try b.finish();
    defer built.deinit();
    const Count = struct { count: []const u8, query: struct { active: bool } };
    inline for (.{ bson.literal(.{ .count = "users", .query = .{ .active = true } }), built, Count{ .count = "users", .query = .{ .active = true } }, .{ .count = "users", .query = .{ .active = true } } }, 0..) |command, i| {
        const got = try db.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator });
        defer got.deinit();
        try testing.expectEqualSlices(u8, reply.bytes, got.bytes);
        try expectBody(bson.literal(.{ .count = "users", .query = .{ .active = true }, .@"$db" = "app" }), f.body(i));
    }
}

test "runCommand is bound by the rules of the contract only" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = Script.ok }, .{ .reply = unauthorized } } };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const db = f.db();
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, db.runCommand(io, .of(.root), .{ .ping = 1, .@"$db" = "admin" }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the command holds '$db', which only the driver writes", d.message());
    const deadline: core.Context = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(60)));
    try testing.expectError(error.InvalidArgument, db.runCommand(io, .of(deadline), .{ .ping = 1, .maxTimeMS = 5 }, .{ .allocator = testing.allocator }));
    // Without a deadline, maxTimeMS of the command goes as it is.
    const pong = try db.runCommand(io, .of(.root), .{ .ping = 1, .maxTimeMS = 5 }, .{ .allocator = testing.allocator });
    pong.deinit();
    try expectBody(bson.literal(.{ .ping = 1, .maxTimeMS = 5, .@"$db" = "app" }), f.body(0));
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, db.runCommand(io, .of(.root), .{ .ping = 1 }, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, unauthorized.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
    const bad: []const u8 = "\xff";
    try testing.expectError(error.InvalidArgument, db.runCommand(io, .of(.root), .{ .ping = bad }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the command cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 2), f.script.received(io));
}

test "runCursorCommand opens the cursor of the command as it is, with the batch size of each getMore" {
    const io = testing.io;
    const ann = bson.literal(.{ ._id = 1 });
    const bob = bson.literal(.{ ._id = 2 });
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{ &.{ann}, &.{bob} } };
    var f: Fixture = .{};
    f.init(cursor.handler());
    defer f.deinit();
    const db = f.db();
    {
        const docs = try db.runCursorCommand(io, .of(.root), .{ .find = "users", .filter = .{}, .batchSize = 1 }, .{ .allocator = testing.allocator, .batch_size = 5 });
        defer docs.deinit(io);
        try testing.expectEqualSlices(u8, ann.bytes, (try docs.next(io, .of(.root))).?.bytes);
        try testing.expectEqualSlices(u8, bob.bytes, (try docs.next(io, .of(.root))).?.bytes);
        try testing.expect(try docs.next(io, .of(.root)) == null);
    }
    try expectBody(bson.literal(.{ .find = "users", .filter = .{}, .batchSize = 1, .@"$db" = "app" }), f.body(0));
    try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .batchSize = 5, .@"$db" = "app" }), f.body(1));
    const raw = try db.runCursorCommand(io, .of(.root), bson.literal(.{ .aggregate = "users", .pipeline = [0]i32{}, .cursor = .{} }), .{ .allocator = testing.allocator });
    raw.deinit(io);
    try expectBody(bson.literal(.{ .aggregate = "users", .pipeline = [0]i32{}, .cursor = .{}, .@"$db" = "app" }), f.body(2));
}

test "ok 0 of runCursorCommand and listCollections is CommandFailed, with the reply in failure_reply" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = unauthorized }, .{ .reply = unauthorized } } };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const db = f.db();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, db.runCursorCommand(io, .of(.root), .{ .find = "users" }, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    try testing.expectEqualSlices(u8, unauthorized.bytes, failure.?.bytes);
    failure.?.deinit();
    failure = null;
    try testing.expectError(error.CommandFailed, db.listCollections(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
}

test "a bad database name is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{} };
    var f: Fixture = .{};
    f.init(queue.handler());
    defer f.deinit();
    const bad: mongo.Database = .init(f.fake.client(), "a.b", &f.ids);
    const a = testing.allocator;
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, bad.listCollections(io, .of(.root), .{ .allocator = a, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "a database name holds none of"));
    try testing.expectError(error.InvalidArgument, bad.drop(io, .of(.root), .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.runCommand(io, .of(.root), .{ .ping = 1 }, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.runCursorCommand(io, .of(.root), .{ .find = "users" }, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.collection("users").drop(io, .of(.root), .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, f.db().collection("").drop(io, .of(.root), .{ .allocator = a, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
