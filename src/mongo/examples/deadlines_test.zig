//! Deadlines and cancellation, against a scripted server whose replies
//! wait as long as a test says: what each call returns, whether it went
//! out, and what it left for the server. Each test starts
//! `mongo.testing.FakeServer` and a client of it, as users_test.zig does.

const std = @import("std");
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const testing = std.testing;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;

/// A command of the shop: how many orders there are.
const count: mongo.Command = .{ .database = "shop", .body = bson.literal(.{ .count = "orders" }) };

/// A context whose deadline is `ms` milliseconds away.
fn within(io: std.Io, ms: i64) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromMilliseconds(ms)));
}

test "a reply that comes after the deadline is Timeout: the command went out, with maxTimeMS from the deadline" {
    const io = testing.io;
    // The server holds its reply for 2 s.
    var queue: Script.Queue = .{ .answers = &.{.{ .delayed = .{ .after = .fromSeconds(2), .reply = bson.literal(.{ .n = 3, .ok = 1.0 }) } }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Timeout, client.runCommand(io, .of(within(io, 200)), count, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    // The command went out, so the server may have run it.
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(error.Timeout));
    // With it went maxTimeMS, the time left: the server gives up then too.
    const sent = try script.entry(io, 0);
    const max_time_ms = try (try sent.body.get("maxTimeMS")).?.asI64();
    try testing.expect(max_time_ms >= 1 and max_time_ms <= 200);
}

test "a deadline that has passed, or a canceled token, stops a call before anything goes out" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);

    try testing.expectError(error.DeadlineExceeded, client.runCommand(io, .of(within(io, 0)), count, .{ .allocator = testing.allocator }));
    // The caller went away: whoever owns the token canceled it.
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.runCommand(io, .of(core.Context.root.withCancellation(&token)), count, .{ .allocator = testing.allocator }));
    // Neither went out, so both are safe to make again.
    try testing.expectEqual(@as(usize, 0), script.received(io));
    try testing.expectEqual(mongo.Outcome.not_sent, mongo.outcome(error.DeadlineExceeded));
    try testing.expectEqual(mongo.Outcome.not_sent, mongo.outcome(error.Cancelled));
}

/// Cancels `token` as the command comes, and answers it: the caller's
/// token is canceled while its call is out, as when the caller goes away
/// in the middle.
const CancelOnArrival = struct {
    token: *core.CancellationToken,

    pub fn answer(h: *CancelOnArrival, io: std.Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        _ = request;
        h.token.cancel();
        return .{ .reply = bson.literal(.{ .n = 3, .ok = 1.0 }) };
    }
};

test "a token canceled while the call is out is Interrupted: the server ran it, and the reply is dropped" {
    const io = testing.io;
    var token: core.CancellationToken = .init;
    var canceler: CancelOnArrival = .{ .token = &token };
    var script: Script = .init(testing.allocator, .init(&canceler));
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);

    try testing.expectError(error.Interrupted, client.runCommand(io, .of(core.Context.root.withCancellation(&token)), count, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(usize, 1), script.received(io));
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(error.Interrupted));
}

/// Runs `count` with `ms` milliseconds for it, and frees the reply.
fn countWithin(io: std.Io, client: *mongo.Client, ms: i64) mongo.Error!void {
    const reply = try client.runCommand(io, .of(within(io, ms)), count, .{ .allocator = testing.allocator });
    reply.deinit();
}

/// Waits until `client` has `n` connections in use, for 5 s at most.
fn awaitInUse(io: std.Io, client: *mongo.Client, n: usize) !void {
    const give_up: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(5));
    while (client.stats().in_use != n) {
        if (give_up.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a call that waits for a connection past its deadline is PoolExhausted, and never goes out" {
    const io = testing.io;
    // The server holds its reply for 1 s.
    var queue: Script.Queue = .{ .answers = &.{.{ .delayed = .{ .after = .fromSeconds(1), .reply = bson.literal(.{ .n = 3, .ok = 1.0 }) } }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    // A pool of one connection.
    var uri: [96]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&uri, "mongodb://127.0.0.1:{d}/?maxPoolSize=1", .{FakeServer.port(&listener)}) });
    defer client.deinit();
    try client.connect(io, .root, null);

    // A call takes the connection, and waits for the held reply.
    var first = try io.concurrent(countWithin, .{ io, &client, 10_000 });
    defer first.cancel(io) catch {};
    try awaitInUse(io, &client, 1);
    // The next one waits in line for it, until its deadline.
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.PoolExhausted, client.runCommand(io, .of(within(io, 100)), count, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(mongo.Outcome.not_sent, mongo.outcome(error.PoolExhausted));
    try first.await(io);
    // The server got the first call only.
    try testing.expectEqual(@as(usize, 1), script.received(io));
}
