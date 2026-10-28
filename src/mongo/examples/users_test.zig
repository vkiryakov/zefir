//! Tests of the users of the shop without MongoDB. Each runs `Users` on a
//! real `mongo.Client`, connected to `mongo.testing.FakeServer`: a server
//! on loopback that plays a `mongo.testing.Script`, which says what to
//! answer and keeps a journal of what came.

const std = @import("std");
const mongo = @import("mongo");
const Users = @import("Users.zig");
const bson = @import("mongo-bson");
const testing = std.testing;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;

// These tests check each optional and the tag of each union before they
// take the value inside: `.?` or a field of a union of another tag would
// stop a test with a panic, where a regression has to fail it.

/// The string `value` of a document; the test fails on anything else.
fn stringOf(value: ?bson.Value) ![]const u8 {
    return switch (value orelse return error.TestUnexpectedResult) {
        .string => |text| text,
        else => error.TestUnexpectedResult,
    };
}

/// The ObjectId `value` of a document; the test fails on anything else.
fn objectIdOf(value: ?bson.Value) !bson.ObjectId {
    return switch (value orelse return error.TestUnexpectedResult) {
        .object_id => |id| id,
        else => error.TestUnexpectedResult,
    };
}

/// The boolean `value` of a document; the test fails on anything else.
fn boolOf(value: ?bson.Value) !bool {
    return switch (value orelse return error.TestUnexpectedResult) {
        .boolean => |flag| flag,
        else => error.TestUnexpectedResult,
    };
}

/// The integer `value` of a document, an int32, an int64 or a double
/// without a fraction; the test fails on anything else.
fn i64Of(value: ?bson.Value) !i64 {
    return (value orelse return error.TestUnexpectedResult).asI64();
}

test "a sign-up is one insert of one document, with the _id made first" {
    const io = testing.io;
    // The script: answer each insert as mongod does, {n: 1, ok: 1}.
    var write: Script.Write = .{};
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    // The server plays it on loopback, in a task of its own.
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    // A client of it, as of any mongod.
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var ids: bson.ObjectId.Generator = .init(io);
    const users: Users = .init(.init(&client, "shop", &ids));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const id = try users.signUp(io, .of(.root), arena.allocator(), .{ .email = "ann@example.com", .name = "Ann" });

    // The journal: one command came, an insert into shop.users.
    try testing.expectEqual(@as(usize, 1), script.received(io));
    const insert = try script.entry(io, 0);
    try testing.expectEqualStrings("insert", insert.name);
    try testing.expectEqualStrings("shop", insert.database);
    try testing.expectEqualStrings("users", try stringOf(try insert.body.get("insert")));
    // Its documents go in a section of their own: here, one.
    const sequence = insert.sequence orelse return error.TestUnexpectedResult;
    var documents = sequence.documents();
    const sent = documents.next() orelse return error.TestUnexpectedResult;
    try testing.expect(documents.next() == null);
    // The _id that the insert made comes first, and signUp returned it.
    const first = try sent.first() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("_id", first.key);
    try testing.expectEqualSlices(u8, &id.bytes, &(try objectIdOf(first.value)).bytes);
    try testing.expectEqualStrings("ann@example.com", try stringOf(try sent.get("email")));
}

test "a second sign-up with the same e-mail is EmailTaken, and nothing is sent again" {
    const io = testing.io;
    // The server refuses the second document of all the inserts it gets,
    // as the unique index of mongod refuses a duplicate key: code 11000.
    var write: Script.Write = .{ .refuse = &.{.{ .index = 1 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var ids: bson.ObjectId.Generator = .init(io);
    const users: Users = .init(.init(&client, "shop", &ids));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    _ = try users.signUp(io, .of(.root), arena.allocator(), .{ .email = "ann@example.com", .name = "Ann" });
    try testing.expectError(error.EmailTaken, users.signUp(io, .of(.root), arena.allocator(), .{ .email = "ann@example.com", .name = "Ann B." }));
    // Two sign-ups, two inserts: the client retries nothing.
    try testing.expectEqual(@as(usize, 2), script.count(io, "insert"));
}

test "byEmail asks for one document by its e-mail, and reads it into a User" {
    const io = testing.io;
    // The server answers find with a cursor of one batch, of one user.
    const found = [_]bson.RawDocument{bson.literal(.{ .email = "ann@example.com", .name = "Ann" })};
    var cursor: Script.Cursor = .{ .ns = "shop.users", .batches = &.{&found} };
    var script: Script = .init(testing.allocator, cursor.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var ids: bson.ObjectId.Generator = .init(io);
    const users: Users = .init(.init(&client, "shop", &ids));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const ann = try users.byEmail(io, .of(.root), arena.allocator(), "ann@example.com") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expect(ann._id == null);

    // findOne is a find of the e-mail, for one document in one batch.
    const find = try script.entry(io, 0);
    try testing.expectEqualStrings("find", find.name);
    try testing.expectEqualStrings("ann@example.com", try stringOf(try find.body.getPath("filter.email")));
    try testing.expectEqual(@as(i64, 1), try i64Of(try find.body.get("limit")));
    try testing.expect(try boolOf(try find.body.get("singleBatch")));
}
