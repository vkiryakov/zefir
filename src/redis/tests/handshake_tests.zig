//! Protocol tests of the handshake, `engine/handshake.zig`: a new
//! connection that `engine/connect.zig` opens against the server's side
//! played by the test, `redis.testing.FakeServer.Peer`, over loopback,
//! with the bytes of real servers where they were recorded
//! (`hello_replies.zig`). Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const Diagnostics = redis.Diagnostics;
const Peer = redis.testing.FakeServer.Peer;
const OwnedOptions = @import("../OwnedOptions.zig");
const Connection = @import("../engine/Connection.zig");
const connect = @import("../engine/connect.zig");
const handshake = @import("../engine/handshake.zig");
const time = @import("../engine/time.zig");
const replies = @import("hello_replies.zig");
const WindowsLike = @import("windows_like_io.zig").WindowsLike;
const within5s = @import("time_limit.zig").within5s;

fn portOf(peer: *const Peer) u16 {
    return peer.listener.?.socket.address.getPort();
}

/// Opens a connection to 127.0.0.1:`port` under a deadline 5 s away.
fn open(io: Io, port: u16, setup: handshake.Setup, d: *Diagnostics) connect.OpenError!*Connection {
    var attempt: connect.Attempt = .{};
    return connect.open(io, testing.allocator, .{ .host = "127.0.0.1", .port = port }, 1 << 20, &setup, .after(time.now(io), .fromSeconds(5)), &attempt, d);
}

/// The server's side of one handshake.
const Side = struct {
    /// The reply to HELLO.
    hello: []const u8,
    /// The replies to the commands after HELLO, one each, sent once they
    /// have all come. Empty: none come, and the client closes the
    /// connection.
    after: []const []const u8 = &.{},
};

/// The replies of a server to `CLIENT SETINFO LIB-NAME`, `LIB-VER` and
/// `SELECT`.
const setinfo_ok: []const []const u8 = &.{ "+OK\r\n", "+OK\r\n" };

/// Accepts the client, answers its HELLO with `side.hello` and the
/// commands after it with `side.after`; with none, checks that nothing
/// else comes before the client closes the connection.
fn serve(peer: *Peer, io: Io, side: Side) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hello = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("HELLO", hello[0]);
    try peer.send(side.hello);
    if (side.after.len == 0) {
        try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
        return;
    }
    for (side.after) |_| _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    for (side.after) |reply| try peer.send(reply);
}

/// A handshake of `setup` against `side` that succeeds; the caller
/// destroys the connection.
fn expectAccepted(io: Io, setup: handshake.Setup, side: Side) !*Connection {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(serve, .{ &peer, io, side });
    defer server.cancel(io) catch {};
    var d: Diagnostics = .{};
    const conn = open(io, portOf(&peer), setup, &d) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, d.message() });
        return err;
    };
    errdefer conn.destroy();
    try server.await(io);
    return conn;
}

/// `message` with its `{d}`, if any, the port of the server.
fn expand(buffer: []u8, message: []const u8, port: u16) ![]const u8 {
    const at = std.mem.find(u8, message, "{d}") orelse return message;
    return std.fmt.bufPrint(buffer, "{s}{d}{s}", .{ message[0..at], port, message[at + 3 ..] });
}

/// A handshake of `setup` against `side` that fails with `expected` and
/// the text `message`, in which `{d}` stands for the port of the server.
fn expectRefused(io: Io, setup: handshake.Setup, side: Side, expected: anyerror, message: []const u8) !Diagnostics {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    var server = try io.concurrent(serve, .{ &peer, io, side });
    defer server.cancel(io) catch {};
    var d: Diagnostics = .{};
    if (open(io, portOf(&peer), setup, &d)) |conn| {
        conn.destroy();
        std.debug.print("taken, expected {t}\n", .{expected});
        return error.TestUnexpectedResult;
    } else |err| {
        try server.await(io);
        try testing.expectEqual(expected, err);
        var buffer: [512]u8 = undefined;
        try testing.expectEqualStrings(try expand(&buffer, message, portOf(&peer)), d.message());
        try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
    }
    return d;
}

/// The test runner prints warnings: these tests make the client refuse
/// servers on purpose.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

/// A map of HELLO with these fields; `role` null leaves it out, as a
/// Sentinel does.
fn helloMap(buffer: []u8, server: []const u8, version: []const u8, proto: []const u8, mode: []const u8, role: ?[]const u8) ![]const u8 {
    var w: Io.Writer = .fixed(buffer);
    try w.print("%{d}\r\n", .{@as(u8, if (role == null) 5 else 6)});
    for ([_][]const u8{ "server", server, "version", version }) |s| try w.print("${d}\r\n{s}\r\n", .{ s.len, s });
    try w.print("$5\r\nproto\r\n{s}\r\n$2\r\nid\r\n:9\r\n", .{proto});
    try w.print("$4\r\nmode\r\n${d}\r\n{s}\r\n", .{ mode.len, mode });
    if (role) |r| try w.print("$4\r\nrole\r\n${d}\r\n{s}\r\n", .{ r.len, r });
    return w.buffered();
}

test "HELLO goes out alone and first, byte for byte, and CLIENT SETINFO and SELECT follow in one write" {
    try within5s(testing.io, handshakeBytes, .{testing.io});
}

/// Fails when the client sends anything within 50 ms: it waits for the
/// server. On an `Io` that cannot time a read, as std's on Windows, it
/// checks what came already.
fn expectSilence(io: Io, peer: *Peer) !void {
    try testing.expectEqual(@as(usize, 0), peer.reader.interface.bufferedLen());
    var byte: [1]u8 = undefined;
    var data: [1][]u8 = .{&byte};
    const quiet_for: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
    _ = io.operateTimeout(.{ .net_read = .{ .socket_handle = peer.stream.?.socket.handle, .data = &data } }, quiet_for.toTimeout()) catch |err| switch (err) {
        error.Timeout, error.ConcurrencyUnavailable => return,
        error.Canceled => |e| return e,
    };
    return error.TestUnexpectedBytes;
}

/// Reads exactly `hello`, checks that nothing follows it before the reply,
/// answers it as Redis 8.10.2, then reads exactly `after` before it
/// answers each of its `commands` commands with +OK.
fn hearBytes(peer: *Peer, io: Io, hello: []const u8, after: []const u8, commands: usize) !void {
    try peer.accept(io);
    const in = &peer.reader.interface;
    var buffer: [512]u8 = undefined;
    try in.readSliceAll(buffer[0..hello.len]);
    try testing.expectEqualStrings(hello, buffer[0..hello.len]);
    try expectSilence(io, peer);
    try peer.send(replies.redis_8_10_2);
    try in.readSliceAll(buffer[0..after.len]);
    try testing.expectEqualStrings(after, buffer[0..after.len]);
    for (0..commands) |_| try peer.send("+OK\r\n");
}

fn handshakeBytes(io: Io) !void {
    const version = handshake.lib_version;
    var setinfo_buffer: [256]u8 = undefined;
    const setinfo = try std.fmt.bufPrint(&setinfo_buffer, "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$8\r\nLIB-NAME\r\n$11\r\nzefir-redis\r\n" ++
        "*4\r\n$6\r\nCLIENT\r\n$7\r\nSETINFO\r\n$7\r\nLIB-VER\r\n${d}\r\n{s}\r\n", .{ version.len, version });
    var with_select_buffer: [256]u8 = undefined;
    const with_select = try std.fmt.bufPrint(&with_select_buffer, "{s}*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n", .{setinfo});
    const cases = [_]struct { Options, []const u8, []const u8, usize }{
        .{ .{ .url = "redis://127.0.0.1" }, "*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n", setinfo, 2 },
        .{
            .{ .url = "redis://app:secret@127.0.0.1/3", .client_name = "api-1" },
            "*7\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$4\r\nAUTH\r\n$3\r\napp\r\n$6\r\nsecret\r\n$7\r\nSETNAME\r\n$5\r\napi-1\r\n",
            with_select,
            3,
        },
        .{ .{ .url = "redis://:secret@127.0.0.1" }, "*5\r\n$5\r\nHELLO\r\n$1\r\n3\r\n$4\r\nAUTH\r\n$7\r\ndefault\r\n$6\r\nsecret\r\n", setinfo, 2 },
    };
    for (cases) |case| {
        const options, const hello, const after, const commands = case;
        var owned: OwnedOptions = try .init(testing.allocator, options);
        defer owned.deinit(testing.allocator);
        var peer: Peer = try .listen(io);
        defer peer.close(io);
        var server = try io.concurrent(hearBytes, .{ &peer, io, hello, after, commands });
        defer server.cancel(io) catch {};
        var d: Diagnostics = .{};
        const conn = open(io, portOf(&peer), handshake.setupOf(&owned), &d) catch |err| {
            std.debug.print("{t}: {s}\n", .{ err, d.message() });
            return err;
        };
        conn.destroy();
        try server.await(io);
    }
}

const Options = @import("../Options.zig");

test "Redis 7.2 or later and Valkey 8 or later, standalone, master or replica, are taken; the connection keeps HELLO's id and its round trip" {
    try within5s(testing.io, acceptedServers, .{testing.io});
}

fn acceptedServers(io: Io) !void {
    var redis_7_2_0: [256]u8 = undefined;
    var valkey_8_0_0: [256]u8 = undefined;
    var unstable: [256]u8 = undefined;
    const cases = [_]struct { []const u8, i64 }{
        .{ replies.redis_8_10_2, 11 },
        .{ replies.redis_7_2_16, 3 },
        .{ replies.valkey_9_1_2, 3 },
        .{ replies.valkey_compatible, 3 },
        .{ replies.redis_replica, 11 },
        .{ try helloMap(&redis_7_2_0, "redis", "7.2.0", ":3", "standalone", "master"), 9 },
        .{ try helloMap(&valkey_8_0_0, "valkey", "8.0.0", ":3", "standalone", "replica"), 9 },
        // A build of the unstable branch of Redis.
        .{ try helloMap(&unstable, "redis", "255.255.255", ":3", "standalone", "master"), 9 },
    };
    for (cases) |case| {
        const hello, const id = case;
        const conn = try expectAccepted(io, .{}, .{ .hello = hello, .after = setinfo_ok });
        defer conn.destroy();
        try testing.expectEqual(@as(?i64, id), conn.id);
        try testing.expect(conn.rtt != null);
        try testing.expect(conn.usable);
    }
}

test "every other server is Unsupported, with what came, and gets no other command" {
    try within5s(testing.io, refusedServers, .{testing.io});
}

fn refusedServers(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    var buffers: [6][256]u8 = undefined;
    const needs = "v0.1 needs Redis 7.2 or later, or Valkey 8 or later";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ replies.redis_6_2_24, "the server at 127.0.0.1:{d} is Redis 6.2.24; v0.1 needs Redis 7.2 or later" },
        .{ try helloMap(&buffers[0], "valkey", "7.2.14", ":3", "standalone", "master"), "the server at 127.0.0.1:{d} is Valkey 7.2.14; v0.1 needs Valkey 8 or later" },
        .{ replies.redis_cluster, "the server at 127.0.0.1:{d} is a cluster node; v0.1 talks to one standalone server" },
        .{ replies.sentinel, "the server at 127.0.0.1:{d} is a Sentinel; v0.1 talks to one standalone server" },
        .{ try helloMap(&buffers[1], "dragonfly", "7.4.0", ":3", "standalone", "master"), "the server at 127.0.0.1:{d} is 'dragonfly' 7.4.0, neither Redis nor Valkey: " ++ needs },
        .{ try helloMap(&buffers[2], "redis", "seven", ":3", "standalone", "master"), "the server at 127.0.0.1:{d} is Redis of the version 'seven', which does not read: " ++ needs },
        .{ try helloMap(&buffers[3], "redis", "8.10.2", ":2", "standalone", "master"), "the server at 127.0.0.1:{d} answered HELLO 3 with proto 2: v0.1 speaks RESP3 only" },
        .{ try helloMap(&buffers[4], "redis", "8.10.2", ":3", "standalone", "leader"), "the server at 127.0.0.1:{d} has the role 'leader'; v0.1 talks to a master or a replica" },
        .{ try helloMap(&buffers[5], "redis", "8.10.2", ":3", "proxy", "master"), "the server at 127.0.0.1:{d} runs in the mode 'proxy'; v0.1 talks to one standalone server" },
        .{ "+OK\r\n", "the server at 127.0.0.1:{d} answered HELLO with a simple string of 2 bytes, not a map: " ++ needs },
        .{ "%1\r\n$6\r\nserver\r\n:1\r\n", "the field 'server' of the reply to HELLO from 127.0.0.1:{d} is an integer, not a string" },
        .{ "%1\r\n$5\r\nproto\r\n$1\r\n3\r\n", "the field 'proto' of the reply to HELLO from 127.0.0.1:{d} is a bulk string of 1 byte, not an integer" },
        .{ "%0\r\n", "the reply to HELLO from 127.0.0.1:{d} has no proto" },
        .{ "%1\r\n$5\r\nproto\r\n:3\r\n", "the reply to HELLO from 127.0.0.1:{d} has no server" },
    };
    for (cases) |case| {
        _ = try expectRefused(io, .{}, .{ .hello = case[0] }, error.Unsupported, case[1]);
    }
}

test "the errors of HELLO: a wrong or a missing password is AuthenticationFailed, no RESP3 or no HELLO Unsupported, the rest Unavailable" {
    try within5s(testing.io, helloErrors, .{testing.io});
}

fn helloErrors(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    const no_hello = "the server has no HELLO: v0.1 needs Redis 7.2 or later, or Valkey 8 or later";
    const auth: handshake.Setup = .{ .auth = .{ .username = "default", .password = "secret" } };
    {
        const d = try expectRefused(io, auth, .{ .hello = replies.wrongpass }, error.AuthenticationFailed, "WRONGPASS invalid username-password pair or user is disabled.");
        try testing.expect(d.isCode("WRONGPASS"));
    }
    _ = try expectRefused(io, .{}, .{ .hello = replies.noauth }, error.AuthenticationFailed, "the server wants a password: set it in the URL or in Options.password");
    _ = try expectRefused(io, .{}, .{ .hello = "-NOPROTO unsupported protocol version\r\n" }, error.Unsupported, "the server at 127.0.0.1:{d} does not speak RESP3: v0.1 needs Redis 7.2 or later, or Valkey 8 or later");
    _ = try expectRefused(io, .{}, .{ .hello = replies.redis_5_unknown }, error.Unsupported, no_hello);
    {
        // Redis 5 quotes the arguments of HELLO, the password among them:
        // its text goes nowhere.
        const d = try expectRefused(io, auth, .{ .hello = replies.redis_5_unknown_auth }, error.Unsupported, no_hello);
        try testing.expect(std.mem.find(u8, d.buffer[0..], "secret") == null);
    }
    const unavailable = [_]struct { []const u8, []const u8 }{
        .{ "-DENIED Redis is running in protected mode because protected mode is enabled and no password is set for the default user.\r\n", "DENIED" },
        .{ "-ERR max number of clients reached\r\n", "ERR" },
        .{ "-NOPERM User app has no permissions to run the 'hello' command\r\n", "NOPERM" },
        .{ "!21\r\nLOADING still loading\r\n", "LOADING" },
    };
    for (unavailable) |case| {
        const reply, const code = case;
        // The server's text as it sent it: after `-`, or after the length
        // of a bulk error.
        const text = std.mem.trimEnd(u8, reply[if (reply[0] == '!') 5 else 1..], "\r\n");
        const d = try expectRefused(io, .{}, .{ .hello = reply }, error.Unavailable, text);
        try testing.expect(d.isCode(code));
    }
}

test "the end of the stream during the handshake is Unavailable" {
    try within5s(testing.io, closedInHandshake, .{testing.io});
}

/// Accepts the client, reads its HELLO and closes the connection.
fn hangUp(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    peer.close(io);
}

fn closedInHandshake(io: Io) !void {
    var peer: Peer = try .listen(io);
    defer peer.close(io);
    const port = portOf(&peer);
    var server = try io.concurrent(hangUp, .{ &peer, io });
    defer server.cancel(io) catch {};
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, open(io, port, .{}, &d));
    try server.await(io);
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the server at 127.0.0.1:{d} closed the connection during the handshake; a server that requires TLS does so, and v0.1 does not speak TLS", .{port}), d.message());
    try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
}

test "a database that the server lacks is InvalidArgument, another error of SELECT Unavailable, and an error of CLIENT SETINFO is skipped" {
    try within5s(testing.io, afterHello, .{testing.io});
}

fn afterHello(io: Io) !void {
    const level = quiet();
    defer testing.log_level = level;
    const in_20: handshake.Setup = .{ .database = 20 };
    _ = try expectRefused(io, in_20, .{ .hello = replies.redis_8_10_2, .after = &.{ "+OK\r\n", "+OK\r\n", replies.select_out_of_range } }, error.InvalidArgument, "database 20 of the URL is not on the server");
    {
        const busy = "-BUSY Redis is busy running a script. You can only call SCRIPT KILL or SHUTDOWN NOSAVE.\r\n";
        const d = try expectRefused(io, in_20, .{ .hello = replies.redis_8_10_2, .after = &.{ "+OK\r\n", "+OK\r\n", busy } }, error.Unavailable, busy[1 .. busy.len - 2]);
        try testing.expect(d.isCode("BUSY"));
    }
    const conn = try expectAccepted(io, .{ .database = 3 }, .{ .hello = replies.redis_7_2_16, .after = &.{ replies.setinfo_unknown, replies.setinfo_unknown, "+OK\r\n" } });
    conn.destroy();
}

test "an attempt stopped during HELLO is Stopped, whatever its socket says, and one stopped before it has a socket keeps none" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| {
        try within5s(testing.io, stopInHello, .{io});
        try within5s(testing.io, stopBeforeSocket, .{io});
    }
}

/// Accepts one client and reads its HELLO, says so, and reads until the
/// client goes.
fn hearHello(peer: *Peer, io: Io, heard: *Io.Event) !void {
    try peer.accept(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    heard.set(io);
    _ = try peer.readToEnd();
}

fn openNow(io: Io, port: u16, attempt: *connect.Attempt, d: *Diagnostics) connect.OpenError!*Connection {
    const setup: handshake.Setup = .{};
    return connect.open(io, testing.allocator, .{ .host = "127.0.0.1", .port = port }, 1 << 20, &setup, null, attempt, d);
}

fn stopInHello(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var heard: Io.Event = .unset;
    var server = try testing.io.concurrent(hearHello, .{ &peer, testing.io, &heard });
    defer server.await(testing.io) catch {};
    var attempt: connect.Attempt = .{};
    var d: Diagnostics = .{};
    var opening = try io.concurrent(openNow, .{ io, portOf(&peer), &attempt, &d });
    // The client waits for the reply to HELLO when the server has it.
    const waited = heard.wait(testing.io);
    attempt.stop(io);
    const opened = opening.await(io);
    if (opened) |conn| conn.destroy() else |_| {}
    try waited;
    try testing.expectError(error.Stopped, opened);
}

/// Accepts one client and reads until it goes.
fn hearNothing(peer: *Peer, io: Io) !void {
    try peer.accept(io);
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn stopBeforeSocket(io: Io) !void {
    var peer: Peer = try .listen(testing.io);
    defer peer.close(testing.io);
    var server = try testing.io.concurrent(hearNothing, .{ &peer, testing.io });
    defer server.await(testing.io) catch {};
    var attempt: connect.Attempt = .{};
    attempt.stop(io);
    var d: Diagnostics = .{};
    // It dials, closes the socket it got and sends nothing.
    const opened = openNow(io, portOf(&peer), &attempt, &d);
    if (opened) |conn| conn.destroy() else |_| {}
    try testing.expectError(error.Stopped, opened);
}
