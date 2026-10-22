//! Tests of `start` and `shutdown` of `redis.Client`, the methods that
//! zefir.App calls on a bean, against `redis.testing.FakeServer` and
//! `FakeServer.Peer` over loopback: `start` is `connect` within
//! `start_timeout`, with its errors, and `shutdown` is `close` that ends
//! the calls in flight 250 ms before the deadline at the latest. Every
//! test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Peer = FakeServer.Peer;
const time = @import("../engine/time.zig");
const within5s = @import("time_limit.zig").within5s;

/// A failed start logs a warning, and so does a refusal of the server:
/// the default runner would print them.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

/// The deadline of a stop `duration` from now, as zefir.App gives it.
fn stopIn(io: Io, duration: Io.Duration) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = duration, .clock = .awake });
}

test "start and shutdown have the forms of a bean that zefir.App starts and stops" {
    // `pub fn start(self: *T, io: std.Io) !void` and
    // `pub fn shutdown(self: *T, io: std.Io, deadline: std.Io.Clock.Timestamp) !void`.
    comptime {
        const start = @typeInfo(@TypeOf(Client.start)).@"fn";
        if (start.param_types.len != 2 or start.param_types[0] != *Client or start.param_types[1] != Io) @compileError("Client.start takes (*Client, std.Io)");
        if (start.return_type.? != redis.Error!void) @compileError("Client.start returns redis.Error!void");
        const shutdown = @typeInfo(@TypeOf(Client.shutdown)).@"fn";
        if (shutdown.param_types.len != 3 or shutdown.param_types[0] != *Client or shutdown.param_types[1] != Io or shutdown.param_types[2] != Io.Clock.Timestamp) {
            @compileError("Client.shutdown takes (*Client, std.Io, std.Io.Clock.Timestamp)");
        }
        const returned = @typeInfo(shutdown.return_type.?);
        if (returned != .error_union or returned.error_union.payload != void) @compileError("Client.shutdown returns !void");
    }
}

test "start connects within start_timeout, and a second start opens nothing" {
    try within5s(testing.io, starts, .{testing.io});
}

fn starts(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, .{ .string = "v" })});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.start(io);
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    try client.start(io);
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualDeep(@as(?[]const u8, "v"), try client.run(io, .of(.root), redis.cmd.get([]const u8, "k"), .{ .allocator = arena.allocator() }));
    try server.finish(io);
}

test "start fails as connect does: a wrong password is AuthenticationFailed, a port nobody listens on Unavailable, a server silent beyond start_timeout DeadlineExceeded" {
    try within5s(testing.io, startFails, .{testing.io});
}

fn startFails(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;

    var server: FakeServer = try .startWith(testing.allocator, io, .{ .hello = .{ .password = "secret" } });
    defer server.stop(io);
    var refused: Client = try .init(testing.allocator, io, .{ .url = server.url(), .password = "wrong" });
    defer refused.deinit();
    try testing.expectError(error.AuthenticationFailed, refused.start(io));

    var gone: Peer = try .listen(io);
    const url = try testing.allocator.dupe(u8, gone.url());
    defer testing.allocator.free(url);
    gone.close(io);
    var nobody: Client = try .init(testing.allocator, io, .{ .url = url });
    defer nobody.deinit();
    try testing.expectError(error.Unavailable, nobody.start(io));

    // A peer that takes the connection and never answers HELLO.
    var silent: Peer = try .listen(io);
    defer silent.close(io);
    var late: Client = try .init(testing.allocator, io, .{ .url = silent.url(), .start_timeout = .fromMilliseconds(100) });
    defer late.deinit();
    const start = time.now(io);
    try testing.expectError(error.DeadlineExceeded, late.start(io));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
}

test "a start_timeout under 1 ms is InvalidArgument at init" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, Client.init(testing.allocator, testing.io, .{ .url = "redis://127.0.0.1:6379", .start_timeout = .zero, .diagnostics = &d }));
    try testing.expectEqualStrings("start_timeout is under 1 ms: give it 1 ms or more", d.message());
    try testing.expectError(error.InvalidArgument, Client.init(testing.allocator, testing.io, .{ .url = "redis://127.0.0.1:6379", .start_timeout = .fromSeconds(-1), .diagnostics = &d }));
}

test "shutdown with nothing in flight returns at once, ends the subscribers as close does, and calls after it are Closed" {
    try within5s(testing.io, shutdownIdle, .{testing.io});
}

/// `sub.next` from a task of its own.
fn nextOf(sub: *redis.Subscriber, io: Io) redis.Error!?redis.Subscriber.Message {
    return sub.next(io);
}

fn shutdownIdle(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"}))});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.start(io);
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"} });
    defer sub.deinit();
    var reading = try io.concurrent(nextOf, .{ &sub, io });
    defer if (reading.cancel(io)) |_| {} else |_| {};
    try redis.testing.sleepAtLeast(io, .fromMilliseconds(50));
    const start = time.now(io);
    try client.shutdown(io, stopIn(io, .fromSeconds(10)));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 1000);
    try testing.expectEqual(@as(?redis.Subscriber.Message, null), try reading.await(io));
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
    var d: Diagnostics = .{};
    try testing.expectError(error.Closed, client.run(io, .of(.root), redis.cmd.ping(), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the client is closed", d.message());
}

const seven: FakeServer.Reply = .{ .integer = 7 };
const after2s: FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(2), .reply = &seven } };

/// A call whose reply the server holds back, which the shutdown cuts.
fn cutCall(io: Io, client: *Client) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, client.run(io, .of(.root), redis.cmd.raw(?i64, .{ "GET", "k" }), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("close() of the client cut the exchange", d.message());
}

fn awaitReceived(io: Io, server: *FakeServer, count: usize) !void {
    const give_up: core.Deadline = .after(time.now(io), .fromSeconds(4));
    while (server.received(io) != count) {
        if (time.expired(io, give_up)) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "shutdown gives a call in flight until 250 ms before its deadline, under a longer close_timeout, then cuts it, and returns no error" {
    try within5s(testing.io, shutdownCuts, .{testing.io});
}

fn shutdownCuts(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after2s)});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromSeconds(5) });
    defer client.deinit();
    try client.start(io);
    var call = try io.concurrent(cutCall, .{ io, &client });
    defer call.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    const start = time.now(io);
    try client.shutdown(io, stopIn(io, .fromMilliseconds(500)));
    const took = start.durationTo(time.now(io)).toMilliseconds();
    try call.await(io);
    // The wait ends at 250 ms; the reply would come at 2 s, and
    // close_timeout at 5 s.
    if (took < 200 or took >= 1000) {
        std.debug.print("shutdown with a deadline 500 ms away took {d} ms\n", .{took});
        return error.TestUnexpectedResult;
    }
}

test "shutdown with less than 250 ms left cuts a call in flight at once" {
    try within5s(testing.io, shutdownLate, .{testing.io});
}

fn shutdownLate(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{.expect(.{ "GET", "k" }, after2s)});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url(), .close_timeout = .fromSeconds(5) });
    defer client.deinit();
    try client.start(io);
    var call = try io.concurrent(cutCall, .{ io, &client });
    defer call.cancel(io) catch {};
    try awaitReceived(io, &server, 1);
    const start = time.now(io);
    try client.shutdown(io, stopIn(io, .fromMilliseconds(100)));
    // At once: neither the 2 s of the reply nor the 5 s of close_timeout.
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 500);
    try call.await(io);
}

test "shutdown after close does nothing, and returns no error" {
    try within5s(testing.io, shutdownAfterClose, .{testing.io});
}

fn shutdownAfterClose(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.start(io);
    client.close(io);
    const start = time.now(io);
    try client.shutdown(io, stopIn(io, .fromSeconds(10)));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() < 500);
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}
