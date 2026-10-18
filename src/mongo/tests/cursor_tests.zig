//! Tests of the cursors of the driver against `mongo.testing.FakeServer`
//! over loopback: the first batch and getMore in the cursor's namespace,
//! errors before and in a getMore, killCursors of `close` and `deinit`,
//! and of `close` of the client. Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const Client = @import("../Client.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;

const docs = [_]bson.RawDocument{
    bson.literal(.{ ._id = 0 }),
    bson.literal(.{ ._id = 1 }),
    bson.literal(.{ ._id = 2 }),
    bson.literal(.{ ._id = 3 }),
    bson.literal(.{ ._id = 4 }),
};

const cursor_not_found = bson.literal(.{ .ok = 0.0, .errmsg = "cursor id 7 not found", .code = 43, .codeName = "CursorNotFound" });
const namespace_not_found = bson.literal(.{ .ok = 0.0, .errmsg = "ns does not exist: app.missing", .code = 26, .codeName = "NamespaceNotFound" });

/// Serves the cursors of `cursors` by collection: `find` of a collection
/// opens its cursor, `getMore` and `killCursors` go to the cursor of their
/// collection. `aggregate` gets a reply without a cursor, `missing` a
/// refusal, and `getMore` what `get_more` says.
const Router = struct {
    cursors: []Script.Cursor,
    get_more: std.atomic.Value(GetMore) = .init(.serve),

    const GetMore = enum(u8) { serve, lose, not_found };

    pub fn answer(r: *Router, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        const name = request.name;
        if (eql(name, "aggregate")) return .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) };
        if (eql(name, "missing")) return .{ .reply = namespace_not_found };
        if (eql(name, "getMore")) switch (r.get_more.load(.acquire)) {
            .serve => {},
            .lose => return .close_connection,
            .not_found => return .{ .reply = cursor_not_found },
        };
        const key = if (eql(name, "getMore")) "collection" else name;
        const collection = if (request.body.get(key) catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        for (r.cursors) |*c| {
            const dot = std.mem.findScalar(u8, c.ns, '.').?;
            if (eql(c.ns[dot + 1 ..], collection)) return c.answer(io, arena, request);
        }
        return .{ .reply = Script.ok };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    router: Router,
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [96]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io, cursors: []Script.Cursor) !void {
        s.* = .{ .router = .{ .cursors = cursors }, .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.router));
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }

    /// `driver`, a client of the server, connected where it is.
    fn connect(s: *Served, io: Io, driver: *Client) !void {
        const uri = try std.fmt.bufPrint(&s.buffer, "mongodb://127.0.0.1:{d}", .{FakeServer.port(&s.listener)});
        driver.* = try .init(testing.allocator, io, .{ .uri = uri });
        errdefer driver.deinit();
        try driver.connect(io, .root, null);
    }
};

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn find(comptime collection: []const u8) mongo.Command {
    return .{ .database = "app", .body = bson.literal(.{ .find = collection }) };
}

/// Fails unless the next document of `cursor` is `expected`.
fn expectNext(io: Io, cursor: mongo.Cursor, op: mongo.OperationContext, expected: bson.RawDocument) !void {
    const doc = (try cursor.next(io, op)) orelse return error.TestUnexpectedEnd;
    try testing.expectEqualSlices(u8, expected.bytes, doc.bytes);
}

test "a cursor gives its first batch, then gets more in its namespace, app.fs.chunks: $db app and collection fs.chunks, with batchSize and comment and without maxTimeMS; at the end next is null, and null again" {
    try within5s(testing.io, readToEnd, .{testing.io});
}

fn readToEnd(io: Io) !void {
    var chunks = [_]Script.Cursor{.{ .ns = "app.fs.chunks", .id = 7, .batches = &.{ docs[0..2], docs[2..4], docs[4..5] } }};
    var served: Served = undefined;
    try served.start(io, &chunks);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    const op = within(io, .fromMilliseconds(4000));
    const comment = bson.literal(.{ .tag = "chunks" });
    var cursor = try driver.openCursor(io, op, find("fs.chunks"), .{ .batch_size = 2, .comment = .{ .document = comment } });
    defer cursor.deinit(io);
    try testing.expectEqual(@as(usize, 1), driver.stats().open_cursors);
    for (docs) |doc| try expectNext(io, cursor, op, doc);
    try testing.expect(try cursor.next(io, op) == null);
    try testing.expect(try cursor.next(io, op) == null);
    try testing.expectEqual(@as(usize, 0), driver.stats().open_cursors);

    const script = &served.script;
    try testing.expect(try script.entry(io, 0).body.get("maxTimeMS") != null);
    try testing.expectEqual(@as(usize, 2), script.count(io, "getMore"));
    try testing.expectEqual(@as(usize, 0), script.count(io, "killCursors"));
    const get_more = bson.literal(.{ .getMore = @as(i64, 7), .collection = "fs.chunks", .batchSize = 2, .comment = .{ .tag = "chunks" }, .@"$db" = "app" });
    for (1..3) |i| try testing.expectEqualSlices(u8, get_more.bytes, script.entry(io, i).body.bytes);
}

test "a reply without a cursor is ProtocolViolation; a refusal is CommandFailed, with the reply in failure_reply; neither leaves a cursor" {
    try within5s(testing.io, noCursor, .{testing.io});
}

fn noCursor(io: Io) !void {
    var served: Served = undefined;
    try served.start(io, &.{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.ProtocolViolation, driver.openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .aggregate = "users", .pipeline = [0]i32{}, .cursor = .{} }) }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the reply holds no cursor; the command may have run", d.message());
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, driver.openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .missing = 1 }) }, .{ .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, namespace_not_found.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 26), d.server.?.code);
    try testing.expectEqual(@as(usize, 0), driver.cursors.liveCount(io));
}

test "the documents of a batch come out past the deadline; a deadline or a token before getMore leaves the cursor as it was, and a lost getMore ends it" {
    try within5s(testing.io, errorsOfGetMore, .{testing.io});
}

fn errorsOfGetMore(io: Io) !void {
    var users = [_]Script.Cursor{.{ .ns = "app.users", .id = 7, .batches = &.{ docs[0..2], docs[2..3], docs[3..4] } }};
    var served: Served = undefined;
    try served.start(io, &users);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    const script = &served.script;
    var d: Diagnostics = .{};
    const op = within(io, .fromMilliseconds(200));
    var cursor = try driver.openCursor(io, op, find("users"), .{ .diagnostics = &d });
    defer cursor.deinit(io);
    try expectNext(io, cursor, op, docs[0]);
    try time.sleepUntil(io, op.ctx.deadline.?);
    try expectNext(io, cursor, op, docs[1]);
    try testing.expectError(error.DeadlineExceeded, cursor.next(io, op));
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, cursor.next(io, .of(core.Context.root.withCancellation(&token))));
    try testing.expectEqual(@as(usize, 0), script.count(io, "getMore"));
    try expectNext(io, cursor, .of(.root), docs[2]);

    served.router.get_more.store(.lose, .release);
    try testing.expectError(error.ConnectionLost, cursor.next(io, .of(.root)));
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    try testing.expectEqualStrings("the cursor is closed", d.message());
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    // The server may still hold it: close kills it.
    served.router.get_more.store(.serve, .release);
    cursor.close(io);
    try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
}

test "CursorNotFound ends the cursor, which leaves nothing to kill" {
    try within5s(testing.io, notFound, .{testing.io});
}

fn notFound(io: Io) !void {
    var users = [_]Script.Cursor{.{ .ns = "app.users", .id = 7, .batches = &.{ docs[0..1], docs[1..2] } }};
    var served: Served = undefined;
    try served.start(io, &users);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    var d: Diagnostics = .{};
    var cursor = try driver.openCursor(io, .of(.root), find("users"), .{ .diagnostics = &d });
    defer cursor.deinit(io);
    try expectNext(io, cursor, .of(.root), docs[0]);
    served.router.get_more.store(.not_found, .release);
    try testing.expectError(error.CommandFailed, cursor.next(io, .of(.root)));
    try testing.expectEqual(@as(i32, 43), d.server.?.code);
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    try testing.expectEqual(@as(usize, 0), driver.stats().open_cursors);
    cursor.close(io);
    try testing.expectEqual(@as(usize, 0), served.script.count(io, "killCursors"));
}

test "close and deinit send killCursors once, with a budget of their own past the deadline and the task's cancelation held off; a cursor read to its end sends none" {
    try within5s(testing.io, kills, .{testing.io});
}

/// Closes `cursor` in a task whose cancelation is pending, and checks that
/// it still is after.
fn closeCanceled(io: Io, cursor: mongo.Cursor) !void {
    io.sleep(.fromSeconds(3600), .awake) catch {};
    io.recancel();
    cursor.close(io);
    try testing.expectError(error.Canceled, io.checkCancel());
}

fn kills(io: Io) !void {
    var users = [_]Script.Cursor{.{ .ns = "app.users", .id = 7, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } }};
    var served: Served = undefined;
    try served.start(io, &users);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    const script = &served.script;
    const c = &driver;
    {
        var cursor = try c.openCursor(io, .of(.root), find("users"), .{});
        defer cursor.deinit(io);
        try expectNext(io, cursor, .of(.root), docs[0]);
        cursor.close(io);
        cursor.close(io);
        try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
        try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    }
    try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
    {
        var cursor = try c.openCursor(io, .of(.root), find("users"), .{});
        try expectNext(io, cursor, .of(.root), docs[0]);
        cursor.deinit(io);
        try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
    }
    {
        var cursor = try c.openCursor(io, .of(.root), find("users"), .{});
        defer cursor.deinit(io);
        while (try cursor.next(io, .of(.root))) |_| {}
    }
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
    {
        const op = within(io, .fromMilliseconds(100));
        var cursor = try c.openCursor(io, op, find("users"), .{});
        defer cursor.deinit(io);
        try time.sleepUntil(io, op.ctx.deadline.?);
        cursor.close(io);
        try testing.expectEqual(@as(usize, 3), script.count(io, "killCursors"));
    }
    {
        var cursor = try c.openCursor(io, .of(.root), find("users"), .{});
        defer cursor.deinit(io);
        var closer = try io.concurrent(closeCanceled, .{ io, cursor });
        try closer.cancel(io);
        try testing.expectEqual(@as(usize, 4), script.count(io, "killCursors"));
    }
    const kill = bson.literal(.{ .killCursors = "users", .cursors = .{@as(i64, 7)}, .@"$db" = "app" });
    for (0..4) |i| {
        var seen: usize = 0;
        for (0..script.received(io)) |at| {
            const entry = script.entry(io, at);
            if (!eql(entry.name, "killCursors")) continue;
            if (seen == i) try testing.expectEqualSlices(u8, kill.bytes, entry.body.bytes);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), driver.cursors.liveCount(io));
}

test "close of the client ends every cursor and kills those that the server holds, on a connection of its own; stats count the open cursors" {
    try within5s(testing.io, closeKills, .{testing.io});
}

fn closeKills(io: Io) !void {
    var cursors = [_]Script.Cursor{
        .{ .ns = "app.a", .id = 11, .batches = &.{ docs[0..1], docs[1..2] } },
        .{ .ns = "app.b", .id = 12, .batches = &.{ docs[0..1], docs[1..2] } },
        .{ .ns = "app.c", .id = 13, .batches = &.{docs[0..1]} },
    };
    var served: Served = undefined;
    try served.start(io, &cursors);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    const c = &driver;
    var a = try c.openCursor(io, .of(.root), find("a"), .{});
    defer a.deinit(io);
    var b = try c.openCursor(io, .of(.root), find("b"), .{});
    defer b.deinit(io);
    // A cursor of one batch: the server holds nothing of it, and close of
    // the client ends it all the same.
    var done = try c.openCursor(io, .of(.root), find("c"), .{});
    defer done.deinit(io);
    try testing.expectEqual(@as(usize, 2), driver.stats().open_cursors);
    const accepted = served.script.acceptedConnections();

    driver.close(io);
    const script = &served.script;
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
    try testing.expectEqual(accepted + 1, served.script.acceptedConnections());
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "a", .cursors = .{@as(i64, 11)}, .@"$db" = "app" }).bytes, script.entry(io, script.received(io) - 2).body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "b", .cursors = .{@as(i64, 12)}, .@"$db" = "app" }).bytes, script.entry(io, script.received(io) - 1).body.bytes);
    try testing.expectError(error.Closed, a.next(io, .of(.root)));
    try testing.expectError(error.Closed, done.next(io, .of(.root)));
    try testing.expectEqual(@as(usize, 0), driver.stats().open_cursors);
    // Nothing more goes out: not for a second close, nor for the cursors.
    driver.close(io);
    a.close(io);
    b.close(io);
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
}
