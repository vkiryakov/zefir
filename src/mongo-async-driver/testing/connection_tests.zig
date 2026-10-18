//! Protocol tests of `engine/Connection.zig`: one connection against the
//! server's side played by the test, `mongo.testing.FakeServer.Peer`, over
//! loopback. Every test runs under a time limit of 5 s, so that a mistake
//! fails it instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const opmsg = mongo.wire.opmsg;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Connection = @import("../engine/Connection.zig");
const time = @import("../engine/time.zig");
const WindowsLike = @import("windows_like_io.zig").WindowsLike;

/// Runs `function(args)` in a task of its own and fails with
/// `error.TestTimedOut` when it takes longer than 5 s.
pub fn within5s(io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
    const Race = union(enum) {
        done: anyerror!void,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, Io.sleep, .{ io, .fromSeconds(5), .awake }) catch |err| {
        while (select.cancel()) |_| {}
        return err;
    };
    const first = try select.await();
    while (select.cancel()) |_| {}
    return switch (first) {
        .done => |result| result,
        .timer => error.TestTimedOut,
    };
}

/// A connection and the server's side of it. It points into itself: open
/// it in place.
const Pair = struct {
    listener: net.Server,
    peer: FakeServer.Peer,
    conn: *Connection,

    fn open(p: *Pair, io: Io) !void {
        p.listener = try FakeServer.listen(io);
        errdefer p.listener.deinit(io);
        const address: net.IpAddress = try .parseIp4("127.0.0.1", FakeServer.port(&p.listener));
        // The system completes the connection before the listener accepts.
        const stream = try address.connect(io, .{ .mode = .stream });
        p.conn = Connection.create(testing.allocator, io, stream, .{ .host = "127.0.0.1", .port = FakeServer.port(&p.listener) }) catch |err| {
            stream.close(io);
            return err;
        };
        errdefer p.conn.destroy();
        try p.peer.accept(io, &p.listener);
    }

    fn close(p: *Pair, io: Io) void {
        p.conn.destroy();
        p.peer.close();
        p.listener.deinit(io);
    }
};

const ping: Connection.Request = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

/// Reads one request and answers it with `reply`; returns its requestID.
fn answer(peer: *FakeServer.Peer, reply: bson.RawDocument) !i32 {
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer request.deinit();
    try peer.reply(&request, reply);
    return request.header.request_id;
}

/// Reads one request and leaves it unanswered.
fn swallow(peer: *FakeServer.Peer) !void {
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    request.deinit();
}

test "an exchange sends the command with $db and returns the reply to its requestID" {
    try within5s(testing.io, exchangeRoundTrip, .{testing.io});
}

fn exchangeRoundTrip(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var server = try io.concurrent(answer, .{ &p.peer, bson.literal(.{ .ok = 1.0 }) });
    const reply = p.conn.exchange(ping, testing.allocator, null, null) catch |err| {
        _ = server.cancel(io) catch {};
        return err;
    };
    defer reply.deinit();
    try testing.expectEqual(@as(i32, 1), try server.await(io));
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 1.0 }).bytes, reply.bytes);
    try testing.expect(p.conn.usable);
}

test "requestID counts up from 1 and wraps around past the largest i32" {
    try within5s(testing.io, requestIds, .{testing.io});
}

fn requestIds(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    p.conn.next_id = std.math.maxInt(i32);
    for ([_]i32{ std.math.maxInt(i32), std.math.minInt(i32) }) |expected| {
        var server = try io.concurrent(answer, .{ &p.peer, bson.literal(.{ .ok = 1.0 }) });
        const reply = p.conn.exchange(ping, testing.allocator, null, null) catch |err| {
            _ = server.cancel(io) catch {};
            return err;
        };
        reply.deinit();
        try testing.expectEqual(expected, try server.await(io));
    }
}

test "a reply to another request breaks OP_MSG: ProtocolViolation, and the connection is used no more" {
    try within5s(testing.io, wrongResponseTo, .{testing.io});
}

fn answerAnother(peer: *FakeServer.Peer) !void {
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer request.deinit();
    try opmsg.writeReply(&peer.writer.interface, 1, request.header.request_id +% 1, bson.literal(.{ .ok = 1.0 }));
    try peer.writer.interface.flush();
}

fn wrongResponseTo(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var server = try io.concurrent(answerAnother, .{&p.peer});
    defer server.await(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.ProtocolViolation, p.conn.exchange(ping, testing.allocator, null, &d));
    try testing.expect(!p.conn.usable);
    try testing.expectEqual(Diagnostics.Phase.receive, d.phase.?);
    try testing.expectEqualStrings("the reply answers request 2; the request was 1", d.message());
}

test "a reply longer than the server's maxMessageSizeBytes is ProtocolViolation, and before hello the limit is 48 000 000" {
    try within5s(testing.io, tooLong, .{testing.io});
}

/// Reads one request and answers with the header of a message of `length`
/// bytes, and nothing after it.
fn announce(peer: *FakeServer.Peer, length: i32) !void {
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer request.deinit();
    var header: [opmsg.header_len]u8 = undefined;
    var w: Io.Writer = .fixed(&header);
    try (opmsg.Header{ .message_length = length, .request_id = 1, .response_to = request.header.request_id, .op_code = opmsg.op_code }).write(&w);
    try peer.send(&header);
}

fn tooLong(io: Io) !void {
    {
        var p: Pair = undefined;
        try p.open(io);
        defer p.close(io);
        var server = try io.concurrent(announce, .{ &p.peer, 48_000_001 });
        defer server.await(io) catch {};
        var d: Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, p.conn.exchange(ping, testing.allocator, null, &d));
        try testing.expect(!p.conn.usable);
        try testing.expectEqualStrings("the message says it is 48000001 bytes long; a message here is 26 to 48000000 bytes", d.message());
    }
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    p.conn.hello.max_message_size_bytes = 1000;
    var server = try io.concurrent(announce, .{ &p.peer, 1001 });
    defer server.await(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.ProtocolViolation, p.conn.exchange(ping, testing.allocator, null, &d));
    try testing.expectEqualStrings("the message says it is 1001 bytes long; a message here is 26 to 1000 bytes", d.message());
}

test "a command longer than the server takes is InvalidArgument, and nothing goes out" {
    try within5s(testing.io, commandTooLong, .{testing.io});
}

fn commandTooLong(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    p.conn.hello.max_message_size_bytes = 40;
    var d: Diagnostics = .{};
    const long: Connection.Request = .{ .database = "admin", .body = bson.literal(.{ .ping = 1, .comment = "a comment that does not fit" }) };
    try testing.expectError(error.InvalidArgument, p.conn.exchange(long, testing.allocator, null, &d));
    try testing.expect(p.conn.usable);
    const length = (opmsg.Request{ .request_id = 0, .body = long.body, .database = long.database }).length();
    var buffer: [80]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the command is {d} bytes as OP_MSG, and the server takes 40 at most", .{length}), d.message());
    // The next request is the first the server sees, with the first id.
    p.conn.hello.max_message_size_bytes = 48_000_000;
    var server = try io.concurrent(answer, .{ &p.peer, bson.literal(.{ .ok = 1.0 }) });
    const reply = p.conn.exchange(ping, testing.allocator, null, null) catch |err| {
        _ = server.cancel(io) catch {};
        return err;
    };
    reply.deinit();
    try testing.expectEqual(@as(i32, 1), try server.await(io));
}

test "the server closing the connection is ConnectionLost" {
    try within5s(testing.io, closedByServer, .{testing.io});
}

fn swallowAndClose(peer: *FakeServer.Peer) !void {
    try swallow(peer);
    peer.close();
}

fn closedByServer(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer {
        p.conn.destroy();
        p.listener.deinit(io);
    }
    var server = try io.concurrent(swallowAndClose, .{&p.peer});
    defer server.await(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, p.conn.exchange(ping, testing.allocator, null, &d));
    try testing.expect(!p.conn.usable);
    try testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the server at 127.0.0.1:{d} closed the connection", .{FakeServer.port(&p.listener)}), d.message());
}

test "the deadline passing while the reply is out is Timeout, and not before it" {
    try within5s(testing.io, replyTooLate, .{testing.io});
}

fn replyTooLate(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var server = try io.concurrent(swallow, .{&p.peer});
    defer server.await(io) catch {};
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
    var d: Diagnostics = .{};
    try testing.expectError(error.Timeout, p.conn.exchange(ping, testing.allocator, deadline, &d));
    try testing.expect(time.expired(io, deadline));
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
}

test "an exchange cut from another task is ConnectionLost, also where the system says error.Unexpected" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| try within5s(testing.io, cutInFlight, .{io});
}

fn exchangeCut(conn: *Connection, d: *Diagnostics) !void {
    try testing.expectError(error.ConnectionLost, conn.exchange(ping, testing.allocator, null, d));
}

fn cutInFlight(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var d: Diagnostics = .{};
    var client = try io.concurrent(exchangeCut, .{ p.conn, &d });
    // The command is out once the server has read it.
    const swallowed = swallow(&p.peer);
    p.conn.cut(io);
    try client.await(io);
    try swallowed;
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the exchange was cut", d.message());
    try testing.expectEqual(Diagnostics.Phase.wait, d.phase.?);
}

test "canceling the task while the reply is out is Interrupted, and the task stays canceled" {
    try within5s(testing.io, canceledInFlight, .{testing.io});
}

fn exchangeAndCheck(conn: *Connection, d: *Diagnostics) !void {
    try testing.expectError(error.Interrupted, conn.exchange(ping, testing.allocator, null, d));
    // io.recancel() kept the cancelation for the task's next wait.
    try testing.expectError(error.Canceled, conn.stream.io.sleep(.fromSeconds(5), .awake));
}

fn canceledInFlight(io: Io) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var d: Diagnostics = .{};
    var client = try io.concurrent(exchangeAndCheck, .{ p.conn, &d });
    try swallow(&p.peer);
    try client.cancel(io);
    try testing.expect(!p.conn.usable);
    try testing.expectEqualStrings("the task was canceled while the command was out", d.message());
}
