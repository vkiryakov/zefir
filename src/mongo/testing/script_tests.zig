//! Tests of `mongo.testing.Script`: its ready handlers, its journal and its
//! connections.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("../bson.zig");
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const Script = @import("Script.zig");

/// A request as a handler gets it, without the round trip through OP_MSG.
fn request(name: []const u8, body: bson.RawDocument, sequence: ?opmsg.Section) Script.Request {
    return .{ .connection = 1, .name = name, .database = "app", .body = body, .sequence = sequence };
}

/// The documents of a section of kind 1, one after another, in `arena`.
fn concat(arena: std.mem.Allocator, docs: []const bson.RawDocument) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    for (docs) |doc| try bytes.appendSlice(arena, doc.bytes);
    return bytes.items;
}

fn answerOf(handler: Script.Handler, arena: std.mem.Allocator, r: Script.Request) !Script.Answer {
    return handler.function(handler.context, testing.io, arena, &r);
}

/// The reply of `answer`, which must be one.
fn replyOf(answer: Script.Answer) !bson.RawDocument {
    return switch (answer) {
        .reply => |doc| doc,
        else => error.TestNotAReply,
    };
}

fn int(doc: bson.RawDocument, path: []const u8) !i64 {
    return (try doc.getPath(path) orelse return error.TestMissingField).asI64();
}

fn text(doc: bson.RawDocument, path: []const u8) ![]const u8 {
    const value = try doc.getPath(path) orelse return error.TestMissingField;
    return if (value == .string) value.string else error.TestNotAString;
}

/// The documents of the array at `path`.
fn documents(arena: std.mem.Allocator, doc: bson.RawDocument, path: []const u8) ![]const bson.RawDocument {
    const value = try doc.getPath(path) orelse return error.TestMissingField;
    var out: std.ArrayList(bson.RawDocument) = .empty;
    var it = value.array.iterator();
    while (try it.next()) |element| try out.append(arena, element.value.document);
    return out.items;
}

test "a queue answers in its order, and past its end with a failure that names the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const first = bson.literal(.{ .n = 1, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = first }, .close_connection, .{ .delayed = .{ .after = .fromMilliseconds(5), .reply = first } } } };
    const handler = queue.handler();
    try testing.expectEqual(@as(usize, 3), queue.left());
    try testing.expectEqualSlices(u8, first.bytes, (try replyOf(try answerOf(handler, arena.allocator(), request("count", first, null)))).bytes);
    try testing.expectEqual(Script.Answer.close_connection, try answerOf(handler, arena.allocator(), request("count", first, null)));
    const delayed = try answerOf(handler, arena.allocator(), request("count", first, null));
    try testing.expectEqual(@as(i96, 5 * std.time.ns_per_ms), delayed.delayed.after.nanoseconds);
    try testing.expectEqual(@as(usize, 0), queue.left());

    const past = try replyOf(try answerOf(handler, arena.allocator(), request("drop", first, null)));
    try testing.expectEqual(@as(i64, 0), try int(past, "ok"));
    try testing.expectEqual(@as(i64, 59), try int(past, "code"));
    try testing.expectEqualStrings("CommandNotFound", try text(past, "codeName"));
    try testing.expect(std.mem.find(u8, try text(past, "errmsg"), "'drop'") != null);
}

test "a cursor answers its command with the first batch, getMore with the next ones, and the last with id 0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }), bson.literal(.{ .n = 2 }) };
    var cursor: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 77, .batches = &.{ docs[0..2], docs[2..3], &.{} } };
    const handler = cursor.handler();

    const opened = try replyOf(try answerOf(handler, a, request("find", bson.literal(.{ .find = "fs.chunks" }), null)));
    try testing.expectEqual(@as(i64, 77), try int(opened, "cursor.id"));
    try testing.expectEqualStrings("app.fs.chunks", try text(opened, "cursor.ns"));
    try testing.expectEqual(@as(i64, 1), try int(opened, "ok"));
    const first = try documents(a, opened, "cursor.firstBatch");
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualSlices(u8, docs[1].bytes, first[1].bytes);

    const more = bson.literal(.{ .getMore = @as(i64, 77), .collection = "fs.chunks" });
    const second = try replyOf(try answerOf(handler, a, request("getMore", more, null)));
    try testing.expectEqual(@as(i64, 77), try int(second, "cursor.id"));
    try testing.expectEqualSlices(u8, docs[2].bytes, (try documents(a, second, "cursor.nextBatch"))[0].bytes);
    const last = try replyOf(try answerOf(handler, a, request("getMore", more, null)));
    try testing.expectEqual(@as(i64, 0), try int(last, "cursor.id"));
    try testing.expectEqual(@as(usize, 0), (try documents(a, last, "cursor.nextBatch")).len);
    try testing.expectEqual(@as(u32, 2), cursor.get_mores);

    // The cursor is gone on the server: getMore finds it no more.
    const gone = try replyOf(try answerOf(handler, a, request("getMore", more, null)));
    try testing.expectEqual(@as(i64, 43), try int(gone, "code"));
    try testing.expectEqualStrings("CursorNotFound", try text(gone, "codeName"));
}

test "a cursor of one batch has id 0 at once, and a cursor without batches has an empty first batch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_]bson.RawDocument{bson.literal(.{ .n = 0 })};
    var one: Script.Cursor = .{ .ns = "app.users", .batches = &.{&docs} };
    const reply = try replyOf(try answerOf(one.handler(), a, request("find", bson.literal(.{ .find = "users" }), null)));
    try testing.expectEqual(@as(i64, 0), try int(reply, "cursor.id"));
    try testing.expectEqual(@as(usize, 1), (try documents(a, reply, "cursor.firstBatch")).len);

    var none: Script.Cursor = .{ .ns = "app.users", .batches = &.{} };
    const empty = try replyOf(try answerOf(none.handler(), a, request("aggregate", bson.literal(.{ .aggregate = "users" }), null)));
    try testing.expectEqual(@as(i64, 0), try int(empty, "cursor.id"));
    try testing.expectEqual(@as(usize, 0), (try documents(a, empty, "cursor.firstBatch")).len);
}

test "a cursor refuses getMore with another id, or in another namespace, and its command opens it afresh" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }) };
    var cursor: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 5, .batches = &.{ docs[0..1], docs[1..2] } };
    const handler = cursor.handler();
    _ = try answerOf(handler, a, request("find", bson.literal(.{ .find = "fs.chunks" }), null));

    const other_id = try replyOf(try answerOf(handler, a, request("getMore", bson.literal(.{ .getMore = @as(i64, 6), .collection = "fs.chunks" }), null)));
    try testing.expectEqual(@as(i64, 43), try int(other_id, "code"));
    const other_collection = try replyOf(try answerOf(handler, a, request("getMore", bson.literal(.{ .getMore = @as(i64, 5), .collection = "fs" }), null)));
    try testing.expectEqual(@as(i64, 13), try int(other_collection, "code"));
    try testing.expectEqualStrings("Unauthorized", try text(other_collection, "codeName"));
    var elsewhere = request("getMore", bson.literal(.{ .getMore = @as(i64, 5), .collection = "fs.chunks" }), null);
    elsewhere.database = "other";
    try testing.expectEqual(@as(i64, 13), try int(try replyOf(try answerOf(handler, a, elsewhere)), "code"));

    const right = bson.literal(.{ .getMore = @as(i64, 5), .collection = "fs.chunks" });
    try testing.expectEqual(@as(i64, 0), try int(try replyOf(try answerOf(handler, a, request("getMore", right, null))), "cursor.id"));
    // The command again: the same batches from the start.
    const again = try replyOf(try answerOf(handler, a, request("find", bson.literal(.{ .find = "fs.chunks" }), null)));
    try testing.expectEqual(@as(i64, 5), try int(again, "cursor.id"));
    try testing.expectEqualSlices(u8, docs[0].bytes, (try documents(a, again, "cursor.firstBatch"))[0].bytes);
}

test "killCursors kills an open cursor once; after that, and for other ids, it reports them not found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }) };
    var cursor: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 9, .batches = &.{ docs[0..1], docs[1..2] } };
    const handler = cursor.handler();
    _ = try answerOf(handler, a, request("find", bson.literal(.{ .find = "fs.chunks" }), null));

    const kill = bson.literal(.{ .killCursors = "fs.chunks", .cursors = .{@as(i64, 9)} });
    const killed = try replyOf(try answerOf(handler, a, request("killCursors", kill, null)));
    try testing.expectEqual(@as(i64, 9), try int(killed, "cursorsKilled.0"));
    try testing.expectEqual(@as(usize, 0), (try documents(a, killed, "cursorsNotFound")).len);
    try testing.expectEqual(@as(i64, 1), try int(killed, "ok"));
    try testing.expectEqual(@as(u32, 1), cursor.kills);

    const again = try replyOf(try answerOf(handler, a, request("killCursors", kill, null)));
    try testing.expectEqual(@as(i64, 9), try int(again, "cursorsNotFound.0"));
    try testing.expect(try again.getPath("cursorsKilled.0") == null);
    try testing.expectEqual(@as(u32, 2), cursor.kills);
    const gone = try replyOf(try answerOf(handler, a, request("getMore", bson.literal(.{ .getMore = @as(i64, 9), .collection = "fs.chunks" }), null)));
    try testing.expectEqual(@as(i64, 43), try int(gone, "code"));

    const others = try replyOf(try answerOf(handler, a, request("killCursors", bson.literal(.{ .killCursors = "fs.chunks", .cursors = .{ @as(i64, 1), @as(i64, 2) } }), null)));
    try testing.expectEqual(@as(i64, 2), try int(others, "cursorsNotFound.1"));
    try testing.expectEqual(@as(u32, 2), cursor.kills);
}

test "a write answers n and the refusals that fall in each batch, by their index in the batch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = bson.literal(.{ .n = 1 });
    const three = try concat(a, &.{ doc, doc, doc });
    var write: Script.Write = .{ .refuse = &.{ .{ .index = 1 }, .{ .index = 4, .code = 121, .errmsg = "Document failed validation" }, .{ .index = 5 } } };
    const handler = write.handler();
    const unordered = bson.literal(.{ .insert = "users", .ordered = false });

    const first = try replyOf(try answerOf(handler, a, request("insert", unordered, .{ .identifier = "documents", .bytes = three })));
    try testing.expectEqual(@as(i64, 2), try int(first, "n"));
    try testing.expectEqual(@as(i64, 1), try int(first, "writeErrors.0.index"));
    try testing.expectEqual(@as(i64, 11000), try int(first, "writeErrors.0.code"));
    try testing.expect(try first.get("nModified") == null);
    const second = try replyOf(try answerOf(handler, a, request("insert", unordered, .{ .identifier = "documents", .bytes = three })));
    try testing.expectEqual(@as(i64, 1), try int(second, "n"));
    try testing.expectEqual(@as(i64, 1), try int(second, "writeErrors.0.index"));
    try testing.expectEqual(@as(i64, 121), try int(second, "writeErrors.0.code"));
    try testing.expectEqualStrings("Document failed validation", try text(second, "writeErrors.0.errmsg"));
    try testing.expectEqual(@as(i64, 2), try int(second, "writeErrors.1.index"));
    const third = try replyOf(try answerOf(handler, a, request("insert", unordered, .{ .identifier = "documents", .bytes = three })));
    try testing.expectEqual(@as(i64, 3), try int(third, "n"));
    try testing.expect(try third.get("writeErrors") == null);
    try testing.expectEqual(@as(i64, 1), try int(third, "ok"));
}

test "an ordered write stops at its first refusal; an update counts nModified; items in the body count too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = bson.literal(.{ .q = .{}, .u = .{ .@"$set" = .{ .x = 1 } } });
    var ordered: Script.Write = .{ .refuse = &.{ .{ .index = 1 }, .{ .index = 2 } } };
    const reply = try replyOf(try answerOf(ordered.handler(), a, request("update", bson.literal(.{ .update = "users" }), .{ .identifier = "updates", .bytes = try concat(a, &.{ doc, doc, doc }) })));
    try testing.expectEqual(@as(i64, 1), try int(reply, "n"));
    try testing.expectEqual(@as(i64, 1), try int(reply, "nModified"));
    try testing.expectEqual(@as(usize, 1), (try documents(a, reply, "writeErrors")).len);
    try testing.expectEqual(@as(i64, 1), try int(reply, "writeErrors.0.index"));

    var plain: Script.Write = .{};
    const in_body = try replyOf(try answerOf(plain.handler(), a, request("delete", bson.literal(.{ .delete = "users", .deletes = .{ .{ .q = .{}, .limit = 0 }, .{ .q = .{}, .limit = 1 } } }), null)));
    try testing.expectEqual(@as(i64, 2), try int(in_body, "n"));

    const not_a_write = try replyOf(try answerOf(plain.handler(), a, request("find", bson.literal(.{ .find = "users" }), null)));
    try testing.expectEqual(@as(i64, 59), try int(not_a_write, "code"));
}

test "failure and cursorReply write what mongod writes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const failed = try Script.failure(a, .{ .code = 462, .code_name = "IngressRequestRateLimitExceeded", .errmsg = "too many requests", .labels = &.{ "SystemOverloadedError", "RetryableError" } });
    try testing.expectEqualSlices(u8, bson.literal(.{
        .ok = 0.0,
        .errmsg = "too many requests",
        .code = 462,
        .codeName = "IngressRequestRateLimitExceeded",
        .errorLabels = .{ "SystemOverloadedError", "RetryableError" },
    }).bytes, failed.bytes);
    const plain = try Script.failure(a, .{ .code = 59, .code_name = "CommandNotFound", .errmsg = "no such command: 'nope'" });
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 0.0, .errmsg = "no such command: 'nope'", .code = 59, .codeName = "CommandNotFound" }).bytes, plain.bytes);

    const docs = [_]bson.RawDocument{bson.literal(.{ .n = 1 })};
    const reply = try Script.cursorReply(a, "app.users", 3, .next, &docs);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .cursor = .{ .nextBatch = .{.{ .n = 1 }}, .id = @as(i64, 3), .ns = "app.users" },
        .ok = 1.0,
    }).bytes, reply.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 1.0 }).bytes, Script.ok.bytes);
}

test "the journal keeps copies of what came, with the connection, the database and the section of kind 1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    const io = testing.io;

    // A request read back from OP_MSG, as the servers and the fake driver get one.
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 1 }), bson.literal(.{ ._id = 2 }) };
    var out: Io.Writer.Allocating = .init(a);
    try opmsg.writeRequest(&out.writer, .{
        .request_id = 7,
        .body = bson.literal(.{ .insert = "users" }),
        .database = "app",
        .ordered = true,
        .sequence = .{ .identifier = "documents", .documents = &docs },
    });
    var reader: Io.Reader = .fixed(try a.dupe(u8, out.written()));
    const incoming = try opmsg.readRequest(&reader, testing.allocator, opmsg.default_max_message_size, null);
    const first = Script.Request.of(2, &incoming);
    try testing.expectEqualStrings("insert", first.name);
    try testing.expectEqualStrings("app", first.database);
    try testing.expectEqualStrings("documents", first.sequence.?.identifier);
    try script.record(io, &first);
    const body = try a.dupe(u8, incoming.body.bytes);
    // The journal does not point into the request.
    incoming.deinit();

    try script.record(io, &request("ping", bson.literal(.{ .ping = 1 }), null));
    try testing.expectEqual(@as(usize, 2), script.received(io));
    const entry = script.entry(io, 0);
    try testing.expectEqual(@as(u32, 2), entry.connection);
    try testing.expectEqualStrings("insert", entry.name);
    try testing.expectEqualStrings("app", entry.database);
    try testing.expectEqualSlices(u8, body, entry.body.bytes);
    try testing.expectEqualStrings("documents", entry.sequence.?.identifier);
    var stored = entry.sequence.?.documents();
    try testing.expectEqualSlices(u8, docs[0].bytes, stored.next().?.bytes);
    try testing.expectEqualSlices(u8, docs[1].bytes, stored.next().?.bytes);
    try testing.expect(stored.next() == null);
    try testing.expectEqualStrings("ping", script.entry(io, 1).name);
    try testing.expect(script.entry(io, 1).sequence == null);
    try testing.expectEqual(@as(usize, 1), script.count(io, "ping"));
    try testing.expectEqual(@as(usize, 0), script.count(io, "find"));
}

test "answer hands the request to the handler, with io and an arena" {
    const Echo = struct {
        seen: u32 = 0,

        pub fn answer(self: *@This(), io: Io, arena: std.mem.Allocator, r: *const Script.Request) Script.HandlerError!Script.Answer {
            _ = io;
            self.seen += 1;
            return .{ .reply = (try r.body.dupe(arena)).raw() };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var echo: Echo = .{};
    var script: Script = .init(testing.allocator, .init(&echo));
    defer script.deinit();
    const body = bson.literal(.{ .zefirEcho = 1 });
    const reply = try replyOf(try script.answer(testing.io, arena.allocator(), &request("zefirEcho", body, null)));
    try testing.expectEqualSlices(u8, body.bytes, reply.bytes);
    try testing.expectEqual(@as(u32, 1), echo.seen);
    // answer does not record: servers and drivers record what they read.
    try testing.expectEqual(@as(usize, 0), script.received(testing.io));
}

test "connections are numbered from 1, and none opens while the script refuses them" {
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    try testing.expectEqual(@as(?u32, 1), script.openConnection());
    try testing.expectEqual(@as(?u32, 2), script.openConnection());
    script.refuseConnections();
    try testing.expect(script.isRefusing());
    try testing.expectEqual(@as(?u32, null), script.openConnection());
    script.acceptConnections();
    try testing.expectEqual(@as(?u32, 3), script.openConnection());
}
