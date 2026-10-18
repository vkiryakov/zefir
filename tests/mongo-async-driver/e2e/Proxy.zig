//! A handler of `mongo.testing.Script` that forwards every command to a
//! mongod, as the driver wrote it, and answers with mongod's reply. With
//! it, `FakeDriver` and `FakeServer` run against a real server: the code
//! on the contract, the collection API and the conformance suite meet
//! mongod before any wire driver does. A command whose exchange with
//! mongod breaks becomes `close_connection`; a canceled task stays
//! canceled.
//!
//! Commands from many tasks go out at once, each on a connection of its
//! own: an idle one, or a new one.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;
const e2e = @import("root.zig");
const RawConn = @import("RawConn.zig");
const Proxy = @This();

gpa: std.mem.Allocator,
/// The port of the mongod on 127.0.0.1.
port: u16,
mutex: Io.Mutex = .init,
/// Connections to mongod that no command uses now.
idle: std.ArrayList(*RawConn) = .empty,

pub fn init(gpa: std.mem.Allocator, port: u16) Proxy {
    return .{ .gpa = gpa, .port = port };
}

/// Closes the idle connections; no command may be out.
pub fn deinit(p: *Proxy, io: Io) void {
    for (p.idle.items) |conn| conn.close(io);
    p.idle.deinit(p.gpa);
    p.* = undefined;
}

pub fn handler(p: *Proxy) Script.Handler {
    return .init(p);
}

pub fn answer(p: *Proxy, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
    const conn = p.take(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        // mongod is not there: the connection of the driver breaks.
        else => return .close_connection,
    };
    const reply = conn.forward(arena, request.body, request.sequence) catch |err| {
        const canceled = isCanceled(conn.reader.err) or isCanceled(conn.writer.err);
        // Half an exchange: this connection is of no more use.
        conn.close(io);
        if (canceled) return error.Canceled;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .close_connection,
        };
    };
    p.give(io, conn);
    return .{ .reply = reply.raw() };
}

fn isCanceled(err: anytype) bool {
    return if (err) |e| e == error.Canceled else false;
}

/// An idle connection, or a new one after its handshake.
fn take(p: *Proxy, io: Io) !*RawConn {
    p.mutex.lockUncancelable(io);
    const idle = p.idle.pop();
    p.mutex.unlock(io);
    if (idle) |conn| return conn;
    const conn = try RawConn.open(io, p.gpa, p.port);
    errdefer conn.close(io);
    _ = try conn.handshake();
    return conn;
}

fn give(p: *Proxy, io: Io, conn: *RawConn) void {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    p.idle.append(p.gpa, conn) catch conn.close(io);
}

test "FakeDriver through the proxy against mongo-plain: ping, 10 inserts at a maxWriteBatchSize of 3, a cursor of 250 documents at a batchSize of 7" {
    try e2e.onZio(throughProxy);
}

fn throughProxy(io: Io) !void {
    var proxy: Proxy = .init(testing.allocator, e2e.servers.plain_port);
    defer proxy.deinit(io);
    var script: Script = .init(testing.allocator, proxy.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    defer fake.close(io);
    const client = fake.client();
    // Under a deadline, so that maxTimeMS goes to mongod too.
    const op: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(60))));

    const pong = try client.runCommand(io, op, .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) }, .{ .allocator = testing.allocator });
    defer pong.deinit();
    try testing.expectEqual(@as(f64, 1), try (try pong.raw().get("ok")).?.asF64());
    try testing.expect(try script.entry(io, 0).body.get("maxTimeMS") != null);

    const conn = try RawConn.open(io, testing.allocator, e2e.servers.plain_port);
    defer conn.close(io);
    _ = try conn.handshake();
    try drop(conn);
    defer drop(conn) catch {};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var docs: [250]bson.RawDocument = undefined;
    for (&docs, 0..) |*doc, i| doc.* = (try bson.encode(a, .{ ._id = @as(i32, @intCast(i)), .n = @as(i32, @intCast(i)) }, .{})).raw();

    // The first ten through the fake driver, in batches of 3, 3, 3 and 1.
    var result = try client.write(io, op, .{
        .database = e2e.database,
        .kind = .insert,
        .body = bson.literal(.{ .insert = "proxy" }),
        .items = docs[0..10],
    }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 10), result.n);
    try testing.expectEqual(@as(usize, 10), result.answered);
    try testing.expectEqual(@as(usize, 0), result.write_errors.len);
    try testing.expectEqual(@as(usize, 4), script.count(io, "insert"));
    for ([_]usize{ 3, 3, 3, 1 }, 1..) |items, i| {
        var sent = script.entry(io, i).sequence.?.documents();
        var n: usize = 0;
        while (sent.next()) |_| n += 1;
        try testing.expectEqual(items, n);
    }
    // The other 240 straight to mongod, in one command.
    const rest = try conn.exchange(.{
        .request_id = 0,
        .body = bson.literal(.{ .insert = "proxy" }),
        .database = e2e.database,
        .ordered = true,
        .sequence = .{ .identifier = "documents", .documents = docs[10..] },
    }, null);
    defer rest.deinit();
    try testing.expectEqual(@as(i64, 240), try (try rest.raw().get("n")).?.asI64());

    // 250 documents at 7 a batch: the first batch and 35 getMore.
    const before = script.received(io);
    var cursor = try client.openCursor(io, op, .{
        .database = e2e.database,
        .body = bson.literal(.{ .find = "proxy", .filter = .{}, .sort = .{ ._id = 1 }, .batchSize = 7 }),
    }, .{ .batch_size = 7 });
    defer cursor.deinit(io);
    var seen: usize = 0;
    while (try cursor.next(io, op)) |doc| : (seen += 1) {
        try testing.expect(seen < docs.len);
        try testing.expectEqualSlices(u8, docs[seen].bytes, doc.bytes);
    }
    try testing.expectEqual(docs.len, seen);
    try testing.expectEqual(@as(usize, 35), script.count(io, "getMore"));
    for (before + 1..script.received(io)) |i| {
        const more = script.entry(io, i);
        try testing.expectEqualStrings("getMore", more.name);
        try testing.expectEqualStrings(e2e.database, more.database);
        try testing.expectEqualStrings("proxy", (try more.body.get("collection")).?.string);
        try testing.expectEqual(@as(i64, 7), try (try more.body.get("batchSize")).?.asI64());
        try testing.expect(try more.body.get("maxTimeMS") == null);
    }
}

test "a proxy to a port where no mongod listens breaks the connection of the driver" {
    try e2e.onZio(nothingThere);
}

fn nothingThere(io: Io) !void {
    // A port that was free a moment ago.
    var listener = try mongo.testing.FakeServer.listen(io);
    const port = mongo.testing.FakeServer.port(&listener);
    listener.deinit(io);
    var proxy: Proxy = .init(testing.allocator, port);
    defer proxy.deinit(io);
    var script: Script = .init(testing.allocator, proxy.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, fake.client().runCommand(io, .of(.root), .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
    }));
    try testing.expectEqual(@as(?mongo.Diagnostics.Phase, .wait), d.phase);
}

fn drop(conn: *RawConn) !void {
    const reply = try conn.command(e2e.database, bson.literal(.{ .drop = "proxy" }));
    reply.deinit();
}
