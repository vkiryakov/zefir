//! Tests of `redis.testing.FakeServer`: a client in the test talks to it
//! over loopback in RESP3, as the client of zefir-redis does, and every
//! scenario runs under a time limit of 5 s, so that a mistake fails a test
//! instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const resp = @import("../resp.zig");
const FakeServer = @import("FakeServer.zig");
const early_io = @import("early_io.zig");

const Reply = FakeServer.Reply;
const Value = resp.Value;

/// Runs `function(args)` in a task of its own and fails with
/// `error.TestTimedOut` when it takes longer than 5 s.
fn within5s(io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
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

/// One connection of a client in the test: it writes commands and reads
/// replies with the client's own writer and reader. It points into itself:
/// open it in place.
const Client = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [16 * 1024]u8,

    /// Connects to `url`, "redis://127.0.0.1:<port>".
    fn open(c: *Client, io: Io, url: []const u8) !void {
        const prefix = "redis://127.0.0.1:";
        if (!std.mem.startsWith(u8, url, prefix)) return error.TestUnexpectedUrl;
        const address: net.IpAddress = try .parseIp4("127.0.0.1", try std.fmt.parseInt(u16, url[prefix.len..], 10));
        c.io = io;
        c.stream = try address.connect(io, .{ .mode = .stream });
        c.reader = c.stream.reader(io, &c.read_buffer);
        c.writer = c.stream.writer(io, &c.write_buffer);
    }

    fn close(c: *Client) void {
        c.stream.close(c.io);
    }

    fn send(c: *Client, args: []const []const u8) !void {
        try resp.Writer.init(&c.writer.interface).command(args);
        try c.writer.interface.flush();
    }

    /// The next reply, whole, in `arena`.
    fn reply(c: *Client, arena: Allocator) !Value {
        var reader: resp.Reader = .init(&c.reader.interface, 1 << 20);
        return resp.readValue(&reader, arena);
    }

    fn command(c: *Client, arena: Allocator, args: []const []const u8) !Value {
        try c.send(args);
        return c.reply(arena);
    }

    /// Reads as many bytes as `expected` holds and checks them.
    fn expectBytes(c: *Client, expected: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        const got = buffer[0..expected.len];
        try c.reader.interface.readSliceAll(got);
        try testing.expectEqualStrings(expected, got);
    }

    /// The server closed the connection: a read ends the stream.
    fn expectClosed(c: *Client) !void {
        _ = c.reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => switch (c.reader.err orelse return err) {
                error.ConnectionResetByPeer => return,
                else => |e| return e,
            },
        };
        return error.TestConnectionStillOpen;
    }
};

/// The pairs of the map `value`.
fn pairsOf(value: Value) ![]const Value.Pair {
    if (value != .map) return error.TestNotAMap;
    return value.map;
}

/// The value of `key` in the map `value`.
fn field(value: Value, key: []const u8) !Value {
    for (try pairsOf(value)) |pair| {
        if (pair.key == .string and std.mem.eql(u8, pair.key.string, key)) return pair.value;
    }
    return error.TestNoSuchKey;
}

/// Checks `got` against `expected`, its kind included.
fn expectValue(expected: Value, got: Value) !void {
    try testing.expectEqualDeep(expected, got);
}

fn expectError(value: Value, code: []const u8, prefix: []const u8) !void {
    if (value != .err) {
        std.debug.print("not an error: {any}\n", .{value});
        return error.TestNotAnError;
    }
    try testing.expectEqualStrings(code, value.err.code);
    if (!std.mem.startsWith(u8, value.err.message, prefix)) {
        std.debug.print("error text: {s}\n", .{value.err.message});
        return error.TestUnexpectedErrorText;
    }
}

fn expectArgs(expected: []const []const u8, entry: FakeServer.Entry) !void {
    try testing.expectEqual(expected.len, entry.args.len);
    for (expected, entry.args) |want, got| try testing.expectEqualStrings(want, got);
}

test "url names the port the server listens on" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    try testing.expect(std.mem.startsWith(u8, server.url(), "redis://127.0.0.1:"));
    try testing.expect(try std.fmt.parseInt(u16, server.url()["redis://127.0.0.1:".len..], 10) != 0);
}

test "a step answers its command, the name in any case, with the bytes of its reply; then finish passes" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "HGETALL", "user:42" }, .map(&.{ .{ "name", "Ann" }, .{ "plan", "pro" } })),
        .expect(.{ "get", "plan" }, .{ .string = "pro" }),
    });
    defer server.stop(io);
    try within5s(io, twoSteps, .{ io, server.url() });
    try server.finish(io);
    try testing.expectEqual(@as(usize, 2), server.received(io));
}

fn twoSteps(io: Io, url: []const u8) !void {
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    try c.send(&.{ "hgetall", "user:42" });
    try c.expectBytes("%2\r\n$4\r\nname\r\n$3\r\nAnn\r\n$4\r\nplan\r\n$3\r\npro\r\n");
    try c.send(&.{ "GET", "plan" });
    try c.expectBytes("$3\r\npro\r\n");
}

test "the server answers HELLO, CLIENT SETINFO, SELECT and PING itself; only PING goes to the journal" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    try within5s(io, handshake, .{ io, server.url() });
    try testing.expectEqual(@as(usize, 2), server.received(io));
    try expectArgs(&.{"PING"}, try server.entry(io, 0));
    try expectArgs(&.{ "ping", "hi" }, try server.entry(io, 1));
    try testing.expectEqual(@as(u32, 1), (try server.entry(io, 0)).connection);
    try server.finish(io);
}

fn handshake(io: Io, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();

    const hello = try c.command(a, &.{ "HELLO", "3" });
    try testing.expectEqual(@as(usize, 7), (try pairsOf(hello)).len);
    try expectValue(.{ .string = "redis" }, try field(hello, "server"));
    try expectValue(.{ .string = "8.10.2" }, try field(hello, "version"));
    try expectValue(.{ .integer = 3 }, try field(hello, "proto"));
    // The id of the client is the number of its connection.
    try expectValue(.{ .integer = 1 }, try field(hello, "id"));
    try expectValue(.{ .string = "standalone" }, try field(hello, "mode"));
    try expectValue(.{ .string = "master" }, try field(hello, "role"));
    try expectValue(.{ .array = &.{} }, try field(hello, "modules"));
    // Without a password the server takes any AUTH, and SETNAME.
    try expectValue(.{ .string = "redis" }, try field(try c.command(a, &.{ "hello", "3", "AUTH", "default", "any", "SETNAME", "api" }), "server"));
    try expectError(try c.command(a, &.{ "HELLO", "2" }), "NOPROTO", "NOPROTO ");

    try c.send(&.{ "CLIENT", "SETINFO", "LIB-NAME", "zefir-redis" });
    try c.expectBytes("+OK\r\n");
    try c.send(&.{ "client", "setinfo", "LIB-VER", "0.10.0" });
    try c.expectBytes("+OK\r\n");
    try c.send(&.{ "SELECT", "3" });
    try c.expectBytes("+OK\r\n");
    try c.send(&.{ "SELECT", "15" });
    try c.expectBytes("+OK\r\n");
    try c.send(&.{ "SELECT", "16" });
    try c.expectBytes("-ERR DB index is out of range\r\n");
    try c.send(&.{ "SELECT", "-1" });
    try c.expectBytes("-ERR DB index is out of range\r\n");
    try c.send(&.{"PING"});
    try c.expectBytes("+PONG\r\n");
    try c.send(&.{ "ping", "hi" });
    try c.expectBytes("$2\r\nhi\r\n");
}

test "with a password, HELLO must carry it: the right one gets the map, a wrong one WRONGPASS, none NOAUTH" {
    const io = testing.io;
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .hello = .{
        .server = "valkey",
        .version = "9.1.2",
        .password = "secret",
    } });
    defer server.stop(io);
    try within5s(io, authenticate, .{ io, server.url() });
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

fn authenticate(io: Io, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();

    const hello = try c.command(a, &.{ "HELLO", "3", "AUTH", "default", "secret" });
    try expectValue(.{ .string = "valkey" }, try field(hello, "server"));
    try expectValue(.{ .string = "9.1.2" }, try field(hello, "version"));
    // The user's name is not checked: every user has the password.
    _ = try field(try c.command(a, &.{ "HELLO", "3", "auth", "app", "secret", "SETNAME", "api" }), "server");
    try expectError(try c.command(a, &.{ "HELLO", "3", "AUTH", "default", "wrong" }), "WRONGPASS", "WRONGPASS ");
    try expectError(try c.command(a, &.{ "HELLO", "3" }), "NOAUTH", "NOAUTH ");
    try expectError(try c.command(a, &.{ "HELLO", "3", "SETNAME", "api" }), "NOAUTH", "NOAUTH ");
}

test "the map of HELLO says what Options.hello says" {
    const io = testing.io;
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .hello = .{ .version = "7.2.16", .mode = "cluster", .role = "replica" } });
    defer server.stop(io);
    try within5s(io, helloSays, .{ io, server.url() });
}

fn helloSays(io: Io, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    const hello = try c.command(arena.allocator(), &.{ "HELLO", "3" });
    try expectValue(.{ .string = "redis" }, try field(hello, "server"));
    try expectValue(.{ .string = "7.2.16" }, try field(hello, "version"));
    try expectValue(.{ .string = "cluster" }, try field(hello, "mode"));
    try expectValue(.{ .string = "replica" }, try field(hello, "role"));
}

test "a command the script does not expect gets an error that names it, goes to the journal, and is noted for finish" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "a" }, .{ .string = "1" }),
        .expect(.{ "DEL", "a" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    try within5s(io, unexpected, .{ io, server.url() });
    try testing.expectEqual(@as(usize, 5), server.received(io));
    try expectArgs(&.{ "GET", "k" }, try server.entry(io, 0));
    // What finish then says is checked in FakeServer.zig, quietly.
    try testing.expect(server.state.?.unexpected != null);
}

fn unexpected(io: Io, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    try expectValue(.{ .err = .{
        .code = "ERR",
        .message = "ERR zefir FakeServer: unexpected command 'GET': the next step expects 'GET' with other arguments",
    } }, try c.command(a, &.{ "GET", "k" }));
    try expectValue(.{ .err = .{
        .code = "ERR",
        .message = "ERR zefir FakeServer: unexpected command 'SET': the next step expects 'GET'",
    } }, try c.command(a, &.{ "SET", "a", "2" }));
    // The step still waits for its command.
    try expectValue(.{ .string = "1" }, try c.command(a, &.{ "GET", "a" }));
    try expectValue(.{ .integer = 1 }, try c.command(a, &.{ "DEL", "a" }));
    try expectValue(.{ .err = .{
        .code = "ERR",
        .message = "ERR zefir FakeServer: unexpected command 'DEL': no step is left",
    } }, try c.command(a, &.{ "DEL", "a" }));
}

test "the steps run in the order the commands arrive, on every connection" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SET", "a", "1" }, .ok),
        .expect(.{ "GET", "a" }, .{ .string = "1" }),
    });
    defer server.stop(io);
    try within5s(io, twoClients, .{ io, server.url() });
    try server.finish(io);
    const first = try server.entry(io, 0);
    const second = try server.entry(io, 1);
    try testing.expect(first.connection != second.connection);
    try testing.expectEqual(@as(u32, 1), first.connection);
    try testing.expectEqual(@as(u32, 2), second.connection);
}

fn twoClients(io: Io, url: []const u8) !void {
    var writer: Client = undefined;
    try writer.open(io, url);
    defer writer.close();
    var reader: Client = undefined;
    try reader.open(io, url);
    defer reader.close();
    try writer.send(&.{ "SET", "a", "1" });
    try writer.expectBytes("+OK\r\n");
    try reader.send(&.{ "GET", "a" });
    try reader.expectBytes("$1\r\n1\r\n");
}

test "a send goes on the connection of the step before it, without a request" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"})),
        .send(.message("orders", "new")),
        .send(.message("orders", "paid")),
        .expect(.{ "GET", "k" }, .nil),
    });
    defer server.stop(io);
    try within5s(io, subscriber, .{ io, server.url() });
    try server.finish(io);
}

fn subscriber(io: Io, url: []const u8) !void {
    var other: Client = undefined;
    try other.open(io, url);
    defer other.close();
    var listener: Client = undefined;
    try listener.open(io, url);
    defer listener.close();
    try listener.send(&.{ "SUBSCRIBE", "orders" });
    try listener.expectBytes(">3\r\n$9\r\nsubscribe\r\n$6\r\norders\r\n:1\r\n");
    try listener.expectBytes(">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$3\r\nnew\r\n");
    try listener.expectBytes(">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$4\r\npaid\r\n");
    // Nothing went to the other connection: its replies come first.
    try other.send(&.{ "GET", "k" });
    try other.expectBytes("_\r\n");
    try other.send(&.{"PING"});
    try other.expectBytes("+PONG\r\n");
}

test "a delayed reply comes after its delay, though each sleep of the server's Io ends early, as on Windows" {
    const io = testing.io;
    const late: Reply = .{ .string = "late" };
    for ([_]Io{ io, early_io.io() }) |server_io| {
        var server: FakeServer = try .start(testing.allocator, server_io, &.{
            .expect(.{ "GET", "k" }, .{ .delayed = .{ .after = .fromMilliseconds(100), .reply = &late } }),
        });
        defer server.stop(server_io);
        try within5s(io, delayed, .{ io, server.url() });
        try server.finish(server_io);
    }
}

fn delayed(io: Io, url: []const u8) !void {
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    const start = Io.Clock.awake.now(io);
    try c.send(&.{ "GET", "k" });
    try c.expectBytes("$4\r\nlate\r\n");
    const took = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(took.nanoseconds >= 100 * std.time.ns_per_ms);
}

test "close_connection reads the command, puts it in the journal and closes the connection" {
    const io = testing.io;
    const closed: Reply = .close_connection;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "a" }, .close_connection),
        .expect(.{ "GET", "b" }, .{ .delayed = .{ .after = .fromMilliseconds(10), .reply = &closed } }),
        .expect(.{ "GET", "c" }, .ok),
    });
    defer server.stop(io);
    try within5s(io, closeTwice, .{ io, server.url() });
    try server.finish(io);
    try testing.expectEqual(@as(usize, 3), server.received(io));
    try expectArgs(&.{ "GET", "a" }, try server.entry(io, 0));
    try expectArgs(&.{ "GET", "b" }, try server.entry(io, 1));
}

fn closeTwice(io: Io, url: []const u8) !void {
    var first: Client = undefined;
    try first.open(io, url);
    defer first.close();
    try first.send(&.{ "GET", "a" });
    try first.expectClosed();
    var second: Client = undefined;
    try second.open(io, url);
    defer second.close();
    try second.send(&.{ "GET", "b" });
    try second.expectClosed();
    var third: Client = undefined;
    try third.open(io, url);
    defer third.close();
    try third.send(&.{ "GET", "c" });
    try third.expectBytes("+OK\r\n");
}

test "refuse_connections ends every connection and refuses new ones until acceptConnections" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "k" }, .refuse_connections),
        .expect(.{ "GET", "k" }, .ok),
    });
    defer server.stop(io);
    try within5s(io, refuse, .{ io, &server });
    try server.finish(io);
    // The connection refused got no number: the one after it is the third.
    try testing.expectEqual(@as(usize, 3), server.received(io));
    try testing.expectEqual(@as(u32, 3), (try server.entry(io, 2)).connection);
}

fn refuse(io: Io, server: *FakeServer) !void {
    var idle: Client = undefined;
    try idle.open(io, server.url());
    defer idle.close();
    try idle.send(&.{"PING"});
    try idle.expectBytes("+PONG\r\n");
    var asking: Client = undefined;
    try asking.open(io, server.url());
    defer asking.close();
    try asking.send(&.{ "GET", "k" });
    try asking.expectClosed();
    // The server went away: the connection that sat idle ends too.
    try idle.expectClosed();
    var refused: Client = undefined;
    try refused.open(io, server.url());
    defer refused.close();
    try refused.expectClosed();

    server.acceptConnections(io);
    var back: Client = undefined;
    try back.open(io, server.url());
    defer back.close();
    try back.send(&.{ "GET", "k" });
    try back.expectBytes("+OK\r\n");
}

test "a malformed reply goes out as it is; the connection stays open after it, except after a truncated one" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "GET", "a" }, .{ .malformed = .unknown_type }),
        .expect(.{ "GET", "b" }, .{ .malformed = .bad_length }),
        .expect(.{ "GET", "c" }, .{ .malformed = .truncated }),
    });
    defer server.stop(io);
    try within5s(io, malformed, .{ io, server.url() });
    try server.finish(io);
}

fn malformed(io: Io, url: []const u8) !void {
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    try c.send(&.{ "GET", "a" });
    try c.expectBytes("@1\r\n");
    try c.send(&.{ "GET", "b" });
    try c.expectBytes("$-2\r\n");
    try c.send(&.{ "GET", "c" });
    try c.expectBytes("*2\r\n$3\r\nAnn\r\n");
    try c.expectClosed();
}

test "bytes that are not a command get a protocol error, the connection closes, and they are noted for finish" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    try within5s(io, notACommand, .{ io, server.url() });
    try testing.expectEqual(@as(usize, 0), server.received(io));
    try testing.expect(server.state.?.unexpected != null);
}

fn notACommand(io: Io, url: []const u8) !void {
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    // An inline command, as a person types it in telnet.
    try c.writer.interface.writeAll("PING\r\n");
    try c.writer.interface.flush();
    try c.expectBytes("-ERR Protocol error: zefir FakeServer reads a command as an array of bulk strings\r\n");
    try c.expectClosed();
}

test "the journal holds each command byte for byte with its connection; count counts a name in any case" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SET", "a\r\nb\x00c", "" }, .ok),
        .expect(.{ "get", "a\r\nb\x00c" }, .{ .string = "" }),
        .expect(.{ "GET", "x" }, .nil),
    });
    defer server.stop(io);
    try within5s(io, binary, .{ io, server.url() });
    try server.finish(io);
    try testing.expectEqual(@as(usize, 3), server.received(io));
    const set = try server.entry(io, 0);
    try expectArgs(&.{ "SET", "a\r\nb\x00c", "" }, set);
    try testing.expectEqual(@as(u32, 1), set.connection);
    try expectArgs(&.{ "GET", "a\r\nb\x00c" }, try server.entry(io, 1));
    try testing.expectError(error.NotReceived, server.entry(io, 3));
    try testing.expectError(error.NotReceived, server.entry(io, 99));
    try testing.expectEqual(@as(usize, 2), server.count(io, "get"));
    try testing.expectEqual(@as(usize, 2), server.count(io, "GET"));
    try testing.expectEqual(@as(usize, 1), server.count(io, "set"));
    try testing.expectEqual(@as(usize, 0), server.count(io, "del"));
}

fn binary(io: Io, url: []const u8) !void {
    var c: Client = undefined;
    try c.open(io, url);
    defer c.close();
    try c.send(&.{ "SET", "a\r\nb\x00c", "" });
    try c.expectBytes("+OK\r\n");
    try c.send(&.{ "GET", "a\r\nb\x00c" });
    try c.expectBytes("$0\r\n\r\n");
    try c.send(&.{ "GET", "x" });
    try c.expectBytes("_\r\n");
}

test "stop ends the connections and frees the journal; a second stop does nothing" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    try within5s(io, stopTwice, .{ io, &server });
    try testing.expectEqual(@as(usize, 0), server.received(io));
    try testing.expectEqual(@as(usize, 0), server.count(io, "ping"));
    try testing.expectError(error.NotReceived, server.entry(io, 0));
    try testing.expectEqualStrings("", server.url());
}

fn stopTwice(io: Io, server: *FakeServer) !void {
    var c: Client = undefined;
    try c.open(io, server.url());
    defer c.close();
    try c.send(&.{"PING"});
    try c.expectBytes("+PONG\r\n");
    server.stop(io);
    server.stop(io);
    try c.expectClosed();
}

test "the server goes on through errors of accept, and stop ends it" {
    var server: FakeServer = try .start(testing.allocator, no_accept.io(), &.{});
    defer server.stop(no_accept.io());
    try testing.io.sleep(.fromMilliseconds(30), .awake);
}

/// `std.testing.io` whose every accept fails with `error.SystemResources`.
const no_accept = struct {
    const vtable: Io.VTable = vtable: {
        var v = testing.io.vtable.*;
        v.netAccept = accept;
        break :vtable v;
    };

    fn io() Io {
        return .{ .userdata = testing.io.userdata, .vtable = &vtable };
    }

    fn accept(userdata: ?*anyopaque, listener: net.Socket.Handle, options: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
        _ = .{ userdata, listener, options };
        return error.SystemResources;
    }
};
