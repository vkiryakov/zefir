//! What mongod says of itself in hello, and the limits the client splits
//! writes by, against mongo-plain: the client connects to a standalone
//! mongod of wire version 21 or later with the default limits; an insert
//! of one item more than `maxWriteBatchSize` goes in two batches, and one
//! whose first three items fill `maxMessageSizeBytes` to the byte goes in
//! a batch of three and a batch of one; find gives every item back. The
//! batches are counted by mongod, in `metrics.commands.insert` of
//! serverStatus.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// A client of mongo-plain, connected.
fn connected(io: Io, client: *mongo.Client) !void {
    var buffer: [64]u8 = undefined;
    client.* = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port}) });
    errdefer client.deinit();
    var d: mongo.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

fn int(doc: bson.RawDocument, path: []const u8) !i64 {
    return (try doc.getPath(path) orelse return error.TestMissingField).asI64();
}

test "the client connects to mongo-plain, a standalone mongod of wire version 21 or later with the default limits, and pings it" {
    try e2e.onZio(helloAndPing);
}

fn helloAndPing(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    // connect refused all but a standalone mongod of wire version 21 or
    // later; its hello says so again.
    const hello = try client.runCommand(io, within(io, .fromSeconds(10)), .{ .database = "admin", .body = bson.literal(.{ .isMaster = 1, .helloOk = true }) }, .{ .allocator = testing.allocator });
    defer hello.deinit();
    const reply = hello.raw();
    try testing.expect(try int(reply, "maxWireVersion") >= 21);
    try testing.expectEqual(@as(i64, 16 * 1024 * 1024), try int(reply, "maxBsonObjectSize"));
    try testing.expectEqual(@as(i64, 48_000_000), try int(reply, "maxMessageSizeBytes"));
    try testing.expectEqual(@as(i64, 100_000), try int(reply, "maxWriteBatchSize"));
    try testing.expect(try reply.get("connectionId") != null);
    try testing.expect(try reply.get("setName") == null);
    try testing.expect(try reply.get("isreplicaset") == null);
    try testing.expect(try reply.get("msg") == null);

    const pong = try client.runCommand(io, within(io, .fromSeconds(10)), .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) }, .{ .allocator = testing.allocator });
    defer pong.deinit();
    try testing.expectEqual(@as(f64, 1), try (try pong.raw().get("ok")).?.asF64());
}

test "an unknown command is CommandFailed with code 59, CommandNotFound, and its reply in failure_reply" {
    try e2e.onZio(unknownCommand);
}

fn unknownCommand(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, client.runCommand(io, within(io, .fromSeconds(10)), .{ .database = "admin", .body = bson.literal(.{ .zefirNoSuchCommand = 1 }) }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    defer failure.?.deinit();
    try testing.expectEqual(@as(i32, 59), d.server.?.code);
    try testing.expectEqualStrings("CommandNotFound", d.server.?.code_name.slice());
    try testing.expect(std.mem.find(u8, d.message(), "zefirNoSuchCommand") != null);
    try testing.expectEqual(@as(i64, 59), try int(failure.?.raw(), "code"));
    try testing.expectEqual(@as(i64, 0), try int(failure.?.raw(), "ok"));
}

test "100 001 documents go in two batches at maxWriteBatchSize, and find gives them back" {
    try e2e.onZio(insertByCount);
}

fn insertByCount(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();
    const count = 100_000 + 1;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try arena.allocator().alloc(bson.RawDocument, count);
    for (items, 0..) |*item, i| {
        const n: i32 = @intCast(i);
        item.* = (try bson.encode(arena.allocator(), .{ ._id = n, .n = n }, .{})).raw();
    }
    try drop(io, &client, "limits_count");
    defer drop(io, &client, "limits_count") catch {};
    try testing.expectEqual(@as(i64, 2), try insertAll(io, &client, "limits_count", items));
    try expectDocuments(io, &client, "limits_count", items);
}

test "a message of exactly maxMessageSizeBytes is taken, and the next item goes in a batch of its own" {
    try e2e.onZio(insertBySize);
}

/// The length of the OP_MSG of an insert into `collection` of
/// `e2e.database` without its items, as the client writes it without a
/// deadline: the header, the flags, the body with `ordered` and `$db`,
/// and the head of its section of kind 1, `documents`.
fn insertOverhead(collection: []const u8) !usize {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putString("insert", collection);
    try b.putBoolean("ordered", true);
    try b.putString("$db", e2e.database);
    const body = try b.finish();
    defer body.deinit();
    return 16 + 4 + 1 + body.bytes.len + 1 + 4 + "documents".len + 1;
}

fn insertBySize(io: Io) !void {
    var client: mongo.Client = undefined;
    try connected(io, &client);
    defer client.deinit();

    // Three documents {_id, data} that fill the message of their batch to
    // the byte, each under maxBsonObjectSize, and a small fourth one.
    const max_message_size = 48_000_000;
    const room = max_message_size - try insertOverhead("limits_size");
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
        try testing.expect(size <= 16 * 1024 * 1024);
    }

    try drop(io, &client, "limits_size");
    defer drop(io, &client, "limits_size") catch {};
    try testing.expectEqual(@as(i64, 2), try insertAll(io, &client, "limits_size", &items));
    try expectDocuments(io, &client, "limits_size", &items);
}

/// The insert commands mongod has run since it started.
fn inserts(io: Io, client: *mongo.Client) !i64 {
    const status = try client.runCommand(io, within(io, .fromSeconds(10)), .{ .database = "admin", .body = bson.literal(.{ .serverStatus = 1 }) }, .{ .allocator = testing.allocator });
    defer status.deinit();
    return int(status.raw(), "metrics.commands.insert.total");
}

/// Inserts `items` into `collection` with one write, checks that mongod
/// took every item, and returns how many insert commands it ran for them:
/// the batches of the write.
fn insertAll(io: Io, client: *mongo.Client, collection: []const u8, items: []const bson.RawDocument) !i64 {
    const body = try bson.encode(testing.allocator, .{ .insert = collection }, .{});
    defer body.deinit();
    const before = try inserts(io, client);
    var d: mongo.Diagnostics = .{};
    var result = client.write(io, .of(.root), .{ .database = e2e.database, .kind = .insert, .body = body.raw(), .items = items }, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
        std.debug.print("insert into {s}: {t}: {s}\n", .{ collection, err, d.message() });
        return err;
    };
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.write_errors.len);
    try testing.expectEqual(@as(u64, items.len), result.n);
    try testing.expectEqual(items.len, result.answered);
    return try inserts(io, client) - before;
}

/// Reads `collection` by `_id` with a cursor, and checks that it holds
/// `expected`, byte for byte, in that order.
fn expectDocuments(io: Io, client: *mongo.Client, collection: []const u8, expected: []const bson.RawDocument) !void {
    const find = try bson.encode(testing.allocator, .{ .find = collection, .filter = .{}, .sort = .{ ._id = 1 } }, .{});
    defer find.deinit();
    var cursor = try client.openCursor(io, within(io, .fromSeconds(60)), .{ .database = e2e.database, .body = find.raw() }, .{});
    defer cursor.deinit(io);
    var seen: usize = 0;
    while (try cursor.next(io, within(io, .fromSeconds(60)))) |doc| : (seen += 1) {
        try testing.expect(seen < expected.len);
        try testing.expectEqualSlices(u8, expected[seen].bytes, doc.bytes);
    }
    try testing.expectEqual(expected.len, seen);
}

fn drop(io: Io, client: *mongo.Client, collection: []const u8) !void {
    const command = try bson.encode(testing.allocator, .{ .drop = collection }, .{});
    defer command.deinit();
    const reply = try client.runCommand(io, within(io, .fromSeconds(10)), .{ .database = e2e.database, .body = command.raw() }, .{ .allocator = testing.allocator });
    reply.deinit();
}
