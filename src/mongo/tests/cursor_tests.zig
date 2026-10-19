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
const Connected = @import("Served.zig");
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
    const op = within(io, .fromMilliseconds(200));
    var cursor = try driver.openCursor(io, op, find("users"), .{});
    defer cursor.deinit(io);
    try expectNext(io, cursor, op, docs[0]);
    try time.sleepUntil(io, op.ctx.deadline.?);
    try expectNext(io, cursor, op, docs[1]);
    try testing.expectError(error.DeadlineExceeded, cursor.next(io, op));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the command went out", cursor.diagnostics().message());
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, cursor.next(io, .of(core.Context.root.withCancellation(&token))));
    try testing.expectEqual(@as(usize, 0), script.count(io, "getMore"));
    try expectNext(io, cursor, .of(.root), docs[2]);

    served.router.get_more.store(.lose, .release);
    try testing.expectError(error.ConnectionLost, cursor.next(io, .of(.root)));
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    try testing.expectEqualStrings("the cursor is closed", cursor.diagnostics().message());
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    // The server may still hold it: close kills it.
    served.router.get_more.store(.serve, .release);
    cursor.close(io);
    try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
}

test "nextOwned that runs out of memory leaves the document where it was: the next call gives it, also after a getMore" {
    try within5s(testing.io, ownedOutOfMemory, .{testing.io});
}

fn ownedOutOfMemory(io: Io) !void {
    var users = [_]Script.Cursor{.{ .ns = "app.users", .id = 7, .batches = &.{ docs[0..2], docs[2..3] } }};
    var served: Served = undefined;
    try served.start(io, &users);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    var cursor = try driver.openCursor(io, .of(.root), find("users"), .{});
    defer cursor.deinit(io);
    try testing.expectError(error.OutOfMemory, cursor.nextOwned(io, .of(.root), testing.failing_allocator));
    const first = (try cursor.nextOwned(io, .of(.root), testing.allocator)) orelse return error.TestUnexpectedEnd;
    defer first.deinit();
    try testing.expectEqualSlices(u8, docs[0].bytes, first.bytes);
    try expectNext(io, cursor, .of(.root), docs[1]);
    // The batch is out: the getMore goes, and its document waits.
    try testing.expectError(error.OutOfMemory, cursor.nextOwned(io, .of(.root), testing.failing_allocator));
    try testing.expectEqual(@as(usize, 1), served.script.count(io, "getMore"));
    const third = (try cursor.nextOwned(io, .of(.root), testing.allocator)) orelse return error.TestUnexpectedEnd;
    defer third.deinit();
    try testing.expectEqualSlices(u8, docs[2].bytes, third.bytes);
    try testing.expect(try cursor.nextOwned(io, .of(.root), testing.allocator) == null);
    try testing.expectEqual(@as(usize, 1), served.script.count(io, "getMore"));
}

test "the diagnostics and the failure_reply of openCursor serve the call alone: a getMore leaves them alone, and its errors stay in the cursor, each error afresh" {
    try within5s(testing.io, ownDiagnostics, .{testing.io});
}

fn ownDiagnostics(io: Io) !void {
    var users = [_]Script.Cursor{.{ .ns = "app.users", .id = 7, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } }};
    var served: Served = undefined;
    try served.start(io, &users);
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver);
    defer driver.deinit();
    var d: Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    defer if (failure) |f| f.deinit();
    var cursor = try driver.openCursor(io, .of(.root), find("users"), .{ .diagnostics = &d, .failure_reply = &failure });
    defer cursor.deinit(io);
    // Once openCursor returned, they are the caller's own again.
    d.set(.wait, null, "the caller's own", .{});
    try testing.expectEqualStrings("", cursor.diagnostics().message());
    try testing.expect(cursor.failureReply() == null);
    try expectNext(io, cursor, .of(.root), docs[0]);
    try expectNext(io, cursor, .of(.root), docs[1]);
    served.router.get_more.store(.not_found, .release);
    try testing.expectError(error.CommandFailed, cursor.next(io, .of(.root)));
    try testing.expectEqualStrings("the caller's own", d.message());
    try testing.expect(d.server == null);
    try testing.expectEqual(@as(?Diagnostics.Phase, .wait), d.phase);
    try testing.expect(failure == null);
    const own = cursor.diagnostics();
    try testing.expectEqual(@as(?i32, 43), if (own.server) |server| server.code else null);
    try testing.expectEqualStrings("cursor id 7 not found", own.message());
    const reply = cursor.failureReply() orelse return error.TestNoFailureReply;
    try testing.expectEqualSlices(u8, cursor_not_found.bytes, reply.bytes);
    // The next error starts them afresh: Closed, of no server.
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    try testing.expectEqualStrings("the cursor is closed", own.message());
    try testing.expect(own.server == null);
    try testing.expect(cursor.failureReply() == null);
    try testing.expectEqualStrings("the caller's own", d.message());
    // A cursor without a state, as listIndexes gives for a collection
    // that is not there, has nothing to tell.
    const empty: mongo.Cursor = .{ .state = null };
    try testing.expectEqualStrings("", empty.diagnostics().message());
    try testing.expect(empty.failureReply() == null);
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
    var cursor = try driver.openCursor(io, .of(.root), find("users"), .{});
    defer cursor.deinit(io);
    try expectNext(io, cursor, .of(.root), docs[0]);
    served.router.get_more.store(.not_found, .release);
    try testing.expectError(error.CommandFailed, cursor.next(io, .of(.root)));
    try testing.expectEqual(@as(?i32, 43), if (cursor.diagnostics().server) |server| server.code else null);
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

test "close of the client kills the cursors that the server holds before it closes the connections: on an idle one, one killCursors per namespace with all its ids; stats count the open cursors" {
    try within5s(testing.io, closeKills, .{testing.io});
}

/// Opens a cursor at each `find`, of one batch and open on the server, but
/// for collection `done`: ids 21, 22, … in the namespace of its
/// collection. Holds `slow` for 3 s, and answers anything else with
/// `{ok: 1.0}`.
const Fresh = struct {
    next_id: std.atomic.Value(i64) = .init(21),

    pub fn answer(f: *Fresh, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        if (eql(request.name, "slow")) return .{ .delayed = .{ .after = .fromSeconds(3), .reply = Script.ok } };
        if (!eql(request.name, "find")) return .{ .reply = Script.ok };
        const collection = if (request.body.get("find") catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        const ns = try std.fmt.allocPrint(arena, "app.{s}", .{collection});
        const id = if (eql(collection, "done")) 0 else f.next_id.fetchAdd(1, .monotonic);
        const reply = Script.cursorReply(arena, ns, id, .first, docs[0..1]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBson => return .{ .reply = Script.ok },
        };
        return .{ .reply = reply };
    }
};

fn closeKills(io: Io) !void {
    var fresh: Fresh = .{};
    var served: Connected = undefined;
    try served.start(io, .init(&fresh), .{});
    defer served.stop(io);
    const c = served.client();
    var a = try c.openCursor(io, .of(.root), find("a"), .{});
    defer a.deinit(io);
    var b = try c.openCursor(io, .of(.root), find("b"), .{});
    defer b.deinit(io);
    var again = try c.openCursor(io, .of(.root), find("a"), .{});
    defer again.deinit(io);
    // A cursor of one batch: the server holds nothing of it, and close of
    // the client ends it all the same.
    var done = try c.openCursor(io, .of(.root), find("done"), .{});
    defer done.deinit(io);
    try testing.expectEqual(@as(usize, 3), c.stats().open_cursors);
    const script = &served.script;
    const accepted = script.acceptedConnections();

    c.close(io);
    // The connection of the finds, idle, sent the kills: no new one.
    try testing.expectEqual(accepted, script.acceptedConnections());
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
    const first = script.entry(io, script.received(io) - 2);
    const second = script.entry(io, script.received(io) - 1);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "a", .cursors = .{ @as(i64, 21), @as(i64, 23) }, .@"$db" = "app" }).bytes, first.body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "b", .cursors = .{@as(i64, 22)}, .@"$db" = "app" }).bytes, second.body.bytes);
    try testing.expectEqual(@as(u32, 1), first.connection);
    try testing.expectEqual(@as(u32, 1), second.connection);
    // Then the connections closed.
    try testing.expectEqual(@as(usize, 0), c.stats().connections);
    try testing.expectError(error.Closed, a.next(io, .of(.root)));
    try testing.expectError(error.Closed, done.next(io, .of(.root)));
    try testing.expectEqual(@as(usize, 0), c.stats().open_cursors);
    // Nothing more goes out: not for a second close, nor for the cursors.
    c.close(io);
    a.close(io);
    b.close(io);
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
}

test "close of the client opens a connection for the kills only when none is left idle" {
    try within5s(testing.io, closeKillsOnNew, .{testing.io});
}

/// A call whose exchange close cuts.
fn slowCut(io: Io, driver: *Client) !void {
    try testing.expectError(error.ConnectionLost, driver.runCommand(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .slow = 1 }) }, .{ .allocator = testing.allocator }));
}

fn closeKillsOnNew(io: Io) !void {
    var fresh: Fresh = .{};
    var script: Script = .init(testing.allocator, .init(&fresh));
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer), .close_timeout = .fromMilliseconds(50) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var a = try driver.openCursor(io, .of(.root), find("a"), .{});
    defer a.deinit(io);
    // The only connection is out when close begins, and close cuts it.
    var call = try io.concurrent(slowCut, .{ io, &driver });
    defer call.cancel(io) catch {};
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (script.count(io, "slow") == 0) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    driver.close(io);
    try call.await(io);
    try testing.expectEqual(@as(u32, 2), script.acceptedConnections());
    try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
    const kill = script.entry(io, script.received(io) - 1);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "a", .cursors = .{@as(i64, 21)}, .@"$db" = "app" }).bytes, kill.body.bytes);
    try testing.expectEqual(@as(u32, 2), kill.connection);
}
