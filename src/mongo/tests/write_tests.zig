//! Tests of the batched writes of the driver against
//! `mongo.testing.FakeServer` over loopback: batches by the limits of
//! hello, one deadline for all of them, a connection of the pool for each,
//! and how a write that stops after batches the server answered is
//! `IncompleteWrite`. Every test runs under a time limit of 5 s.

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

/// Ten documents, `{_id: 0}` to `{_id: 9}`.
const ten = ten: {
    var items: [10]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = bson.literal(.{ ._id = @as(i32, i) });
    break :ten items;
};

const three = bson.literal(.{ .n = 3, .ok = 1.0 });
const one = bson.literal(.{ .n = 1, .ok = 1.0 });
const insert = bson.literal(.{ .insert = "users" });

/// Answers the writes with `queue`, and holds `hold` for 3 s.
const Writes = struct {
    queue: Script.Queue,

    pub fn answer(w: *Writes, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (std.mem.eql(u8, request.name, "hold")) return .{ .delayed = .{ .after = .fromSeconds(3), .reply = Script.ok } };
        return w.queue.answer(io, arena, request);
    }
};

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    writes: Writes,
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [96]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io, answers: []const Script.Answer, hello: mongo.wire.Hello) !void {
        s.* = .{ .writes = .{ .queue = .{ .answers = answers } }, .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.writes));
        s.script.hello = hello;
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

    /// `driver`, a client of the server with `query`, connected where it
    /// is.
    fn connect(s: *Served, io: Io, driver: *Client, query: []const u8) !void {
        const uri = try std.fmt.bufPrint(&s.buffer, "mongodb://127.0.0.1:{d}/{s}", .{ FakeServer.port(&s.listener), query });
        driver.* = try .init(testing.allocator, io, .{ .uri = uri });
        errdefer driver.deinit();
        try driver.connect(io, .root, null);
    }
};

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn awaitReceived(io: Io, script: *Script, name: []const u8, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (script.count(io, name) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitWaiting(io: Io, driver: *Client, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (driver.stats().waiting != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a write goes in batches by maxWriteBatchSize, in sections of kind 1 with ordered and $db, and its maxTimeMS counts to one deadline for all the batches" {
    try within5s(testing.io, batches, .{testing.io});
}

fn batches(io: Io) !void {
    var served: Served = undefined;
    const answers = [_]Script.Answer{ .{ .delayed = .{ .after = .fromMilliseconds(150), .reply = three } }, .{ .reply = three }, .{ .reply = three }, .{ .reply = one } };
    try served.start(io, &answers, .{ .max_write_batch_size = 3 });
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var result = try driver.write(io, within(io, .fromMilliseconds(4000)), .{ .database = "app", .kind = .insert, .body = insert, .items = &ten }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 10), result.n);
    try testing.expectEqual(@as(usize, 10), result.answered);

    const script = &served.script;
    try testing.expectEqual(@as(usize, 4), script.count(io, "insert"));
    var at: usize = 0;
    var budgets: [4]i64 = undefined;
    for ([_]usize{ 3, 3, 3, 1 }, 0..) |size, i| {
        const entry = script.entry(io, i);
        const sequence = entry.sequence.?;
        try testing.expectEqualStrings("documents", sequence.identifier);
        var items = sequence.documents();
        var n: usize = 0;
        while (items.next()) |doc| : (n += 1) try testing.expectEqualSlices(u8, ten[at + n].bytes, doc.bytes);
        try testing.expectEqual(size, n);
        at += n;
        budgets[i] = (try entry.body.get("maxTimeMS")).?.int64;
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        try b.putString("insert", "users");
        try b.putBoolean("ordered", true);
        try b.putInt64("maxTimeMS", budgets[i]);
        try b.putString("$db", "app");
        const expected = try b.finish();
        defer expected.deinit();
        try testing.expectEqualSlices(u8, expected.bytes, entry.body.bytes);
    }
    // The first batch took 150 ms of the deadline from the others.
    try testing.expect(budgets[0] <= 4000 and budgets[1] <= budgets[0] - 140);
    try testing.expect(budgets[3] <= budgets[2] and budgets[2] <= budgets[1]);
}

test "an item that no message holds alone is InvalidArgument before any batch goes; one larger than maxBsonObjectSize within a message goes" {
    try within5s(testing.io, sizes, .{testing.io});
}

fn sizes(io: Io) !void {
    var served: Served = undefined;
    const answers = [_]Script.Answer{.{ .reply = one }};
    try served.start(io, &answers, .{ .max_message_size_bytes = 2048, .max_bson_object_size = 512 });
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pad = try arena.allocator().alloc(u8, 2100);
    @memset(pad, 'p');
    const huge = try bson.encode(arena.allocator(), .{ ._id = 1, .pad = pad }, .{});
    const large = try bson.encode(arena.allocator(), .{ ._id = 2, .pad = pad[0..700] }, .{});
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, driver.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = insert, .items = &.{ ten[0], huge.raw() } }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "item 1 of the write is "));
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
    var result = try driver.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = insert, .items = &.{large.raw()} }, .{ .allocator = testing.allocator });
    result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), served.script.count(io, "insert"));
}

test "a write cut at its third batch is IncompleteWrite for ConnectionLost, with batch_offset 6 and the two batches before in partial" {
    try within5s(testing.io, cutAtThird, .{testing.io});
}

fn cutAtThird(io: Io) !void {
    var served: Served = undefined;
    const answers = [_]Script.Answer{ .{ .reply = three }, .{ .reply = three }, .close_connection };
    try served.start(io, &answers, .{ .max_write_batch_size = 3 });
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    try testing.expectError(error.IncompleteWrite, driver.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = insert, .items = &ten }, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    try testing.expectEqual(mongo.Error.ConnectionLost, d.reason.?);
    try testing.expectEqual(@as(usize, 6), d.batch_offset.?);
    try testing.expectEqual(@as(u64, 6), partial.n);
    try testing.expectEqual(@as(usize, 6), partial.answered);
    try testing.expectEqual(@as(usize, 3), served.script.count(io, "insert"));
}

test "a token canceled while the second batch is out stops the write before the third: IncompleteWrite for Cancelled; canceled before the first, the write is Cancelled" {
    try within5s(testing.io, tokenCanceled, .{testing.io});
}

/// Answers each batch with `{n: 3}`, and cancels `token` at the second.
const Canceler = struct {
    token: core.CancellationToken = .init,
    batches: std.atomic.Value(u32) = .init(0),

    pub fn answer(c: *Canceler, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ io, arena, request };
        if (c.batches.fetchAdd(1, .monotonic) == 1) c.token.cancel();
        return .{ .reply = three };
    }
};

fn tokenCanceled(io: Io) !void {
    var canceler: Canceler = .{};
    var script: Script = .init(testing.allocator, .init(&canceler));
    defer script.deinit();
    script.hello = .{ .max_write_batch_size = 3 };
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var buffer: [64]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    var d: Diagnostics = .{};
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    const request: mongo.WriteRequest = .{ .database = "app", .kind = .insert, .body = insert, .items = &ten };
    try testing.expectError(error.IncompleteWrite, driver.write(io, .of(core.Context.root.withCancellation(&canceler.token)), request, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    try testing.expectEqual(mongo.Error.Cancelled, d.reason.?);
    try testing.expectEqual(@as(usize, 6), d.batch_offset.?);
    try testing.expectEqual(@as(u64, 6), partial.n);
    try testing.expectEqual(@as(usize, 2), script.count(io, "insert"));
    try testing.expectError(error.Cancelled, driver.write(io, .of(core.Context.root.withCancellation(&canceler.token)), request, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(usize, 2), script.count(io, "insert"));
}

test "every batch takes a connection of the pool: one that a call took meanwhile leaves the third batch in line, PoolExhausted at the deadline, and the write IncompleteWrite for it" {
    try within5s(testing.io, batchInLine, .{testing.io});
}

fn hold(io: Io, driver: *Client) void {
    const reply = driver.runCommand(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .hold = 1 }) }, .{ .allocator = testing.allocator }) catch return;
    reply.deinit();
}

fn batchInLine(io: Io) !void {
    var served: Served = undefined;
    const answers = [_]Script.Answer{ .{ .reply = three }, .{ .delayed = .{ .after = .fromMilliseconds(300), .reply = three } }, .{ .reply = three }, .{ .reply = one } };
    try served.start(io, &answers, .{ .max_write_batch_size = 3 });
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "?maxPoolSize=1");
    defer driver.deinit();
    var d: Diagnostics = .{};
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    var holder: ?Io.Future(void) = null;
    defer if (holder) |*h| h.cancel(io);
    const Writer = struct {
        fn run(task_io: Io, c: *mongo.Client, diagnostics: *Diagnostics, result: *mongo.WriteResult) mongo.Error!void {
            var written = try c.write(task_io, within(task_io, .fromMilliseconds(1500)), .{ .database = "app", .kind = .insert, .body = insert, .items = &ten }, .{ .allocator = testing.allocator, .diagnostics = diagnostics, .partial = result });
            written.deinit(testing.allocator);
        }
    };
    var writing = try io.concurrent(Writer.run, .{ io, &driver, &d, &partial });
    // While the second batch is out, a call joins the line for the only
    // connection, and takes it when the batch comes back.
    try awaitReceived(io, &served.script, "insert", 2);
    holder = try io.concurrent(hold, .{ io, &driver });
    try awaitWaiting(io, &driver, 1);
    try testing.expectError(error.IncompleteWrite, writing.await(io));
    try testing.expectEqual(mongo.Error.PoolExhausted, d.reason.?);
    try testing.expectEqual(mongo.Outcome.not_sent, mongo.outcome(d.reason.?));
    try testing.expectEqual(@as(usize, 6), d.batch_offset.?);
    try testing.expectEqual(@as(u64, 6), partial.n);
    try testing.expectEqual(@as(usize, 2), served.script.count(io, "insert"));
}

test "code 50 among the writeErrors is Timeout, with its batch merged into partial" {
    try within5s(testing.io, expiredItem, .{testing.io});
}

fn expiredItem(io: Io) !void {
    var served: Served = undefined;
    const expired = bson.literal(.{ .n = 2, .writeErrors = .{.{ .index = 2, .code = 50, .codeName = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" }}, .ok = 1.0 });
    const answers = [_]Script.Answer{.{ .reply = expired }};
    try served.start(io, &answers, .{});
    defer served.stop(io);
    var driver: Client = undefined;
    try served.connect(io, &driver, "");
    defer driver.deinit();
    var d: Diagnostics = .{};
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    try testing.expectError(error.Timeout, driver.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = insert, .items = ten[0..3] }, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    try testing.expectEqual(@as(i32, 50), d.server.?.code);
    try testing.expectEqualStrings("operation exceeded time limit", d.message());
    try testing.expectEqual(@as(u64, 2), partial.n);
    try testing.expectEqual(@as(usize, 1), partial.write_errors.len);
    try testing.expectEqual(@as(usize, 2), partial.write_errors[0].index);
}
