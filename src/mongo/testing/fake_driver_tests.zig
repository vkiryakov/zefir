//! Tests of `mongo.testing.FakeDriver` through `mongo.Client`: commands,
//! cursors, writes split by the script's hello, deadlines, cancelation,
//! lost connections and closing.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;

fn ok(reply: bson.OwnedDocument) !void {
    defer reply.deinit();
    try testing.expectEqual(@as(f64, 1), try (try reply.raw().get("ok")).?.asF64());
}

fn count(client: mongo.Client, io: Io, op: mongo.OperationContext, diagnostics: ?*mongo.Diagnostics) mongo.Error!bson.OwnedDocument {
    return client.runCommand(io, op, .{ .database = "app", .body = bson.literal(.{ .count = "users" }) }, .{ .allocator = testing.allocator, .diagnostics = diagnostics });
}

fn within(io: Io, seconds: i64) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(seconds))));
}

/// Waits until the journal holds `n` commands, for 5 s at most.
fn awaitReceived(io: Io, script: *Script, n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (script.received(io) < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.TestCommandNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a command reaches the script as a driver sends it, with $db, and its reply comes back as it was" {
    const io = testing.io;
    const reply = bson.literal(.{ .n = 5, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{.{ .reply = reply }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const client = fake.client();

    const got = try count(client, io, .of(.root), null);
    defer got.deinit();
    try testing.expectEqualSlices(u8, reply.bytes, got.bytes);
    const entry = script.entry(io, 0);
    try testing.expectEqual(@as(u32, 1), entry.connection);
    try testing.expectEqualStrings("count", entry.name);
    try testing.expectEqualStrings("app", entry.database);
    // The body as it was, then $db, and nothing else without a deadline.
    try testing.expectEqualSlices(u8, bson.literal(.{ .count = "users", .@"$db" = "app" }).bytes, entry.body.bytes);
}

test "ok 0 is CommandFailed with the server's error and its reply; code 50 is Timeout" {
    const io = testing.io;
    const failed = bson.literal(.{ .ok = 0.0, .errmsg = "no such command: 'count'", .code = 59, .codeName = "CommandNotFound" });
    const expired = bson.literal(.{ .ok = 0.0, .errmsg = "operation exceeded time limit", .code = 50, .codeName = "MaxTimeMSExpired" });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = failed }, .{ .reply = expired } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, fake.client().runCommand(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .count = "users" }) }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, failed.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 59), d.server.?.code);
    try testing.expectEqualStrings("no such command: 'count'", d.message());
    try testing.expectError(error.Timeout, count(fake.client(), io, .of(.root), &d));
    try testing.expectEqual(@as(i32, 50), d.server.?.code);
}

test "under a deadline, maxTimeMS is the time left; with less than 1 ms left nothing is sent" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{.{ .reply = Script.ok }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    try ok(try count(fake.client(), io, within(io, 10), null));
    const body = script.entry(io, 0).body;
    const max_time = try (try body.get("maxTimeMS")).?.asI64();
    try testing.expect(max_time >= 1 and max_time <= 10_000);
    try testing.expectEqual(bson.Type.int64, std.meta.activeTag((try body.get("maxTimeMS")).?));

    const past: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .zero)));
    try testing.expectError(error.DeadlineExceeded, count(fake.client(), io, past, null));
    try testing.expectEqual(@as(usize, 1), script.received(io));
}

test "a cursor reads its batches with getMore in its namespace, and the end is null, again and again" {
    const io = testing.io;
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }), bson.literal(.{ .n = 2 }), bson.literal(.{ .n = 3 }) };
    var chunks: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 7, .batches = &.{ docs[0..2], docs[2..3], docs[3..4] } };
    var script: Script = .init(testing.allocator, chunks.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const op = within(io, 30);
    var cursor = try fake.client().openCursor(io, op, .{ .database = "app", .body = bson.literal(.{ .find = "fs.chunks" }) }, .{
        .batch_size = 2,
        .comment = .{ .string = "a comment" },
    });
    defer cursor.deinit(io);
    for (docs) |expected| {
        const doc = (try cursor.next(io, op)) orelse return error.TestCursorEndedEarly;
        try testing.expectEqualSlices(u8, expected.bytes, doc.bytes);
    }
    try testing.expect(try cursor.next(io, op) == null);
    try testing.expect(try cursor.next(io, op) == null);

    try testing.expectEqual(@as(usize, 3), script.received(io));
    for (1..3) |i| {
        const more = script.entry(io, i);
        try testing.expectEqualStrings("getMore", more.name);
        try testing.expectEqualSlices(u8, bson.literal(.{
            .getMore = @as(i64, 7),
            .collection = "fs.chunks",
            .batchSize = 2,
            .comment = "a comment",
            .@"$db" = "app",
        }).bytes, more.body.bytes);
    }
    // Exhausted: neither close nor deinit sends killCursors.
    cursor.close(io);
    try testing.expectEqual(@as(usize, 0), script.count(io, "killCursors"));
}

test "close in the middle of a cursor sends one killCursors with its id, even past the deadline; next is Closed after it" {
    const io = testing.io;
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }) };
    var chunks: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 11, .batches = &.{ docs[0..1], docs[1..2] } };
    var script: Script = .init(testing.allocator, chunks.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var cursor = try fake.client().openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "fs.chunks" }) }, .{});
    defer cursor.deinit(io);
    _ = (try cursor.next(io, .of(.root))).?;
    cursor.close(io);
    cursor.close(io);
    try testing.expectEqual(@as(usize, 1), script.count(io, "killCursors"));
    const kill = script.entry(io, 1);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "fs.chunks", .cursors = .{@as(i64, 11)}, .@"$db" = "app" }).bytes, kill.body.bytes);
    try testing.expectEqual(@as(u32, 1), chunks.kills);
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));

    // deinit without close kills it too, once, with a budget of its own.
    var second = try fake.client().openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "fs.chunks" }) }, .{});
    _ = (try second.next(io, .of(.root))).?;
    second.deinit(io);
    try testing.expectEqual(@as(usize, 2), script.count(io, "killCursors"));
}

test "a cursor stays as it was after a deadline before getMore, and a lost getMore ends it" {
    const io = testing.io;
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }), bson.literal(.{ .n = 2 }) };
    var chunks: Script.Cursor = .{ .ns = "app.users", .id = 3, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } };
    const Lose = struct {
        cursor: *Script.Cursor,
        lose_next_get_more: bool = false,

        pub fn answer(self: *@This(), io_: Io, arena: std.mem.Allocator, r: *const Script.Request) Script.HandlerError!Script.Answer {
            if (self.lose_next_get_more and std.mem.eql(u8, r.name, "getMore")) return .close_connection;
            return self.cursor.answer(io_, arena, r);
        }
    };
    var lose: Lose = .{ .cursor = &chunks };
    var script: Script = .init(testing.allocator, .init(&lose));
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var cursor = try fake.client().openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "users" }) }, .{});
    defer cursor.deinit(io);
    _ = (try cursor.next(io, .of(.root))).?;
    const past: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .zero)));
    try testing.expectError(error.DeadlineExceeded, cursor.next(io, past));
    try testing.expectEqualSlices(u8, docs[1].bytes, (try cursor.next(io, .of(.root))).?.bytes);

    lose.lose_next_get_more = true;
    try testing.expectError(error.ConnectionLost, cursor.next(io, .of(.root)));
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
}

test "a reply without cursor is a protocol violation, and CursorNotFound at getMore is CommandFailed" {
    const io = testing.io;
    const first = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ .n = 0 }}, .id = @as(i64, 5), .ns = "app.users" }, .ok = 1.0 });
    const not_found = bson.literal(.{ .ok = 0.0, .errmsg = "cursor id 5 not found", .code = 43, .codeName = "CursorNotFound" });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = Script.ok }, .{ .reply = first }, .{ .reply = not_found } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const find: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .find = "users" }) };
    try testing.expectError(error.ProtocolViolation, fake.client().openCursor(io, .of(.root), find, .{}));
    var d: mongo.Diagnostics = .{};
    var cursor = try fake.client().openCursor(io, .of(.root), find, .{ .diagnostics = &d });
    defer cursor.deinit(io);
    _ = (try cursor.next(io, .of(.root))).?;
    try testing.expectError(error.CommandFailed, cursor.next(io, .of(.root)));
    try testing.expectEqual(@as(i32, 43), d.server.?.code);
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    // The server has no such cursor: deinit sends no killCursors.
    cursor.close(io);
    try testing.expectEqual(@as(usize, 0), script.count(io, "killCursors"));
}

fn insertTen(fake: *FakeDriver, io: Io, ordered: bool, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
    var items: [10]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = switch (i) {
        inline 0...9 => |n| bson.literal(.{ ._id = @as(i32, n) }),
        else => unreachable,
    };
    return fake.client().write(io, .of(.root), .{
        .database = "app",
        .kind = .insert,
        .body = bson.literal(.{ .insert = "users" }),
        .items = &items,
        .ordered = ordered,
    }, options);
}

test "a write is split by the script's maxWriteBatchSize, and its replies are merged" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 4 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var result = try insertTen(&fake, io, false, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 9), result.n);
    try testing.expectEqual(@as(usize, 10), result.answered);
    try testing.expectEqual(@as(usize, 1), result.write_errors.len);
    try testing.expectEqual(@as(usize, 4), result.write_errors[0].index);

    try testing.expectEqual(@as(usize, 4), script.received(io));
    for ([_]usize{ 3, 3, 3, 1 }, 0..) |items, i| {
        const entry = script.entry(io, i);
        try testing.expectEqualStrings("insert", entry.name);
        try testing.expectEqualStrings("documents", entry.sequence.?.identifier);
        try testing.expectEqual(false, (try entry.body.get("ordered")).?.boolean);
        var docs = entry.sequence.?.documents();
        var n: usize = 0;
        while (docs.next()) |_| n += 1;
        try testing.expectEqual(items, n);
    }
}

test "an ordered write sends no batch after the one with a refused item" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 4 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var result = try insertTen(&fake, io, true, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 4), result.n);
    try testing.expectEqual(@as(usize, 6), result.answered);
    try testing.expectEqual(@as(usize, 2), script.received(io));
}

test "a write cut at its third batch is IncompleteWrite, with the two batches before in partial" {
    const io = testing.io;
    const three = bson.literal(.{ .n = 3, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = three }, .{ .reply = three }, .close_connection } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.IncompleteWrite, insertTen(&fake, io, true, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    try testing.expectEqual(@as(?mongo.Error, error.ConnectionLost), d.reason);
    try testing.expectEqual(@as(?usize, 6), d.batch_offset);
    try testing.expectEqual(@as(u64, 6), partial.n);
    try testing.expectEqual(@as(usize, 6), partial.answered);
}

test "a token canceled after the second batch stops the write at the third: IncompleteWrite for Cancelled" {
    const io = testing.io;
    const CancelAfterTwo = struct {
        token: core.CancellationToken = .init,
        batches: u32 = 0,

        pub fn answer(self: *@This(), io_: Io, arena: std.mem.Allocator, r: *const Script.Request) Script.HandlerError!Script.Answer {
            _ = io_;
            _ = arena;
            _ = r;
            self.batches += 1;
            if (self.batches == 2) self.token.cancel();
            return .{ .reply = bson.literal(.{ .n = 3, .ok = 1.0 }) };
        }
    };
    var handler: CancelAfterTwo = .{};
    var script: Script = .init(testing.allocator, .init(&handler));
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var items: [10]bson.RawDocument = @splat(bson.literal(.{ .n = 1 }));
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    const op: mongo.OperationContext = .of(core.Context.root.withCancellation(&handler.token));
    try testing.expectError(error.IncompleteWrite, fake.client().write(io, op, .{
        .database = "app",
        .kind = .insert,
        .body = bson.literal(.{ .insert = "users" }),
        .items = &items,
    }, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    try testing.expectEqual(@as(?mongo.Error, error.Cancelled), d.reason);
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(error.IncompleteWrite));
    try testing.expectEqual(@as(u64, 6), partial.n);
    try testing.expectEqual(@as(usize, 2), script.received(io));
}

test "a reply held past the deadline is Timeout at the deadline, and the next call goes through on a new connection" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .delayed = .{ .after = .fromSeconds(10), .reply = Script.ok } }, .{ .reply = Script.ok } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const start = Io.Clock.awake.now(io);
    const op: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(start, .fromMilliseconds(100))));
    try testing.expectError(error.Timeout, count(fake.client(), io, op, null));
    const took = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(took.nanoseconds >= 100 * std.time.ns_per_ms);
    try testing.expect(took.nanoseconds < 5 * std.time.ns_per_s);
    try ok(try count(fake.client(), io, .of(.root), null));
    try testing.expectEqual(@as(u32, 2), script.entry(io, 1).connection);
}

/// How a call in a task of its own ended.
const Ended = struct {
    err: ?mongo.Error = null,
    /// Whether the task still saw its cancelation after the call.
    kept_cancelation: bool = false,
};

fn countInTask(io: Io, client: mongo.Client, ended: *Ended) void {
    if (count(client, io, .of(.root), null)) |reply| reply.deinit() else |err| ended.err = err;
    io.checkCancel() catch {
        ended.kept_cancelation = true;
    };
}

test "a task canceled while its reply is held gets Interrupted, and keeps its cancelation" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{.{ .delayed = .{ .after = .fromSeconds(10), .reply = Script.ok } }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ended: Ended = .{};
    var task = try io.concurrent(countInTask, .{ io, fake.client(), &ended });
    defer task.cancel(io);
    try awaitReceived(io, &script, 1);
    task.cancel(io);
    try testing.expectEqual(@as(?mongo.Error, error.Interrupted), ended.err);
    try testing.expect(ended.kept_cancelation);
}

test "a token canceled while the command is out is Interrupted after the reply" {
    const io = testing.io;
    const CancelDuring = struct {
        token: core.CancellationToken = .init,

        pub fn answer(self: *@This(), io_: Io, arena: std.mem.Allocator, r: *const Script.Request) Script.HandlerError!Script.Answer {
            _ = io_;
            _ = arena;
            _ = r;
            self.token.cancel();
            return .{ .reply = Script.ok };
        }
    };
    var handler: CancelDuring = .{};
    var script: Script = .init(testing.allocator, .init(&handler));
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    try testing.expectError(error.Interrupted, count(fake.client(), io, .of(core.Context.root.withCancellation(&handler.token)), null));
    try testing.expectEqual(@as(usize, 1), script.received(io));
}

test "close_connection is ConnectionLost; refuse_connections, then Unavailable until the script accepts; malformed is ProtocolViolation" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .close_connection, .refuse_connections, .{ .reply = Script.ok }, .{ .malformed = .truncated }, .{ .reply = Script.ok } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const client = fake.client();
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, count(client, io, .of(.root), &d));
    try testing.expectError(error.ConnectionLost, count(client, io, .of(.root), &d));
    try testing.expectError(error.Unavailable, count(client, io, .of(.root), &d));
    try testing.expectError(error.Unavailable, fake.connect(io, .root));
    try testing.expectEqual(@as(usize, 2), script.received(io));
    script.acceptConnections();
    try ok(try count(client, io, .of(.root), &d));
    try testing.expectError(error.ProtocolViolation, count(client, io, .of(.root), &d));
    try ok(try count(client, io, .of(.root), &d));
    const connections = [_]u32{ 1, 2, 3, 3, 4 };
    for (connections, 0..) |connection, i| try testing.expectEqual(connection, script.entry(io, i).connection);
}

/// Serves the cursor's commands, and holds `count` for 10 s.
const HoldCount = struct {
    cursor: *Script.Cursor,

    pub fn answer(self: *@This(), io: Io, arena: std.mem.Allocator, r: *const Script.Request) Script.HandlerError!Script.Answer {
        if (std.mem.eql(u8, r.name, "count")) return .{ .delayed = .{ .after = .fromSeconds(10), .reply = Script.ok } };
        return self.cursor.answer(io, arena, r);
    }
};

test "close ends a held call with ConnectionLost, kills open cursors, makes new calls Closed, and a second close does nothing" {
    const io = testing.io;
    const docs = [_]bson.RawDocument{ bson.literal(.{ .n = 0 }), bson.literal(.{ .n = 1 }) };
    var chunks: Script.Cursor = .{ .ns = "app.fs.chunks", .id = 21, .batches = &.{ docs[0..1], docs[1..2] } };
    var hold: HoldCount = .{ .cursor = &chunks };
    var script: Script = .init(testing.allocator, .init(&hold));
    defer script.deinit();
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var cursor = try fake.client().openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "fs.chunks" }) }, .{});
    defer cursor.deinit(io);

    var ended: Ended = .{};
    var task = try io.concurrent(countInTask, .{ io, fake.client(), &ended });
    defer task.cancel(io);
    try awaitReceived(io, &script, 2);
    const start = Io.Clock.awake.now(io);
    fake.close(io);
    task.await(io);
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(?mongo.Error, error.ConnectionLost), ended.err);
    try testing.expectEqual(@as(u32, 1), chunks.kills);
    try testing.expectError(error.Closed, count(fake.client(), io, .of(.root), null));
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));

    const received = script.received(io);
    fake.close(io);
    cursor.close(io);
    try testing.expectEqual(received, script.received(io));
}

test "capabilities: revision 1, named fake, the four of revision 1, and the server of the script's hello" {
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    script.hello.max_wire_version = 25;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    const caps = fake.client().capabilities();
    try testing.expectEqual(@as(u16, 1), caps.revision);
    try testing.expectEqualStrings("fake", caps.name);
    try testing.expect(caps.commands and caps.cursors and caps.aggregation and caps.batched_writes);
    try testing.expect(!caps.sessions and !caps.transactions and !caps.retryable_writes and !caps.read_preference);
    const server = caps.server.?;
    try testing.expectEqual(mongo.ServerKind.standalone, server.kind);
    try testing.expectEqual(@as(u32, 3), server.max_write_batch_size);
    try testing.expectEqual(@as(i32, 25), server.max_wire_version);
}
