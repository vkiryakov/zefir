//! Closing a client while 1,000 operations are in flight, in three rounds,
//! each on a fresh client of mongo-plain:
//!
//! - cut: 1,000 calls sleep on as many connections, and `close` cuts them
//!   all at close_timeout: each ends with ConnectionLost;
//! - drain: on a pool of 100, the 100 calls on connections end well within
//!   close_timeout, the 850 waiting in line get Closed at once, and the 50
//!   cursors that mongod holds get killCursors: mongod holds none of them
//!   once `close` returns, and their `next` is Closed;
//! - cut again, as the first.
//!
//! In each, `close` returns in time, every call returns right after it,
//! and all of the client's memory comes back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("e2e");
const stress = @import("root.zig");

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

/// `sleep`, a test command of mongo-plain, without a lock: the call holds
/// its connection for `millis`.
fn sleepFor(comptime millis: i32) mongo.Command {
    return .{ .database = "admin", .body = bson.literal(.{ .sleep = 1, .millis = millis, .lock = "none" }) };
}

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// Calls that run in tasks of a group: each counts what it got against
/// what it expected.
const Calls = struct {
    c: *mongo.Client,
    /// Null: success.
    expected: ?mongo.Error = null,
    message: []const u8 = "",
    done: std.atomic.Value(usize) = .init(0),
    unexpected: std.atomic.Value(u32) = .init(0),

    fn run(calls: *Calls, io: Io, command: mongo.Command) Io.Cancelable!void {
        defer _ = calls.done.fetchAdd(1, .acq_rel);
        var d: mongo.Diagnostics = .{};
        const result = calls.c.runCommand(io, within(io, .fromSeconds(60)), command, .{ .allocator = testing.allocator, .diagnostics = &d });
        if (result) |reply| {
            reply.deinit();
            if (calls.expected == null) return;
        } else |err| if (calls.expected) |expected| {
            if (err == expected and std.mem.eql(u8, calls.message, d.message())) return;
        }
        if (calls.unexpected.fetchAdd(1, .monotonic) != 0) return;
        if (result) |_| std.debug.print("  a call: ok, and an error was expected\n", .{}) else |err| std.debug.print("  a call: {t}: {s}\n", .{ err, d.message() });
    }
};

/// A client of mongo-plain for a round, connected, whose memory `counting`
/// counts.
fn connected(io: Io, client: *mongo.Client, counting: *stress.CountingAllocator, max_pool_size: u32, close_timeout: Io.Duration) !void {
    var buffer: [128]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}/?appName=zefir-stress-close&maxPoolSize={d}", .{ e2e.servers.plain_port, max_pool_size });
    client.* = try .init(counting.allocator(), io, .{ .uri = uri, .close_timeout = close_timeout });
    errdefer client.deinit();
    var d: mongo.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
        std.debug.print("  connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// Waits until `field` of the client's stats is `value`, for `limit` at
/// most.
fn awaitStats(io: Io, client: *mongo.Client, comptime field: []const u8, value: usize, limit: Io.Duration) !void {
    const began = Io.Clock.awake.now(io);
    while (@field(client.stats(), field) != value) {
        if (stress.elapsedSince(io, began).nanoseconds >= limit.nanoseconds) {
            std.debug.print("  {s} is {d}, not {d}, after {d} ms\n", .{ field, @field(client.stats(), field), value, limit.toMilliseconds() });
            return error.TestTimedOut;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

const close_cut_timeout: Io.Duration = .fromMilliseconds(300);

/// 1,000 calls on as many connections, cut by `close` at close_timeout.
fn cutRound(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var client: mongo.Client = undefined;
    try connected(io, &client, &counting, 1000, close_cut_timeout);
    {
        defer client.deinit();
        var out: Calls = .{ .c = &client, .expected = error.ConnectionLost, .message = "close() of the client cut the exchange" };
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (0..1000) |_| try group.concurrent(io, Calls.run, .{ &out, io, sleepFor(3000) });
        // The pool opens two connections at a time.
        try awaitStats(io, &client, "in_use", 1000, .fromSeconds(60));
        const stopping = Io.Clock.awake.now(io);
        client.close(io);
        const took = stress.elapsedSince(io, stopping);
        // Every call has left the client once close returns, and returns
        // right after.
        try stress.awaitCount(io, &out.done, 1000, .fromSeconds(1));
        try group.await(io);
        std.debug.print("  cut: close ended 1,000 calls on 1,000 connections in {d} ms (close_timeout {d} ms); client heap at most {d} KiB\n", .{ took.toMilliseconds(), close_cut_timeout.toMilliseconds(), counting.peak.load(.monotonic) / 1024 });
        try testing.expectEqual(@as(u32, 0), out.unexpected.load(.monotonic));
        try testing.expect(took.nanoseconds >= close_cut_timeout.nanoseconds);
        try testing.expect(took.toMilliseconds() < close_cut_timeout.toMilliseconds() + 2000);
        try testing.expectEqual(@as(usize, 0), client.stats().connections);
    }
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

const cursor_ns_collection = "close_cursors";
const cursor_count = 50;
const cursor_docs = 1000;
const cursor_batch = 10;

/// 100 calls on a pool of 100 that end within close_timeout, 850 in line,
/// and 50 cursors open on the server.
fn drainRound(io: Io) !void {
    var watch: mongo.Client = undefined;
    var watch_counting: stress.CountingAllocator = .{ .child = testing.allocator };
    try connected(io, &watch, &watch_counting, 1, .fromSeconds(5));
    defer watch.deinit();
    var watch_ids: bson.ObjectId.Generator = .init(io);
    const watch_db: mongo.Database = .init(&watch, "zefir_stress", &watch_ids);
    try watch_db.drop(io, within(io, .fromSeconds(10)), .{ .allocator = testing.allocator });
    defer watch_db.drop(io, within(io, .fromSeconds(10)), .{ .allocator = testing.allocator }) catch {};
    try fill(io, watch_db);

    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var client: mongo.Client = undefined;
    try connected(io, &client, &counting, 100, .fromSeconds(5));
    {
        defer client.deinit();
        var ids: bson.ObjectId.Generator = .init(io);
        const db: mongo.Database = .init(&client, "zefir_stress", &ids);
        // 50 cursors, each with the rest of its documents on the server.
        var cursors: [cursor_count]mongo.Cursor = undefined;
        var opened: usize = 0;
        defer for (cursors[0..opened]) |cursor| cursor.deinit(io);
        for (&cursors) |*cursor| {
            const op = within(io, .fromSeconds(10));
            cursor.* = try db.collection(cursor_ns_collection).find(io, op, .{}, .{ .allocator = testing.allocator, .batch_size = cursor_batch });
            opened += 1;
            for (0..cursor_batch) |_| _ = (try cursor.next(io, op)) orelse return error.TestCursorEnded;
        }
        try testing.expectEqual(@as(usize, cursor_count), client.stats().open_cursors);
        try testing.expectEqual(@as(u64, cursor_count), try idleCursors(io, &watch));

        var out: Calls = .{ .c = &client };
        var flying: Io.Group = .init;
        defer flying.cancel(io);
        for (0..100) |_| try flying.concurrent(io, Calls.run, .{ &out, io, sleepFor(2000) });
        try awaitStats(io, &client, "in_use", 100, .fromSeconds(30));
        var in_line: Calls = .{ .c = &client, .expected = error.Closed, .message = "the client was closed while the call waited for a connection" };
        var waiting: Io.Group = .init;
        defer waiting.cancel(io);
        for (0..850) |_| try waiting.concurrent(io, Calls.run, .{ &in_line, io, ping });
        try awaitStats(io, &client, "waiting", 850, .fromSeconds(30));
        const stopping = Io.Clock.awake.now(io);
        client.close(io);
        const took = stress.elapsedSince(io, stopping);
        try stress.awaitCount(io, &out.done, 100, .fromSeconds(1));
        try stress.awaitCount(io, &in_line.done, 850, .fromSeconds(1));
        try flying.await(io);
        try waiting.await(io);
        std.debug.print("  drain: close let 100 calls end, sent 850 in line away and killed 50 cursors in {d} ms; client heap at most {d} KiB\n", .{ took.toMilliseconds(), counting.peak.load(.monotonic) / 1024 });
        try testing.expectEqual(@as(u32, 0), out.unexpected.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), in_line.unexpected.load(.monotonic));
        // The calls out slept 2 s, and close waited for them.
        try testing.expect(took.toMilliseconds() < 2000 + 1500);
        const stats = client.stats();
        try testing.expectEqual(@as(usize, 0), stats.connections + stats.open_cursors);
        try testing.expectEqual(@as(u64, 0), try idleCursors(io, &watch));
        for (cursors) |cursor| try testing.expectError(error.Closed, cursor.next(io, within(io, .fromSeconds(10))));
    }
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

/// The cursors that mongod holds on the collection of the cursors, idle
/// between their batches, by `$currentOp`.
fn idleCursors(io: Io, watch: *mongo.Client) !u64 {
    const reply = try watch.runCommand(io, within(io, .fromSeconds(10)), .{ .database = "admin", .body = bson.literal(.{
        .aggregate = 1,
        .pipeline = .{
            .{ .@"$currentOp" = .{ .idleCursors = true, .allUsers = true } },
            .{ .@"$match" = .{ .type = "idleCursor", .ns = "zefir_stress." ++ cursor_ns_collection } },
            .{ .@"$count" = "n" },
        },
        .cursor = .{},
    }) }, .{ .allocator = testing.allocator });
    defer reply.deinit();
    const batch = (try reply.raw().getPath("cursor.firstBatch")) orelse return error.TestNoBatch;
    if (batch != .array) return error.TestNoBatch;
    const first = (try batch.array.first()) orelse return 0;
    if (first.value != .document) return error.TestNoBatch;
    const n = (try first.value.document.get("n")) orelse return error.TestNoBatch;
    return @intCast(try n.asI64());
}

/// The collection of the cursors: `cursor_docs` documents.
fn fill(io: Io, db: mongo.Database) !void {
    const Doc = struct { _id: i64 };
    var docs: [cursor_docs]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ ._id = @intCast(i) };
    var result = try db.collection(cursor_ns_collection).insertMany(io, within(io, .fromSeconds(10)), @as([]const Doc, &docs), .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, cursor_docs), result.inserted);
}

fn rounds(io: Io) !void {
    try cutRound(io);
    try drainRound(io);
    try cutRound(io);
}

test "close with 1,000 operations in flight, three rounds: it cuts 1,000 calls on as many connections at close_timeout; it lets 100 calls end, sends 850 in line away and kills 50 cursors; and again the first" {
    try stress.onZio(rounds);
}
