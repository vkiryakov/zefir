//! Tests of `mongo.OdmDriver` against `mongo.testing.FakeServer` over
//! loopback: what reaches the server, how the errors and diagnostics of
//! zefir-mongo become those of odm, and the capabilities. Every test runs
//! under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("../root.zig");
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const within5s = @import("connection_tests.zig").within5s;

const ns: odm.Client.Namespace = .{ .database = "app", .collection = "users" };

/// A scripted server on loopback, served until `stop`; no client of its
/// own connects to it. It points into itself: start it in place.
const Server = struct {
    script: Script,
    listener: net.Server,
    server: Io.Future(FakeServer.ServeError!void),
    buffer: [64]u8,
    /// "mongodb://127.0.0.1:<port>", in `buffer`.
    uri: []const u8,

    fn start(s: *Server, io: Io, handler: Script.Handler) !void {
        s.script = .init(testing.allocator, handler);
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.uri = try FakeServer.uri(&s.listener, &s.buffer);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    fn stop(s: *Server, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }
};

/// A client of `uri` from the driver, connected.
fn connected(driver: *mongo.OdmDriver, io: Io, uri: []const u8) !odm.Client {
    const client = try driver.driver().open(io, &.{ .uri = uri });
    errdefer release(client, io);
    try client.connect(io, .root, null);
    return client;
}

fn release(client: odm.Client, io: Io) void {
    client.close(io);
    client.deinit();
}

test "open makes a client without a connection" {
    try within5s(testing.io, opensWithoutConnection, .{testing.io});
}

fn opensWithoutConnection(io: Io) !void {
    var queue: Script.Queue = .{ .answers = &.{} };
    var server: Server = undefined;
    try server.start(io, queue.handler());
    defer server.stop(io);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    const client = try driver.driver().open(io, &.{ .uri = server.uri });
    defer release(client, io);
    // Time enough for a connection to show, if open had made one.
    try mongo.testing.sleepAtLeast(io, .fromMilliseconds(50));
    try testing.expectEqual(@as(u32, 0), server.script.acceptedConnections());
    try testing.expectEqual(@as(usize, 0), server.script.received(io));
    try testing.expectEqual(@as(usize, 0), client.stats().?.connections);
    // connect makes the first one.
    try client.connect(io, .root, null);
    try testing.expectEqual(@as(usize, 1), client.stats().?.connections);
}

test "a write error 11000 becomes DuplicateKey with its index" {
    try within5s(testing.io, duplicateKeys, .{testing.io});
}

fn duplicateKeys(io: Io) !void {
    const documents = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .email = "ann@example.com" }),
        bson.literal(.{ ._id = 2, .email = "ann@example.com" }),
        bson.literal(.{ ._id = 3, .email = "bob@example.com" }),
    };
    // 11001 and 12582 are duplicate keys too; 121 (DocumentValidationFailure)
    // is another refusal.
    for ([_]i32{ 11000, 11001, 12582, 121 }) |code| {
        var write: Script.Write = .{ .refuse = &.{.{ .index = 1, .code = code, .errmsg = "the server refused the document" }} };
        var server: Server = undefined;
        try server.start(io, write.handler());
        defer server.stop(io);
        var driver: mongo.OdmDriver = .init(testing.allocator);
        const client = try connected(&driver, io, server.uri);
        defer release(client, io);
        var d: odm.Diagnostics = .{};
        const inserted = client.insert(io, .root, &.{ .ns = ns, .documents = &documents }, .{ .allocator = testing.allocator, .diagnostics = &d });
        if (code == 121) {
            try testing.expectError(error.WriteFailed, inserted);
        } else try testing.expectError(error.DuplicateKey, inserted);
        try testing.expectEqual(@as(?usize, 1), d.index);
        try testing.expectEqual(@as(?i32, code), d.code);
        try testing.expectEqualStrings("the server refused the document", d.message());
    }
}

test "find with limit 1 is one batch" {
    try within5s(testing.io, findOne, .{testing.io});
}

fn findOne(io: Io) !void {
    const ann = bson.literal(.{ ._id = 1, .name = "Ann" });
    var users: Script.Cursor = .{ .ns = "app.users", .batches = &.{&.{ann}} };
    var server: Server = undefined;
    try server.start(io, users.handler());
    defer server.stop(io);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    const client = try connected(&driver, io, server.uri);
    var d: odm.Diagnostics = .{};
    const cursor = try client.find(io, .root, &.{ .ns = ns, .filter = bson.literal(.{ .name = "Ann" }), .limit = 1 }, .{ .allocator = testing.allocator, .diagnostics = &d });
    const doc = (try cursor.next(io, .root, &d)) orelse return error.TestExpectedDocument;
    try testing.expectEqualSlices(u8, ann.bytes, doc.bytes);
    try testing.expect(try cursor.next(io, .root, &d) == null);
    cursor.deinit(io);
    release(client, io);

    try testing.expectEqual(@as(usize, 1), server.script.received(io));
    const find = try server.script.entry(io, 0);
    try testing.expectEqualStrings("find", find.name);
    const single = (try find.body.get("singleBatch")) orelse return error.TestExpectedSingleBatch;
    try testing.expect(single == .boolean and single.boolean);
    try testing.expectEqual(@as(i64, 1), try ((try find.body.get("limit")) orelse return error.TestExpectedLimit).asI64());
    try testing.expectEqual(@as(usize, 0), server.script.count(io, "killCursors"));
}

test "every capability is true" {
    const io = testing.io;
    var driver: mongo.OdmDriver = .init(testing.allocator);
    const d = driver.driver();
    try testing.expectEqualStrings("zefir-mongo", d.name());
    // Nothing listens at this port; open does not try it.
    const client = try d.open(io, &.{ .uri = "mongodb://127.0.0.1:1" });
    defer release(client, io);
    try testing.expectEqual(odm.Capabilities{ .aggregate = true, .count = true, .indexes = true, .command = true }, client.capabilities());
}

test "diagnostics carry the server's code and message" {
    try within5s(testing.io, serversError, .{testing.io});
}

fn serversError(io: Io) !void {
    const refusal = bson.literal(.{ .ok = 0.0, .errmsg = "no such command: 'zefirNope'", .code = 59, .codeName = "CommandNotFound" });
    var queue: Script.Queue = .{ .answers = &.{.{ .reply = refusal }} };
    var server: Server = undefined;
    try server.start(io, queue.handler());
    defer server.stop(io);
    var driver: mongo.OdmDriver = .init(testing.allocator);

    var d: odm.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, driver.driver().open(io, &.{ .uri = "http://127.0.0.1", .diagnostics = &d }));
    try testing.expectEqualStrings("a connection string starts with mongodb://", d.message());

    const client = try connected(&driver, io, server.uri);
    defer release(client, io);
    try testing.expectError(error.CommandFailed, client.command(io, .root, &.{ .database = "app", .body = bson.literal(.{ .zefirNope = 1 }) }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(?i32, 59), d.code);
    try testing.expectEqual(@as(?usize, null), d.index);
    try testing.expectEqualStrings("no such command: 'zefirNope'", d.message());
}
