//! Tests of `redis.Conn.transaction` against `redis.testing.FakeServer`
//! and `FakeServer.Peer` over loopback: MULTI on its own, the commands and
//! EXEC in one write, the QUEUED of each command, the replies of EXEC in
//! their places, null when a key under WATCH changed, EXECABORT with the
//! command the server refused, replies out of step, the token after MULTI,
//! and what each leaves of the WATCH of the Conn. Every test runs under a
//! time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const Peer = FakeServer.Peer;
const peers = @import("peers.zig");
const within5s = @import("time_limit.zig").within5s;

fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

fn connectionOf(io: Io, server: *FakeServer, i: usize) !u32 {
    return (try server.entry(io, i)).connection;
}

fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

const queued: FakeServer.Reply = .{ .raw = "+QUEUED\r\n" };
const get = cmd.raw(?i64, .{ "GET", "k" });
const incr_a = cmd.raw(i64, .{ "INCR", "a" });
const incr_b = cmd.raw(i64, .{ "INCR", "b" });

test "MULTI goes on its own, and the commands and EXEC in one write: the server reads them all before it answers any" {
    try within5s(testing.io, oneWrite, .{testing.io});
}

/// The server's side: MULTI, then both commands and EXEC before any
/// reply.
fn queueAll(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try peers.shakeHands(peer, io, .zero);
    try peers.expectCommand(peer, &.{"MULTI"});
    try peer.send("+OK\r\n");
    try peers.expectCommand(peer, &.{ "INCR", "a" });
    try peers.expectCommand(peer, &.{ "GET", "b" });
    try peers.expectCommand(peer, &.{"EXEC"});
    try peer.send("+QUEUED\r\n+QUEUED\r\n*2\r\n:1\r\n$1\r\nx\r\n");
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn oneWrite(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(queueAll, .{ &peer, io });
    defer server.cancel(io) catch {};
    {
        var client: Client = try .init(testing.allocator, io, .{ .url = peer.url() });
        defer client.deinit();
        try client.connect(io, .root, null);
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const r = (try conn.transaction(io, .of(.root), .{ incr_a, cmd.raw(?[]const u8, .{ "GET", "b" }) }, .{ .allocator = arena.allocator() })) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 1), try r[0]);
        try testing.expectEqualStrings("x", (try r[1]).?);
    }
    try server.await(io);
}

test "a server that refuses MULTI gets none of the commands: ServerError, with its code" {
    try within5s(testing.io, multiRefused, .{testing.io});
}

fn multiRefused(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .{ .err = "NOPERM User no-multi has no permissions to run the 'multi' command" }),
        .expect(.{ "GET", "k" }, .nil),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.transaction(io, .of(.root), .{ incr_a, incr_b }, .{ .diagnostics = &d }));
    try testing.expect(d.isCode("NOPERM"));
    try testing.expectEqual(@as(?usize, null), d.command);
    try testing.expectEqual(@as(?Diagnostics.Refused, null), d.refused());
    try testing.expectEqual(@as(usize, 1), server.received(io));
    // The connection stays, outside any transaction.
    try testing.expectEqual(@as(?i64, null), try conn.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 1));
    try server.finish(io);
}

test "a key under WATCH that changed gives null, for a tuple and for many commands of one type" {
    try within5s(testing.io, watchFired, .{testing.io});
}

fn watchFired(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{"EXEC"}, .nil),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{"EXEC"}, .nil),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    try testing.expect(try conn.transaction(io, .of(.root), .{incr_a}, .{}) == null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const both = [_]@TypeOf(incr_a){ incr_a, incr_a };
    try testing.expect(try conn.transaction(io, .of(.root), &both, .{ .allocator = arena.allocator() }) == null);
    const done = (try conn.transaction(io, .of(.root), &both, .{ .allocator = arena.allocator() })) orelse return error.TestUnexpectedResult;
    comptime std.debug.assert(@TypeOf(done) == []const (redis.CommandError!i64));
    try testing.expectEqual(@as(i64, 1), try done[0]);
    try testing.expectEqual(@as(i64, 2), try done[1]);
    try server.finish(io);
}

test "an error of one command inside EXEC is the value in its place, and the others ran" {
    try within5s(testing.io, errorInExec, .{testing.io});
}

fn errorInExec(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "b" }, queued),
        .expect(.{ "GET", "k" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{
            .{ .integer = 1 },
            .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" },
            .{ .string = "3" },
        } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    const r = (try conn.transaction(io, .of(.root), .{ incr_a, incr_b, get }, .{ .diagnostics = &d })) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), try r[0]);
    try testing.expectError(error.ServerError, r[1]);
    try testing.expectEqual(@as(?i64, 3), try r[2]);
    try testing.expectEqual(@as(?usize, 1), d.command);
    try testing.expect(d.isCode("WRONGTYPE"));
    try server.finish(io);
}

test "EXECABORT after a refused command is ServerError EXECABORT, with that command and its own error in refused()" {
    try within5s(testing.io, refusedWhileQueued, .{testing.io});
}

const unknown = "ERR unknown command 'FOO', with args beginning with: ";
const previous = "EXECABORT Transaction discarded because of previous errors.";

fn refusedWhileQueued(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "SET", "k", "v" }, queued),
        .expect(.{"FOO"}, .{ .err = unknown }),
        .expect(.{"EXEC"}, .{ .err = previous }),
        .expect(.{ "GET", "k" }, .nil),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.transaction(io, .of(.root), .{ cmd.raw(void, .{ "SET", "k", "v" }), cmd.raw(void, .{"FOO"}) }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("EXECABORT", d.code());
    try testing.expectEqualStrings(previous, d.message());
    try testing.expectEqual(@as(?usize, 1), d.command);
    const refused = d.refused() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ERR", refused.code);
    try testing.expectEqualStrings(unknown, refused.message);
    // The connection stays, outside any transaction.
    try testing.expectEqual(@as(?i64, null), try conn.run(io, .of(.root), get, .{}));
    try server.finish(io);
}

test "EXECABORT of a check of EXEC itself is ServerError EXECABORT, with no command and no refused()" {
    try within5s(testing.io, execRefused, .{testing.io});
}

fn execRefused(io: Io) !void {
    const readonly = "EXECABORT Transaction discarded because of: READONLY You can't write against a read only replica.";
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{"EXEC"}, .{ .err = readonly }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.ServerError, conn.transaction(io, .of(.root), .{incr_a}, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("EXECABORT", d.code());
    try testing.expectEqualStrings(readonly, d.message());
    try testing.expectEqual(@as(?usize, null), d.command);
    try testing.expectEqual(@as(?Diagnostics.Refused, null), d.refused());
    try server.finish(io);
}

test "a QUEUED where the array of EXEC was due, or an array of 3 for 2 commands, is ProtocolViolation, and the Conn is then Closed" {
    try within5s(testing.io, outOfStep, .{testing.io});
}

fn outOfStep(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "b" }, queued),
        .expect(.{"EXEC"}, queued),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "b" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    for ([_][]const u8{
        "EXEC was answered with a simple string of 6 bytes, where an array of 2 replies was due",
        "EXEC was answered with an array of 3 elements, where an array of 2 replies was due",
    }) |message| {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try testing.expectError(error.ProtocolViolation, conn.transaction(io, .of(.root), .{ incr_a, incr_b }, .{ .diagnostics = &d }));
        try testing.expectEqualStrings(message, d.message());
        try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{}));
    }
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
    try server.finish(io);
}

test "a token canceled after MULTI stops the transaction before the commands go out: Cancelled, and the connection closes" {
    try within5s(testing.io, canceledAfterMulti, .{testing.io});
}

/// Cancels the token as it answers MULTI.
const CancelOnMulti = struct {
    token: core.CancellationToken = .init,

    pub fn answer(self: *CancelOnMulti, _: Io, _: std.mem.Allocator, request: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        if (!std.ascii.eqlIgnoreCase(request.args[0], "MULTI")) return .{ .err = "ERR only MULTI is expected" };
        self.token.cancel();
        return .ok;
    }
};

fn canceledAfterMulti(io: Io) !void {
    var handler: CancelOnMulti = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&handler) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    const op: redis.OperationContext = .of(core.Context.root.withCancellation(&handler.token));
    try testing.expectError(error.Cancelled, conn.transaction(io, op, .{ incr_a, incr_b }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the token was canceled before the command went out", d.message());
    try testing.expectEqual(@as(usize, 1), server.received(io));
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{}));
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}

test "a connection cut after two QUEUED is ConnectionLost, with answered 3: MULTI and the two" {
    try within5s(testing.io, cutAfterQueued, .{testing.io});
}

fn cutAfterQueued(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{ "INCR", "b" }, queued),
        .expect(.{"EXEC"}, .close_connection),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, conn.transaction(io, .of(.root), .{ incr_a, incr_b }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 3), d.answered);
    try testing.expectEqual(@as(?Diagnostics.Refused, null), d.refused());
    try testing.expectError(error.Closed, conn.run(io, .of(.root), get, .{}));
    try server.finish(io);
}

test "a WATCH stays until EXEC goes out: after a refused MULTI or a bad command release closes the connection, after EXEC it keeps it" {
    try within5s(testing.io, watchUntilExec, .{testing.io});
}

fn watchUntilExec(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "WATCH", "k" }, .ok),
        .expect(.{"MULTI"}, .{ .err = "NOPERM User no-multi has no permissions to run the 'multi' command" }),
        .expect(.{ "WATCH", "k" }, .ok),
        .expect(.{ "WATCH", "k" }, .ok),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "INCR", "a" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{.{ .integer = 1 }} }),
        .expect(.{ "GET", "k" }, .{ .integer = 5 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try conn.run(io, .of(.root), cmd.watch(&.{"k"}), .{});
        try testing.expectError(error.ServerError, conn.transaction(io, .of(.root), .{incr_a}, .{}));
    }
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try conn.run(io, .of(.root), cmd.watch(&.{"k"}), .{});
        try testing.expectError(error.InvalidArgument, conn.transaction(io, .of(.root), .{ incr_a, cmd.raw(i64, .{ "ZADD", "z", std.math.nan(f64), "m" }) }, .{}));
        try testing.expectEqual(@as(usize, 3), server.received(io));
    }
    {
        var conn = try client.acquire(io, .of(.root));
        defer conn.release(io);
        try conn.run(io, .of(.root), cmd.watch(&.{"k"}), .{});
        _ = (try conn.transaction(io, .of(.root), .{incr_a}, .{})) orelse return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(?i64, 5), try client.run(io, .of(.root), get, .{}));
    const expected = [_]u32{ 1, 1, 2, 3, 3, 3, 3, 3 };
    for (expected, 0..) |connection, i| try testing.expectEqual(connection, try connectionOf(io, &server, i));
    try testing.expectEqual(@as(usize, 1), client.stats().connections);
    try server.finish(io);
}
