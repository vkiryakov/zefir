//! The replies of `mongo.testing.Script` and `FakeServer` against
//! mongo-plain: every field that a ready handler, or the fake server
//! itself, writes is in mongod's reply to the same command, with the same
//! BSON type, so that tests on a script see what a driver sees from
//! mongod. And a document of every BSON type of zefir's vectors goes into
//! mongod and comes back byte for byte.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const bson = mongo.bson;
const opmsg = mongo.wire.opmsg;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;
const e2e = @import("root.zig");
const RawConn = e2e.RawConn;

/// Fails unless every element of `ours` is in `theirs` under the same key
/// and of the same BSON type, inside documents and arrays too.
fn expectFieldsIn(ours: bson.RawDocument, theirs: bson.RawDocument, path: []const u8) !void {
    var it = ours.iterator();
    while (try it.next()) |element| {
        const value = (try theirs.get(element.key)) orelse {
            std.debug.print("{s}{s} is not in mongod's reply {f}\n", .{ path, element.key, theirs });
            return error.TestFieldMissing;
        };
        const ours_type = std.meta.activeTag(element.value);
        const theirs_type = std.meta.activeTag(value);
        if (ours_type != theirs_type) {
            std.debug.print("{s}{s} is {t} here and {t} in mongod's reply {f}\n", .{ path, element.key, ours_type, theirs_type, theirs });
            return error.TestFieldOfAnotherType;
        }
        const inner_ours, const inner_theirs = switch (element.value) {
            .document, .array => |inner| .{ inner, switch (value) {
                .document, .array => |d| d,
                else => return error.TestFieldOfAnotherType,
            } },
            else => continue,
        };
        var buffer: [256]u8 = undefined;
        const inner_path = std.fmt.bufPrint(&buffer, "{s}{s}.", .{ path, element.key }) catch path;
        try expectFieldsIn(inner_ours, inner_theirs, inner_path);
    }
}

/// A command as a handler gets it, in the database of the tests.
fn request(name: []const u8, body: bson.RawDocument, sequence: ?opmsg.Section) Script.Request {
    return .{ .connection = 1, .name = name, .database = e2e.database, .body = body, .sequence = sequence };
}

fn replyOf(handler: Script.Handler, io: Io, arena: std.mem.Allocator, r: Script.Request) !bson.RawDocument {
    return switch (try handler.function(handler.context, io, arena, &r)) {
        .reply => |doc| doc,
        else => error.TestNotAReply,
    };
}

/// The documents of a section of kind 1, one after another.
fn concat(arena: std.mem.Allocator, docs: []const bson.RawDocument) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (docs) |doc| try bytes.appendSlice(arena, doc.bytes);
    return bytes.items;
}

fn drop(conn: *RawConn, arena: std.mem.Allocator, collection: []const u8) !void {
    const command = try bson.encode(arena, .{ .drop = collection }, .{});
    const reply = try conn.command(e2e.database, command.raw());
    reply.deinit();
}

/// Inserts `docs` into `collection`, all of them.
fn insert(conn: *RawConn, arena: std.mem.Allocator, collection: []const u8, docs: []const bson.RawDocument) !void {
    const body = try bson.encode(arena, .{ .insert = collection }, .{});
    const reply = try conn.exchange(.{
        .request_id = 0,
        .body = body.raw(),
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "documents", .documents = docs },
    }, null);
    defer reply.deinit();
    try mongo.wire.checkReply(reply.raw(), arena, null, null);
    if (try reply.raw().get("writeErrors")) |refused| {
        std.debug.print("mongod refused documents: {f}\n", .{refused.array});
        return error.TestInsertRefused;
    }
    try testing.expectEqual(@as(i64, @intCast(docs.len)), try (try reply.raw().get("n")).?.asI64());
}

test "Script.Cursor writes only what mongod writes in its replies to find, getMore and killCursors" {
    try e2e.onZio(cursorReplies);
}

fn cursorReplies(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(conn, a, "script_cursor");
    defer drop(conn, a, "script_cursor") catch {};
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 0, .n = "zero" }), bson.literal(.{ ._id = 1, .n = "one" }), bson.literal(.{ ._id = 2, .n = "two" }) };
    try insert(conn, a, "script_cursor", &docs);

    const find = bson.literal(.{ .find = "script_cursor", .filter = .{}, .sort = .{ ._id = 1 }, .batchSize = 1 });
    const found = try conn.command(e2e.database, find);
    defer found.deinit();
    const id = try (try found.raw().getPath("cursor.id")).?.asI64();
    try testing.expect(id != 0);
    var cursor: Script.Cursor = .{ .ns = e2e.database ++ ".script_cursor", .id = id, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } };
    const handler = cursor.handler();
    try expectFieldsIn(try replyOf(handler, io, a, request("find", find, null)), found.raw(), "");

    const more = try bson.encode(a, .{ .getMore = id, .collection = "script_cursor", .batchSize = 1 }, .{});
    const next = try conn.command(e2e.database, more.raw());
    defer next.deinit();
    try expectFieldsIn(try replyOf(handler, io, a, request("getMore", more.raw(), null)), next.raw(), "");
    try testing.expectEqualSlices(u8, docs[1].bytes, (try next.raw().getPath("cursor.nextBatch.0")).?.document.bytes);

    const kill = try bson.encode(a, .{ .killCursors = "script_cursor", .cursors = .{id} }, .{});
    const killed = try conn.command(e2e.database, kill.raw());
    defer killed.deinit();
    try testing.expectEqual(id, try (try killed.raw().getPath("cursorsKilled.0")).?.asI64());
    try expectFieldsIn(try replyOf(handler, io, a, request("killCursors", kill.raw(), null)), killed.raw(), "");
}

test "Script.Write writes only what mongod writes in its replies to insert, update and delete, writeErrors of a duplicate _id among them" {
    try e2e.onZio(writeReplies);
}

fn writeReplies(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(conn, a, "script_write");
    defer drop(conn, a, "script_write") catch {};
    try insert(conn, a, "script_write", &.{bson.literal(.{ ._id = 0 })});

    // The second document repeats an _id: mongod refuses it with 11000.
    const body = bson.literal(.{ .insert = "script_write" });
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 10 }), bson.literal(.{ ._id = 0 }) };
    const theirs = try conn.exchange(.{
        .request_id = 0,
        .body = body,
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "documents", .documents = &docs },
    }, null);
    defer theirs.deinit();
    try testing.expectEqual(@as(i64, 11000), try (try theirs.raw().getPath("writeErrors.0.code")).?.asI64());
    try testing.expectEqual(@as(i64, 1), try (try theirs.raw().getPath("writeErrors.0.index")).?.asI64());
    var refusing: Script.Write = .{ .refuse = &.{.{ .index = 1 }} };
    const ours = try replyOf(refusing.handler(), io, a, request("insert", body, .{ .identifier = "documents", .bytes = try concat(a, &docs) }));
    try testing.expectEqual(@as(i64, 1), try (try ours.getPath("writeErrors.0.index")).?.asI64());
    try expectFieldsIn(ours, theirs.raw(), "");

    var plain: Script.Write = .{};
    const updates = [_]bson.RawDocument{
        bson.literal(.{ .q = .{ ._id = 10 }, .u = .{ .@"$set" = .{ .x = 1 } } }),
        bson.literal(.{ .q = .{ ._id = 0 }, .u = .{ .@"$set" = .{ .x = 1 } } }),
    };
    const update = bson.literal(.{ .update = "script_write" });
    const updated = try conn.exchange(.{
        .request_id = 0,
        .body = update,
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "updates", .documents = &updates },
    }, null);
    defer updated.deinit();
    try testing.expectEqual(@as(i64, 2), try (try updated.raw().get("nModified")).?.asI64());
    try expectFieldsIn(try replyOf(plain.handler(), io, a, request("update", update, .{ .identifier = "updates", .bytes = try concat(a, &updates) })), updated.raw(), "");

    const deletes = [_]bson.RawDocument{bson.literal(.{ .q = .{ ._id = 10 }, .limit = 1 })};
    const delete = bson.literal(.{ .delete = "script_write" });
    const deleted = try conn.exchange(.{
        .request_id = 0,
        .body = delete,
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "deletes", .documents = &deletes },
    }, null);
    defer deleted.deinit();
    try testing.expectEqual(@as(i64, 1), try (try deleted.raw().get("n")).?.asI64());
    try expectFieldsIn(try replyOf(plain.handler(), io, a, request("delete", delete, .{ .identifier = "deletes", .bytes = try concat(a, &deletes) })), deleted.raw(), "");
}

test "a failure of the script and the answers of FakeServer itself write only what mongod writes" {
    try e2e.onZio(ownAnswers);
}

fn ownAnswers(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();

    // The handshake, legacy hello with helloOk, as drivers of 2026 send it.
    var handshake = request("isMaster", bson.literal(.{ .isMaster = 1, .helloOk = true }), null);
    handshake.database = "admin";
    try expectFieldsIn(try FakeServer.helloReply(io, a, script.hello, &handshake), conn.hello_reply.?.raw(), "");

    // An unknown command: the failure the queue answers when it is empty.
    const unknown = bson.literal(.{ .zefirNoSuchCommand = 1 });
    const not_found = try conn.exchange(.{ .request_id = 0, .body = unknown, .database = e2e.database }, null);
    defer not_found.deinit();
    try testing.expectEqual(@as(i32, 59), mongo.ServerError.fromReply(not_found.raw()).code);
    try expectFieldsIn(try replyOf(queue.handler(), io, a, request("zefirNoSuchCommand", unknown, null)), not_found.raw(), "");

    // What the fake server answers itself, after the handshake.
    const nonce = "n,,n=zefir_nobody,r=fyko+d2lbbFgONRv9qkxdawL";
    const sasl = try bson.encode(a, .{
        .saslStart = 1,
        .mechanism = "SCRAM-SHA-256",
        .payload = bson.Binary{ .subtype = .generic, .bytes = nonce },
        .autoAuthorize = 1,
    }, .{});
    const commands = [_]struct { name: []const u8, body: bson.RawDocument }{
        .{ .name = "hello", .body = bson.literal(.{ .hello = 1 }) },
        .{ .name = "ping", .body = bson.literal(.{ .ping = 1 }) },
        .{ .name = "endSessions", .body = bson.literal(.{ .endSessions = [0]i32{} }) },
        .{ .name = "saslStart", .body = sasl.raw() },
    };
    for (commands) |command| {
        const theirs = try conn.exchange(.{ .request_id = 0, .body = command.body, .database = "admin" }, null);
        defer theirs.deinit();
        var r = request(command.name, command.body, null);
        r.database = "admin";
        const ours = (try FakeServer.ownAnswer(io, a, &script, &r)).?.reply;
        expectFieldsIn(ours, theirs.raw(), "") catch |err| {
            std.debug.print("in the reply to {s}\n", .{command.name});
            return err;
        };
    }

    // A command without $db, sent as it is.
    const theirs = try conn.forward(a, bson.literal(.{ .ping = 1 }), null);
    try testing.expectEqual(@as(i32, 40414), mongo.ServerError.fromReply(theirs.raw()).code);
    var no_database = request("ping", bson.literal(.{ .ping = 1 }), null);
    no_database.database = "";
    try expectFieldsIn((try FakeServer.ownAnswer(io, a, &script, &no_database)).?.reply, theirs.raw(), "");
}

test "a document of every BSON type of the vectors goes into mongod and comes back byte for byte" {
    try e2e.onZio(everyType);
}

/// `{_id: 1, v0: …, v1: …}`: the value of every valid vector, in its
/// order, under a key of its own, deprecated types and a timestamp other
/// than 0 among them (mongod replaces a timestamp of 0 near the front).
fn everyTypeDocument(arena: std.mem.Allocator) !bson.RawDocument {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(arena, &.{ 0, 0, 0, 0 });
    try bytes.appendSlice(arena, "\x10_id\x00\x01\x00\x00\x00");
    for (mongo.testing.vectors.valid, 0..) |vector, i| {
        // The element of the vector: its type, "a" and its 0, the value.
        const element = vector.bson[4 .. vector.bson.len - 1];
        try bytes.append(arena, element[0]);
        try bytes.print(arena, "v{d}\x00", .{i});
        try bytes.appendSlice(arena, element[3..]);
    }
    try bytes.append(arena, 0);
    std.mem.writeInt(i32, bytes.items[0..4], @intCast(bytes.items.len), .little);
    const doc: bson.RawDocument = try .init(bytes.items);
    try doc.validate();
    return doc;
}

fn everyType(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(conn, a, "script_types");
    defer drop(conn, a, "script_types") catch {};
    const doc = try everyTypeDocument(a);
    try insert(conn, a, "script_types", &.{doc});

    const find = bson.literal(.{ .find = "script_types", .filter = .{ ._id = 1 } });
    const found = try conn.command(e2e.database, find);
    defer found.deinit();
    const back = (try found.raw().getPath("cursor.firstBatch.0")) orelse return error.TestDocumentNotFound;
    if (!std.mem.eql(u8, doc.bytes, back.document.bytes)) {
        std.debug.print("sent {f}\ngot  {f}\n", .{ doc, back.document });
        return error.TestDocumentChanged;
    }
}
