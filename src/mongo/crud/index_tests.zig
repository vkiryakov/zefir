//! Tests of `createIndexes`, `listIndexes`, `dropIndex` and `dropIndexes`
//! on the client against `mongo.testing.FakeServer`: the exact commands in
//! the script's journal, and the names of the indexes.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// A script that answers each command with the next of `replies`, and
/// the client on it.
const Fixture = struct {
    replies: [8]Script.Answer = undefined,
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

const created = bson.literal(.{ .numIndexesBefore = 1, .numIndexesAfter = 4, .createdCollectionAutomatically = false, .ok = 1.0 });

fn freeNames(names: []const []const u8) void {
    for (names) |name| testing.allocator.free(name);
    testing.allocator.free(names);
}

fn expectBody(expected: bson.RawDocument, got: bson.RawDocument) !void {
    if (!std.mem.eql(u8, expected.bytes, got.bytes)) {
        std.debug.print("expected {f}\n     got {f}\n", .{ expected, got });
        return error.TestUnexpectedCommand;
    }
}

test "createIndexes sends the models in their order, each with its name, and returns the names" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(created);
    defer f.deinit();
    const names = try f.users().createIndexes(io, .of(.root), &.{
        .{ .keys = bson.literal(.{ .email = 1 }), .unique = true },
        .{ .keys = bson.literal(.{ .age = -1, .name = 1 }), .name = "by_age" },
        .{
            .keys = bson.literal(.{ .created = 1 }),
            .sparse = true,
            .expire_after_seconds = 3600,
            .partial_filter_expression = bson.literal(.{ .active = true }),
            .collation = bson.literal(.{ .locale = "en" }),
            .hidden = true,
        },
        .{ .keys = bson.literal(.{ .age = -1, .name = 1 }) },
    }, .{ .allocator = testing.allocator, .comment = .{ .string = "set up" } });
    defer freeNames(names);
    try testing.expectEqual(@as(usize, 4), names.len);
    try testing.expectEqualStrings("email_1", names[0]);
    try testing.expectEqualStrings("by_age", names[1]);
    try testing.expectEqualStrings("created_1", names[2]);
    try testing.expectEqualStrings("age_-1_name_1", names[3]);
    try expectBody(bson.literal(.{
        .createIndexes = "users",
        .indexes = .{
            .{ .key = .{ .email = 1 }, .name = "email_1", .unique = true },
            .{ .key = .{ .age = -1, .name = 1 }, .name = "by_age" },
            .{
                .key = .{ .created = 1 },
                .name = "created_1",
                .sparse = true,
                .expireAfterSeconds = 3600,
                .partialFilterExpression = .{ .active = true },
                .collation = .{ .locale = "en" },
                .hidden = true,
            },
            .{ .key = .{ .age = -1, .name = 1 }, .name = "age_-1_name_1" },
        },
        .comment = "set up",
        .@"$db" = "app",
    }), (try f.script.entry(io, 0)).body);
}

test "createIndexes of no models, or of a model whose keys make no name, is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(created);
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, users.createIndexes(io, .of(.root), &.{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("createIndexes has no models: it needs at least one", d.message());
    // The names made before the one that fails are freed: the allocator
    // of the test sees no leak.
    try testing.expectError(error.InvalidArgument, users.createIndexes(io, .of(.root), &.{
        .{ .keys = bson.literal(.{ .email = 1 }) },
        .{ .keys = bson.literal(.{ .a = true }) },
    }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "key 'a' of index 1 is of type boolean"));
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, users.createIndexes(io, .of(.root), &.{
        .{ .keys = bson.literal(.{ .email = 1 }), .name = "e" },
        .{ .keys = bson.literal(.{ .n = 1 }), .partial_filter_expression = broken },
    }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the partial filter expression of index 1 cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}

test "ok 0 of createIndexes is CommandFailed with the reply in failure_reply, and the names are freed" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "Index already exists with a different name: email_1", .code = 85, .codeName = "IndexOptionsConflict" });
    var f: Fixture = .{};
    try f.init(refused);
    defer f.deinit();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, f.users().createIndexes(io, .of(.root), &.{.{ .keys = bson.literal(.{ .email = 1 }), .name = "mail" }}, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 85), d.server.?.code);
}

test "listIndexes sends cursor: {} or its batch size, which goes with the comment to each getMore" {
    const io = testing.io;
    const id_index = bson.literal(.{ .v = 2, .key = .{ ._id = 1 }, .name = "_id_" });
    const email_index = bson.literal(.{ .v = 2, .key = .{ .email = 1 }, .name = "email_1", .unique = true });
    var cursor: Script.Cursor = .{ .ns = "app.users", .batches = &.{ &.{id_index}, &.{email_index} } };
    var served: Served = undefined;
    try served.start(io, cursor.handler(), .{});
    defer served.stop(io);
    const script = &served.script;
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    {
        const indexes = try users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator });
        defer indexes.deinit(io);
        try testing.expectEqualStrings("_id_", (try (try indexes.next(io, .of(.root))).?.get("name")).?.string);
        try testing.expectEqualStrings("email_1", (try (try indexes.next(io, .of(.root))).?.get("name")).?.string);
        try testing.expect(try indexes.next(io, .of(.root)) == null);
        try expectBody(bson.literal(.{ .listIndexes = "users", .cursor = .{}, .@"$db" = "app" }), (try script.entry(io, 0)).body);
        try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .@"$db" = "app" }), (try script.entry(io, 1)).body);
    }
    const indexes = try users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator, .batch_size = 1, .comment = .{ .string = "check" } });
    defer indexes.deinit(io);
    while (try indexes.next(io, .of(.root))) |_| {}
    try expectBody(bson.literal(.{ .listIndexes = "users", .cursor = .{ .batchSize = 1 }, .comment = "check", .@"$db" = "app" }), (try script.entry(io, 2)).body);
    try expectBody(bson.literal(.{ .getMore = @as(i64, 42), .collection = "users", .batchSize = 1, .comment = "check", .@"$db" = "app" }), (try script.entry(io, 3)).body);
}

const namespace_not_found = bson.literal(.{ .ok = 0.0, .errmsg = "ns does not exist: app.users", .code = 26, .codeName = "NamespaceNotFound" });

test "listIndexes of a collection that is not there, code 26, is an empty cursor, with or without diagnostics" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(namespace_not_found);
    defer f.deinit();
    const users = f.users();

    // With the caller's diagnostics and failure_reply: both stay empty.
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    {
        const indexes = try users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure });
        defer indexes.deinit(io);
        try testing.expect(try indexes.next(io, .of(.root)) == null);
        try testing.expect(try indexes.next(io, .of(.root)) == null);
        indexes.close(io);
        indexes.close(io);
    }
    try testing.expect(d.server == null);
    try testing.expectEqualStrings("", d.message());
    try testing.expect(failure == null);
    // Without them.
    {
        const indexes = try users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator, .batch_size = 1 });
        defer indexes.deinit(io);
        try testing.expect(try indexes.next(io, .of(.root)) == null);
    }
    // The command went out each time, and nothing else: no getMore, no
    // killCursors.
    try testing.expectEqual(@as(usize, 2), f.script.received(io));
    try expectBody(bson.literal(.{ .listIndexes = "users", .cursor = .{ .batchSize = 1 }, .@"$db" = "app" }), (try f.script.entry(io, 1)).body);
}

test "a cursor of listIndexes without diagnostics: the error of a getMore ends it, and its deinit frees all it holds" {
    const io = testing.io;
    const first = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ .v = 2, .key = .{ ._id = 1 }, .name = "_id_" }}, .id = @as(i64, 42), .ns = "app.users" }, .ok = 1.0 });
    const gone = bson.literal(.{ .ok = 0.0, .errmsg = "cursor id 42 not found", .code = 43, .codeName = "CursorNotFound" });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = first }, .{ .reply = gone } } };
    var served: Served = undefined;
    try served.start(io, queue.handler(), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    const indexes = try users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator });
    defer indexes.deinit(io);
    try testing.expectEqualStrings("_id_", (try (try indexes.next(io, .of(.root))).?.get("name")).?.string);
    try testing.expectError(error.CommandFailed, indexes.next(io, .of(.root)));
    try testing.expectError(error.Closed, indexes.next(io, .of(.root)));
}

test "listIndexes answered with any other code is CommandFailed, with or without diagnostics" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "not authorized on app to execute command { listIndexes: \"users\" }", .code = 13, .codeName = "Unauthorized" });
    var f: Fixture = .{};
    try f.init(refused);
    defer f.deinit();
    const users = f.users();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
    try testing.expectError(error.CommandFailed, users.listIndexes(io, .of(.root), .{ .allocator = testing.allocator }));
}

test "dropIndex sends dropIndexes with the name, dropIndexes with *, and dropIndex(\"*\") is InvalidArgument" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .nIndexesWas = 2, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    try users.dropIndex(io, .of(.root), "email_1", .{ .allocator = testing.allocator });
    try expectBody(bson.literal(.{ .dropIndexes = "users", .index = "email_1", .@"$db" = "app" }), (try f.script.entry(io, 0)).body);
    try users.dropIndexes(io, .of(.root), .{ .allocator = testing.allocator, .comment = .{ .string = "reset" } });
    try expectBody(bson.literal(.{ .dropIndexes = "users", .index = "*", .comment = "reset", .@"$db" = "app" }), (try f.script.entry(io, 1)).body);

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, users.dropIndex(io, .of(.root), "*", .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("dropIndex(\"*\") would drop every index of the collection: dropIndexes does that", d.message());
    try testing.expectEqual(@as(usize, 2), f.script.received(io));
}

test "ok 0 of dropIndex is CommandFailed, with the reply in failure_reply" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "index not found with name [nope]", .code = 27, .codeName = "IndexNotFound" });
    var f: Fixture = .{};
    try f.init(refused);
    defer f.deinit();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, f.users().dropIndex(io, .of(.root), "nope", .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 27), d.server.?.code);
}

test "a bad collection name is InvalidArgument for the indexes too, and nothing is sent" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(created);
    defer f.deinit();
    const bad = mongo.Database.init(f.served.client(), "app", &f.ids).collection("");
    const a = testing.allocator;
    try testing.expectError(error.InvalidArgument, bad.createIndexes(io, .of(.root), &.{.{ .keys = bson.literal(.{ .n = 1 }) }}, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.listIndexes(io, .of(.root), .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.dropIndex(io, .of(.root), "n_1", .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, bad.dropIndexes(io, .of(.root), .{ .allocator = a }));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
