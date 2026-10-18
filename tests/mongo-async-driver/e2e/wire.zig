//! The wire tools of zefir-mongo against mongo-plain, before any driver:
//! hand-built OP_MSG requests through `mongo.wire.opmsg`, replies read by
//! it and by `mongo.wire.Hello`, and inserts split by `mongo.wire.batch`
//! at the limits mongod gives in its hello, read back with find.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const e2e = @import("root.zig");
const RawConn = e2e.RawConn;

test "isMaster and ping through hand-built OP_MSG" {
    try e2e.onZio(helloAndPing);
}

fn helloAndPing(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    const hello = try conn.handshake();
    try testing.expectEqual(wire.Hello.ServerType.standalone, hello.server_type);
    try testing.expect(hello.max_wire_version >= 21);
    try testing.expectEqual(@as(u32, 16 * 1024 * 1024), hello.max_bson_object_size);
    try testing.expectEqual(@as(u32, 48_000_000), hello.max_message_size_bytes);
    try testing.expectEqual(@as(u32, 100_000), hello.max_write_batch_size);
    try testing.expect(hello.connection_id != null);
    try testing.expect(hello.set_name == null);

    const pong = try conn.command("admin", bson.literal(.{ .ping = 1 }));
    defer pong.deinit();
    try testing.expectEqual(@as(f64, 1), try (try pong.raw().get("ok")).?.asF64());
}

test "an unknown command gives ok 0 with code 59, CommandNotFound" {
    try e2e.onZio(unknownCommand);
}

fn unknownCommand(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    const reply = try conn.exchange(.{ .request_id = 0, .body = bson.literal(.{ .zefirNoSuchCommand = 1 }), .database = "admin" }, null);
    defer reply.deinit();

    const server = mongo.ServerError.fromReply(reply.raw());
    try testing.expectEqual(@as(i32, 59), server.code);
    try testing.expectEqualStrings("CommandNotFound", server.code_name.slice());
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, wire.checkReply(reply.raw(), testing.allocator, &d, &failure));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, reply.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 59), d.server.?.code);
    try testing.expect(std.mem.find(u8, d.message(), "zefirNoSuchCommand") != null);
}

test "100 001 documents go in two batches at maxWriteBatchSize, and find gives them back" {
    try e2e.onZio(insertByCount);
}

fn insertByCount(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    const hello = try conn.handshake();
    const count = hello.max_write_batch_size + 1;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try arena.allocator().alloc(bson.RawDocument, count);
    for (items, 0..) |*item, i| {
        const n: i32 = @intCast(i);
        item.* = (try bson.encode(arena.allocator(), .{ ._id = n, .n = n }, .{})).raw();
    }
    try drop(conn, "wire_count");
    defer drop(conn, "wire_count") catch {};
    const batches = try insertAll(conn, "wire_count", items);
    defer testing.allocator.free(batches);
    try testing.expectEqualSlices(usize, &.{ hello.max_write_batch_size, 1 }, batches);
    try expectDocuments(conn, "wire_count", items);
}

test "a message of exactly maxMessageSizeBytes is taken, and the next item goes in a batch of its own" {
    try e2e.onZio(insertBySize);
}

fn insertBySize(io: Io) !void {
    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    const hello = try conn.handshake();

    // Three documents {_id, data} that fill the message of their batch to
    // the byte, each under maxBsonObjectSize, and a small fourth one.
    const body = bson.literal(.{ .insert = "wire_size" });
    const empty = insertRequest(body, &.{});
    const room = hello.max_message_size_bytes - empty.length();
    const sizes = [_]usize{ room / 3 + room % 3, room / 3, room / 3, 40 };
    // _id (int32) and data (a string) take 25 bytes besides the string.
    const filler = try testing.allocator.alloc(u8, sizes[0] - 25);
    defer testing.allocator.free(filler);
    @memset(filler, 'z');
    var docs: [sizes.len]bson.OwnedDocument = undefined;
    var built: usize = 0;
    defer for (docs[0..built]) |doc| doc.deinit();
    var items: [sizes.len]bson.RawDocument = undefined;
    for (sizes, 0..) |size, i| {
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        try b.putInt32("_id", @intCast(i));
        try b.putString("data", filler[0 .. size - 25]);
        docs[i] = try b.finish();
        built += 1;
        items[i] = docs[i].raw();
        try testing.expectEqual(size, items[i].bytes.len);
        try testing.expect(size <= hello.max_bson_object_size);
    }
    try testing.expectEqual(@as(usize, hello.max_message_size_bytes), insertRequest(body, items[0..3]).length());

    try drop(conn, "wire_size");
    defer drop(conn, "wire_size") catch {};
    const batches = try insertAll(conn, "wire_size", &items);
    defer testing.allocator.free(batches);
    try testing.expectEqualSlices(usize, &.{ 3, 1 }, batches);
    try expectDocuments(conn, "wire_size", &items);
}

fn insertRequest(body: bson.RawDocument, items: []const bson.RawDocument) wire.opmsg.Request {
    return .{
        .request_id = 0,
        .body = body,
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "documents", .documents = items },
    };
}

/// Inserts `items` in the batches that `wire.batch` makes at the server's
/// limits, checks that the server took every item of each, and returns
/// how many items each batch carried; free it with `testing.allocator`.
fn insertAll(conn: *RawConn, collection: []const u8, items: []const bson.RawDocument) ![]usize {
    const body = try bson.encode(testing.allocator, .{ .insert = collection }, .{});
    defer body.deinit();
    var request = insertRequest(body.raw(), items);
    var batches = try wire.batch.Batches.init(request, .of(conn.hello), null);
    var counts: std.ArrayList(usize) = .empty;
    errdefer counts.deinit(testing.allocator);
    while (batches.next()) |batch| {
        request.sequence.?.documents = batch.items;
        try testing.expect(request.length() <= conn.hello.max_message_size_bytes);
        const reply = try conn.exchange(request, null);
        defer reply.deinit();
        try wire.checkReply(reply.raw(), testing.allocator, null, null);
        try testing.expect((try reply.raw().get("writeErrors")) == null);
        try testing.expectEqual(@as(i64, @intCast(batch.items.len)), try (try reply.raw().get("n")).?.asI64());
        try counts.append(testing.allocator, batch.items.len);
    }
    return counts.toOwnedSlice(testing.allocator);
}

/// Reads `collection` by `_id` with find and getMore, and checks that it
/// holds `expected`, byte for byte, in that order.
fn expectDocuments(conn: *RawConn, collection: []const u8, expected: []const bson.RawDocument) !void {
    const find = try bson.encode(testing.allocator, .{ .find = collection, .filter = .{}, .sort = .{ ._id = 1 } }, .{});
    defer find.deinit();
    var reply = try conn.command(e2e.database, find.raw());
    defer reply.deinit();
    var batch_key: []const u8 = "firstBatch";
    var seen: usize = 0;
    while (true) {
        const cursor = (try reply.raw().get("cursor")).?.document;
        var docs = (try cursor.get(batch_key)).?.array.iterator();
        while (try docs.next()) |element| : (seen += 1) {
            try testing.expect(seen < expected.len);
            try testing.expectEqualSlices(u8, expected[seen].bytes, element.value.document.bytes);
        }
        const id = try (try cursor.get("id")).?.asI64();
        if (id == 0) break;
        const more = try bson.encode(testing.allocator, .{ .getMore = id, .collection = collection }, .{});
        defer more.deinit();
        const next = try conn.command(e2e.database, more.raw());
        reply.deinit();
        reply = next;
        batch_key = "nextBatch";
    }
    try testing.expectEqual(expected.len, seen);
}

fn drop(conn: *RawConn, collection: []const u8) !void {
    const command = try bson.encode(testing.allocator, .{ .drop = collection }, .{});
    defer command.deinit();
    const reply = try conn.command(e2e.database, command.raw());
    reply.deinit();
}
