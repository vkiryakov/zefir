//! Protocol tests of `engine/Connection.zig`: one connection against the
//! server's side played by the test, `redis.testing.FakeServer.Peer`, over
//! loopback, with commands of `cmd.raw`. Every test runs under a time
//! limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Diagnostics = redis.Diagnostics;
const Peer = redis.testing.FakeServer.Peer;
const Connection = @import("../engine/Connection.zig");
const time = @import("../engine/time.zig");
const WindowsLike = @import("windows_like_io.zig").WindowsLike;
const within5s = @import("time_limit.zig").within5s;

/// A connection and the server's side of it. It points into itself: open
/// it in place.
const Pair = struct {
    peer: Peer,
    conn: *Connection,
    /// The peer's port, which stays known after the peer closes.
    listening: u16,

    fn open(p: *Pair, io: Io, max_reply_bytes: usize) !void {
        p.peer = try .listen(io);
        errdefer p.peer.close(io);
        p.listening = p.peer.listener.?.socket.address.getPort();
        const address: net.IpAddress = try .parseIp4("127.0.0.1", p.listening);
        // The system completes the connection before the listener accepts.
        const stream = try address.connect(io, .{ .mode = .stream });
        p.conn = Connection.create(testing.allocator, io, stream, .{ .host = "127.0.0.1", .port = p.listening }, max_reply_bytes) catch |err| {
            stream.close(io);
            return err;
        };
        errdefer p.conn.destroy();
        try p.peer.accept(io);
    }

    fn port(p: *const Pair) u16 {
        return p.listening;
    }

    fn close(p: *Pair, io: Io) void {
        p.conn.destroy();
        p.peer.close(io);
    }
};

/// Room for any reply of these tests.
const roomy = 1 << 20;

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, arg| try testing.expectEqualStrings(want, arg);
}

/// Reads `commands`, one after another, and answers them all with
/// `replies` once the last has come.
fn answerAll(peer: *Peer, commands: []const []const []const u8, replies: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (commands) |expected| {
        const got = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
        try expectArgs(expected, got);
    }
    try peer.send(replies);
}

/// Reads one command and leaves it unanswered.
fn swallow(peer: *Peer) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
}

fn swallowAndClose(peer: *Peer, io: Io) !void {
    try swallow(peer);
    peer.close(io);
}

fn deadline5s(io: Io) core.Deadline {
    return .after(time.now(io), .fromSeconds(5));
}

test "commands go out together at the flush and nothing before it, and each reply comes back in order through the decoder" {
    try within5s(testing.io, flushOnce, .{testing.io});
}

/// Reads two commands, saying when the first has come.
fn hearTwo(peer: *Peer, heard: *std.atomic.Value(bool)) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectArgs(&.{ "GET", "a" }, (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult);
    heard.store(true, .release);
    try expectArgs(&.{ "INCR", "n" }, (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult);
    try peer.send("$3\r\nAnn\r\n:7\r\n");
}

fn flushOnce(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostics = .{};
    const get = cmd.raw(?[]const u8, .{ "GET", "a" });
    const incr = cmd.raw(i64, .{ "INCR", "n" });
    p.conn.begin(deadline5s(io));
    try p.conn.write(get, &d);
    try p.conn.write(incr, &d);
    var heard: std.atomic.Value(bool) = .init(false);
    var server = try io.concurrent(hearTwo, .{ &p.peer, &heard });
    defer server.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(50), .awake);
    try testing.expect(!heard.load(.acquire));
    try p.conn.flush(&d);
    try testing.expectEqualDeep(@as(?[]const u8, "Ann"), try p.conn.receive(get, arena.allocator(), &d));
    try testing.expectEqual(@as(i64, 7), try p.conn.receive(incr, null, &d));
    try server.await(io);
    try testing.expect(p.conn.usable);
}

test "UnexpectedReply and ServerError leave the connection usable, and the next exchange reads its own reply" {
    try within5s(testing.io, softErrors, .{testing.io});
}

/// Runs `command` on `p.conn` while the peer reads `commands` and answers
/// with `replies`, all of them static.
fn exchangeWith(io: Io, p: *Pair, comptime commands: []const []const []const u8, comptime replies: []const u8, command: anytype, d: *Diagnostics) !@TypeOf(command).Reply {
    var server = try io.concurrent(answerAll, .{ &p.peer, commands, replies });
    defer server.cancel(io) catch {};
    const result = p.conn.exchange(command, null, deadline5s(io), d);
    try server.await(io);
    return result;
}

fn softErrors(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var d: Diagnostics = .{};

    try testing.expectError(error.UnexpectedReply, exchangeWith(io, &p, &.{&.{ "GET", "k" }}, "$3\r\nabc\r\n", cmd.raw(i64, .{ "GET", "k" }), &d));
    try testing.expect(p.conn.usable);
    try testing.expectEqualStrings("the reply is a bulk string of 3 bytes, and the call asked for i64", d.message());

    d = .{};
    try testing.expectError(error.ServerError, exchangeWith(io, &p, &.{&.{ "INCR", "k" }}, "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n", cmd.raw(i64, .{ "INCR", "k" }), &d));
    try testing.expect(p.conn.usable);
    try testing.expect(d.isCode("WRONGTYPE"));

    try exchangeWith(io, &p, &.{&.{ "SET", "k", "v" }}, "+OK\r\n", cmd.raw(void, .{ "SET", "k", "v" }), &d);
    try testing.expect(p.conn.usable);
}

test "pushes between replies, and the attributes before them, are skipped" {
    try within5s(testing.io, pushesSkipped, .{testing.io});
}

fn pushesSkipped(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var server = try io.concurrent(answerAll, .{
        &p.peer,
        &.{ &.{ "SET", "k", "v" }, &.{ "INCR", "n" } },
        ">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$3\r\nnew\r\n+OK\r\n" ++
            "|1\r\n+a\r\n:1\r\n>2\r\n+x\r\n+y\r\n>0\r\n|1\r\n+b\r\n:2\r\n:42\r\n",
    });
    defer server.await(io) catch {};
    const set = cmd.raw(void, .{ "SET", "k", "v" });
    const incr = cmd.raw(i64, .{ "INCR", "n" });
    p.conn.begin(deadline5s(io));
    try p.conn.write(set, null);
    try p.conn.write(incr, null);
    try p.conn.flush(null);
    try p.conn.receive(set, null, null);
    try testing.expectEqual(@as(i64, 42), try p.conn.receive(incr, null, null));
    try testing.expect(p.conn.usable);
}

test "a malformed reply is ProtocolViolation, and the connection is used no more" {
    try within5s(testing.io, malformed, .{testing.io});
}

fn malformed(io: Io) !void {
    for ([_][]const u8{ "@oops\r\n", "$abc\r\n", ">1\r\n+x\r\n@\r\n" }) |reply| {
        var p: Pair = undefined;
        try p.open(io, roomy);
        defer p.close(io);
        var server = try io.concurrent(answerAll, .{ &p.peer, &.{&.{"PING"}}, reply });
        defer server.await(io) catch {};
        var d: Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, p.conn.exchange(cmd.raw(void, .{"PING"}), null, deadline5s(io), &d));
        try testing.expect(!p.conn.usable);
        try testing.expectEqual(@as(?Diagnostics.Phase, .receive), d.phase);
        try testing.expectEqualStrings("the reply broke RESP3", d.message());
    }
}

test "a reply larger than max_reply_bytes is ReplyTooLarge, and the connection is used no more" {
    try within5s(testing.io, tooLarge, .{testing.io});
}

fn tooLarge(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, 100);
    defer p.close(io);
    var server = try io.concurrent(answerAll, .{ &p.peer, &.{&.{ "GET", "k" }}, "$200\r\n" ++ @as([200]u8, @splat('x')) ++ "\r\n" });
    defer server.await(io) catch {};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.ReplyTooLarge, p.conn.exchange(cmd.raw(?[]const u8, .{ "GET", "k" }), arena.allocator(), deadline5s(io), &d));
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the reply is larger than max_reply_bytes (100) or nests deeper than 64 levels", d.message());
}

test "the server closing the connection is ConnectionLost" {
    try within5s(testing.io, closedByServer, .{testing.io});
}

fn closedByServer(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var server = try io.concurrent(swallowAndClose, .{ &p.peer, io });
    defer server.await(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, p.conn.exchange(cmd.raw(void, .{"PING"}), null, deadline5s(io), &d));
    try testing.expect(!p.conn.usable);
    try testing.expectEqual(@as(?Diagnostics.Phase, .wait), d.phase);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the server at 127.0.0.1:{d} closed the connection", .{p.port()}), d.message());
}

test "an error of the socket that no cut caused is ConnectionLost, error.Unexpected too, and the diagnostics keep it" {
    var windows: WindowsLike = undefined;
    try within5s(testing.io, brokenUnexpectedly, .{windows.io()});
}

/// The client on an `Io` that reads the end of the stream, which the
/// server makes, as error.Unexpected.
fn brokenUnexpectedly(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var server = try io.concurrent(swallowAndClose, .{ &p.peer, io });
    defer server.await(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, p.conn.exchange(cmd.raw(void, .{"PING"}), null, deadline5s(io), &d));
    try testing.expect(!p.conn.usable);
    try testing.expectEqual(@as(?anyerror, error.Unexpected), d.cause);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the connection to 127.0.0.1:{d} broke: Unexpected", .{p.port()}), d.message());
}

test "the deadline passing while the reply is out is Timeout, not before it, and the connection is used no more" {
    try within5s(testing.io, replyTooLate, .{testing.io});
}

fn replyTooLate(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var server = try io.concurrent(swallow, .{&p.peer});
    defer server.await(io) catch {};
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
    var d: Diagnostics = .{};
    try testing.expectError(error.Timeout, p.conn.exchange(cmd.raw(void, .{"PING"}), null, deadline, &d));
    try testing.expect(time.expired(io, deadline));
    try testing.expect(!p.conn.usable);
    try testing.expectEqual(@as(?Diagnostics.Phase, .wait), d.phase);
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
}

test "an exchange cut from another task is ConnectionLost, also where the system says error.Unexpected" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, cutInFlight, .{io});
}

fn exchangeCut(conn: *Connection, d: *Diagnostics) !void {
    try testing.expectError(error.ConnectionLost, conn.exchange(cmd.raw(void, .{"PING"}), null, null, d));
}

fn cutInFlight(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var d: Diagnostics = .{};
    var client = try io.concurrent(exchangeCut, .{ p.conn, &d });
    try swallow(&p.peer);
    // The client waits for the reply, or soon will: the cut ends the wait
    // either way.
    try io.sleep(.fromMilliseconds(20), .awake);
    p.conn.cut(io);
    try client.await(io);
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the exchange was cut", d.message());
}

test "canceling the task while the reply is out is Interrupted, and the task stays canceled" {
    try within5s(testing.io, canceledInFlight, .{testing.io});
}

fn exchangeAndCheck(conn: *Connection, d: *Diagnostics) !void {
    try testing.expectError(error.Interrupted, conn.exchange(cmd.raw(void, .{"PING"}), null, null, d));
    // io.recancel() kept the cancelation for the task's next wait.
    try testing.expectError(error.Canceled, conn.stream.io.sleep(.fromSeconds(5), .awake));
}

fn canceledInFlight(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io, roomy);
    defer p.close(io);
    var d: Diagnostics = .{};
    var client = try io.concurrent(exchangeAndCheck, .{ p.conn, &d });
    try swallow(&p.peer);
    try client.cancel(io);
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the task was canceled while the command was out", d.message());
}
