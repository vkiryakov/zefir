//! Deadlines and cancellation, against `redis.testing.FakeServer`, whose
//! replies wait as long as a test says: what each call returns, whether
//! its command went out, and what a blocking command gave the server as its
//! timeout. Each test starts a server and a client of it, as
//! profiles_test.zig does.

const std = @import("std");
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const testing = std.testing;
const FakeServer = redis.testing.FakeServer;

/// A context whose deadline is `ms` milliseconds away.
fn within(io: std.Io, ms: i64) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromMilliseconds(ms)));
}

/// What the server answers LLEN with, two seconds late.
const three: FakeServer.Reply = .{ .integer = 3 };

test "a reply that comes after the deadline is Timeout: the command went out, and its connection closed" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "LLEN", "orders:paid" }, .{ .delayed = .{ .after = .fromSeconds(2), .reply = &three } }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    var d: redis.Diagnostics = .{};
    try testing.expectError(error.Timeout, client.run(io, .of(within(io, 200)), cmd.llen("orders:paid"), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    // The command went out, so the server may have run it.
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.Timeout));
    try testing.expectEqual(1, server.received(io));
    // Its reply may still come: the connection closed rather than go back
    // to the pool with it.
    try testing.expectEqual(0, client.stats().connections);
}

test "a deadline that has passed, or a canceled token, stops a call before anything goes out" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    try testing.expectError(error.DeadlineExceeded, client.run(io, .of(within(io, 0)), cmd.llen("orders:paid"), .{}));
    // The caller went away: whoever owns the token canceled it.
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.run(io, .of(core.Context.root.withCancellation(&token)), cmd.llen("orders:paid"), .{}));
    // Neither went out, so both are safe to make again.
    try testing.expectEqual(0, server.received(io));
    try testing.expectEqual(redis.Outcome.not_sent, redis.outcome(error.DeadlineExceeded));
    try testing.expectEqual(redis.Outcome.not_sent, redis.outcome(error.Cancelled));
}

/// Cancels `token` as the command comes, and answers it: the caller's
/// token is canceled while its call is out, as when the caller goes away
/// in the middle.
const CancelOnArrival = struct {
    token: *core.CancellationToken,

    pub fn answer(h: *CancelOnArrival, _: std.Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        h.token.cancel();
        return .{ .string = "order:1001" };
    }
};

test "a token canceled while the command is out does not drop its reply: LPOP has taken the order off the server" {
    const io = testing.io;
    var token: core.CancellationToken = .init;
    var canceler: CancelOnArrival = .{ .token = &token };
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&canceler) });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const op: redis.OperationContext = .of(core.Context.root.withCancellation(&token));
    const order = try client.run(io, op, cmd.lpop([]const u8, "orders:paid"), .{ .allocator = arena.allocator() });
    try testing.expectEqualStrings("order:1001", order.?);
    // The next call sees the token before it sends.
    try testing.expectError(error.Cancelled, client.run(io, op, cmd.lpop([]const u8, "orders:paid"), .{ .allocator = arena.allocator() }));
    try testing.expectEqual(1, server.received(io));
}

/// LLEN orders:paid, without a deadline of the context: the 5 s of
/// `Options.timeout`.
fn countPaid(io: std.Io, client: *redis.Client) redis.Error!u64 {
    return client.run(io, .of(.root), cmd.llen("orders:paid"), .{});
}

test "a task canceled while its command waits for the reply is Interrupted, and the connection closes" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "LLEN", "orders:paid" }, .{ .delayed = .{ .after = .fromSeconds(2), .reply = &three } }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    var call = try io.concurrent(countPaid, .{ io, &client });
    // Wait until the command is out, for 5 s at most.
    const give_up: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(5));
    while (server.received(io) == 0) {
        if (give_up.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Interrupted, call.cancel(io));
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.Interrupted));
    try testing.expectEqual(0, client.stats().connections);
}

/// Answers every command with null, as BLMOVE of an empty list answers
/// once its timeout is over.
const Empty = struct {
    pub fn answer(_: *Empty, _: std.Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        return .nil;
    }
};

test "a blocking command gives the server what the deadline leaves beyond 150 ms, or its own timeout when that is shorter" {
    const io = testing.io;
    var empty: Empty = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&empty) });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A second for the call; the command would wait for an order forever.
    const start = std.Io.Clock.awake.now(io);
    const order = try client.run(io, .of(within(io, 1000)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena.allocator() });
    try testing.expect(order == null);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    // BLMOVE orders:paid orders:packing LEFT RIGHT <seconds>: the deadline
    // less 150 ms, so 0.85 s at most, and less only by the time that passed
    // before the command went out.
    const sent = (try server.entry(io, 0)).args;
    try testing.expectEqualStrings("BLMOVE", sent[0]);
    const timeout_ms: i64 = @intFromFloat(@round(try std.fmt.parseFloat(f64, sent[5]) * 1000));
    try testing.expect(timeout_ms <= 850);
    try testing.expect(timeout_ms + elapsed + 1 >= 850);

    // Its own timeout, when the deadline leaves more: 300 ms.
    _ = try client.run(io, .of(within(io, 1000)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .{ .at_most = .fromMilliseconds(300) }), .{ .allocator = arena.allocator() });
    try testing.expectEqualStrings("0.3", (try server.entry(io, 1)).args[5]);
}

test "a blocking command with 150 ms or less left of its deadline is DeadlineExceeded, and nothing goes out" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var d: redis.Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, client.run(io, .of(within(io, 100)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena.allocator(), .diagnostics = &d }));
    // The text says why, and names the command that does not block.
    try testing.expect(std.mem.startsWith(u8, d.message(), "a blocking command needs more than 150 ms left of the deadline"));
    try testing.expect(std.mem.endsWith(u8, d.message(), "for a shorter wait, use redis.cmd.lmove"));
    try testing.expectEqual(0, server.received(io));
}
