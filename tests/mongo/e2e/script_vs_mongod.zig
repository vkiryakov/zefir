//! The replies of `mongo.testing.Script` and `FakeServer` against
//! mongo-plain: every field that a ready handler, or the fake server
//! itself, writes is in mongod's reply to the same command, with the same
//! BSON type, so that tests on a script see what the client sees from
//! mongod. The commands go to mongod through `mongo.Client.runCommand`,
//! the items of a write in its body. And a document of every BSON type of
//! zefir's vectors goes into mongod and comes back byte for byte.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;
const e2e = @import("root.zig");

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

/// A command as a handler gets it, in the database of the tests, without
/// a section of kind 1.
fn request(name: []const u8, body: bson.RawDocument) Script.Request {
    return .{ .connection = 1, .name = name, .database = e2e.database, .body = body, .sequence = null };
}

/// A write as a handler gets it: `body`, and `items` in a section of kind
/// 1 named `identifier`.
fn writeRequest(arena: std.mem.Allocator, name: []const u8, body: bson.RawDocument, identifier: []const u8, items: []const bson.RawDocument) !Script.Request {
    var r = request(name, body);
    r.sequence = .{ .identifier = identifier, .bytes = try concat(arena, items) };
    return r;
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

fn within(io: Io) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(30))));
}

/// A client of mongo-plain, connected.
fn connected(io: Io, client: *mongo.Client) !void {
    var buffer: [64]u8 = undefined;
    client.* = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port}) });
    errdefer client.deinit();
    try client.connect(io, within(io).ctx, null);
}

/// mongod's reply to `body` in `database`, ok 1 or not, from `arena`.
fn replyTo(io: Io, client: *mongo.Client, arena: std.mem.Allocator, database: []const u8, body: bson.RawDocument) !bson.RawDocument {
    var failure: ?bson.OwnedDocument = null;
    const reply = client.runCommand(io, .of(.root), .{ .database = database, .body = body }, .{ .allocator = arena, .failure_reply = &failure }) catch |err| switch (err) {
        error.CommandFailed => return failure.?.raw(),
        else => return err,
    };
    return reply.raw();
}

/// mongod's reply to the write `body` with `items` under `identifier`, in
/// its body, from `arena`.
fn writeReplyTo(io: Io, client: *mongo.Client, arena: std.mem.Allocator, body: bson.RawDocument, identifier: []const u8, items: []const bson.RawDocument) !bson.RawDocument {
    var b: bson.Builder = .init(arena);
    var it = body.iterator();
    while (try it.next()) |element| try b.putValue(element.key, element.value);
    try b.beginArray(identifier);
    for (items) |item| try b.putDocument("", item);
    try b.end();
    try b.putBoolean("ordered", true);
    return replyTo(io, client, arena, e2e.database, (try b.finish()).raw());
}

fn drop(io: Io, client: *mongo.Client, arena: std.mem.Allocator, collection: []const u8) !void {
    const command = try bson.encode(arena, .{ .drop = collection }, .{});
    const reply = try client.runCommand(io, within(io), .{ .database = e2e.database, .body = command.raw() }, .{ .allocator = testing.allocator });
    reply.deinit();
}

/// Inserts `docs` into `collection`, all of them.
fn insert(io: Io, client: *mongo.Client, arena: std.mem.Allocator, collection: []const u8, docs: []const bson.RawDocument) !void {
    const body = try bson.encode(arena, .{ .insert = collection }, .{});
    var result = try client.write(io, within(io), .{ .database = e2e.database, .kind = .insert, .body = body.raw(), .items = docs }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    if (result.write_errors.len > 0) {
        std.debug.print("mongod refused document {d}: {s}\n", .{ result.write_errors[0].index, result.write_errors[0].message });
        return error.TestInsertRefused;
    }
    try testing.expectEqual(@as(u64, docs.len), result.n);
}

test "Script.Cursor writes only what mongod writes in its replies to find, getMore and killCursors" {
    try e2e.onZio(cursorReplies);
}

fn cursorReplies(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(io, &client, a, "script_cursor");
    defer drop(io, &client, a, "script_cursor") catch {};
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 0, .n = "zero" }), bson.literal(.{ ._id = 1, .n = "one" }), bson.literal(.{ ._id = 2, .n = "two" }) };
    try insert(io, &client, a, "script_cursor", &docs);

    // find with a batch of one: mongod keeps the cursor for the rest.
    const find = bson.literal(.{ .find = "script_cursor", .filter = .{}, .sort = .{ ._id = 1 }, .batchSize = 1 });
    const found = try replyTo(io, &client, a, e2e.database, find);
    const id = try (try found.getPath("cursor.id")).?.asI64();
    try testing.expect(id != 0);
    var cursor: Script.Cursor = .{ .ns = e2e.database ++ ".script_cursor", .id = id, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } };
    const handler = cursor.handler();
    try expectFieldsIn(try replyOf(handler, io, a, request("find", find)), found, "");

    const more = try bson.encode(a, .{ .getMore = id, .collection = "script_cursor", .batchSize = 1 }, .{});
    const next = try replyTo(io, &client, a, e2e.database, more.raw());
    try expectFieldsIn(try replyOf(handler, io, a, request("getMore", more.raw())), next, "");
    try testing.expectEqualSlices(u8, docs[1].bytes, (try next.getPath("cursor.nextBatch.0")).?.document.bytes);

    const kill = try bson.encode(a, .{ .killCursors = "script_cursor", .cursors = .{id} }, .{});
    const killed = try replyTo(io, &client, a, e2e.database, kill.raw());
    try testing.expectEqual(id, try (try killed.getPath("cursorsKilled.0")).?.asI64());
    try expectFieldsIn(try replyOf(handler, io, a, request("killCursors", kill.raw())), killed, "");

    // The cursor is gone: getMore finds it no more.
    const gone = try replyTo(io, &client, a, e2e.database, more.raw());
    try testing.expectEqual(@as(i32, 43), mongo.ServerError.fromReply(gone).code);
    const ours = try replyOf(handler, io, a, request("getMore", more.raw()));
    try testing.expectEqual(@as(i32, 43), mongo.ServerError.fromReply(ours).code);
    try expectFieldsIn(ours, gone, "");
}

test "Script.Write writes only what mongod writes in its replies to insert, update and delete, writeErrors of a duplicate _id among them" {
    try e2e.onZio(writeReplies);
}

fn writeReplies(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(io, &client, a, "script_write");
    defer drop(io, &client, a, "script_write") catch {};
    try insert(io, &client, a, "script_write", &.{bson.literal(.{ ._id = 0 })});

    // The second document repeats an _id: mongod refuses it with 11000.
    const body = bson.literal(.{ .insert = "script_write" });
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 10 }), bson.literal(.{ ._id = 0 }) };
    const theirs = try writeReplyTo(io, &client, a, body, "documents", &docs);
    try testing.expectEqual(@as(i64, 11000), try (try theirs.getPath("writeErrors.0.code")).?.asI64());
    try testing.expectEqual(@as(i64, 1), try (try theirs.getPath("writeErrors.0.index")).?.asI64());
    var refusing: Script.Write = .{ .refuse = &.{.{ .index = 1 }} };
    const ours = try replyOf(refusing.handler(), io, a, try writeRequest(a, "insert", body, "documents", &docs));
    try testing.expectEqual(@as(i64, 1), try (try ours.getPath("writeErrors.0.index")).?.asI64());
    try expectFieldsIn(ours, theirs, "");

    var plain: Script.Write = .{};
    const updates = [_]bson.RawDocument{
        bson.literal(.{ .q = .{ ._id = 10 }, .u = .{ .@"$set" = .{ .x = 1 } } }),
        bson.literal(.{ .q = .{ ._id = 0 }, .u = .{ .@"$set" = .{ .x = 1 } } }),
    };
    const update = bson.literal(.{ .update = "script_write" });
    const updated = try writeReplyTo(io, &client, a, update, "updates", &updates);
    try testing.expectEqual(@as(i64, 2), try (try updated.get("nModified")).?.asI64());
    try expectFieldsIn(try replyOf(plain.handler(), io, a, try writeRequest(a, "update", update, "updates", &updates)), updated, "");

    const deletes = [_]bson.RawDocument{bson.literal(.{ .q = .{ ._id = 10 }, .limit = 1 })};
    const delete = bson.literal(.{ .delete = "script_write" });
    const deleted = try writeReplyTo(io, &client, a, delete, "deletes", &deletes);
    try testing.expectEqual(@as(i64, 1), try (try deleted.get("n")).?.asI64());
    try expectFieldsIn(try replyOf(plain.handler(), io, a, try writeRequest(a, "delete", delete, "deletes", &deletes)), deleted, "");
}

test "a failure of the script and the answers of FakeServer itself write only what mongod writes" {
    try e2e.onZio(ownAnswers);
}

fn ownAnswers(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();

    // The handshake, legacy hello with helloOk, as the client of 2026
    // sends it; mongod answers it alike after the handshake.
    const is_master = bson.literal(.{ .isMaster = 1, .helloOk = true });
    var handshake = request("isMaster", is_master);
    handshake.database = "admin";
    try expectFieldsIn(try FakeServer.helloReply(io, a, script.hello, &handshake), try replyTo(io, &client, a, "admin", is_master), "");

    // An unknown command: the failure the queue answers when it is empty.
    const unknown = bson.literal(.{ .zefirNoSuchCommand = 1 });
    const not_found = try replyTo(io, &client, a, e2e.database, unknown);
    try testing.expectEqual(@as(i32, 59), mongo.ServerError.fromReply(not_found).code);
    try expectFieldsIn(try replyOf(queue.handler(), io, a, request("zefirNoSuchCommand", unknown)), not_found, "");

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
        const theirs = try replyTo(io, &client, a, "admin", command.body);
        var r = request(command.name, command.body);
        r.database = "admin";
        const ours = (try FakeServer.ownAnswer(io, a, &script, &r)).?.reply;
        expectFieldsIn(ours, theirs, "") catch |err| {
            std.debug.print("in the reply to {s}\n", .{command.name});
            return err;
        };
    }
    // A command without $db fails in FakeServer with Script.failure, as the
    // unknown command above does: the client never sends one.
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
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(io, &client, a, "script_types");
    defer drop(io, &client, a, "script_types") catch {};
    const doc = try everyTypeDocument(a);
    try insert(io, &client, a, "script_types", &.{doc});

    const find = bson.literal(.{ .find = "script_types", .filter = .{ ._id = 1 } });
    var cursor = try client.openCursor(io, within(io), .{ .database = e2e.database, .body = find }, .{});
    defer cursor.deinit(io);
    const back = (try cursor.next(io, within(io))) orelse return error.TestDocumentNotFound;
    if (!std.mem.eql(u8, doc.bytes, back.bytes)) {
        std.debug.print("sent {f}\ngot  {f}\n", .{ doc, back });
        return error.TestDocumentChanged;
    }
}
