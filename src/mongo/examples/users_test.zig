//! Tests of the users of the shop without MongoDB. Each runs `Users` on a
//! real `mongo.Client`, connected to `mongo.testing.FakeServer`: a server
//! on loopback that plays a `mongo.testing.Script`, which says what to
//! answer and keeps a journal of what came.

const std = @import("std");
const mongo = @import("mongo");
const Users = @import("Users.zig");
const bson = mongo.bson;
const testing = std.testing;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;

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
    const insert = script.entry(io, 0);
    try testing.expectEqualStrings("insert", insert.name);
    try testing.expectEqualStrings("shop", insert.database);
    try testing.expectEqualStrings("users", (try insert.body.get("insert")).?.string);
    // Its documents go in a section of their own: here, one.
    var documents = insert.sequence.?.documents();
    const sent = documents.next().?;
    try testing.expect(documents.next() == null);
    // The _id that the insert made comes first, and signUp returned it.
    const first = (try sent.first()).?;
    try testing.expectEqualStrings("_id", first.key);
    try testing.expectEqualSlices(u8, &id.bytes, &first.value.object_id.bytes);
    try testing.expectEqualStrings("ann@example.com", (try sent.get("email")).?.string);
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

    const ann = (try users.byEmail(io, .of(.root), arena.allocator(), "ann@example.com")).?;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expect(ann._id == null);

    // findOne is a find of the e-mail, for one document in one batch.
    const find = script.entry(io, 0);
    try testing.expectEqualStrings("find", find.name);
    try testing.expectEqualStrings("ann@example.com", (try find.body.getPath("filter.email")).?.string);
    try testing.expectEqual(@as(i64, 1), try (try find.body.get("limit")).?.asI64());
    try testing.expect((try find.body.get("singleBatch")).?.boolean);
}
