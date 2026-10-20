//! Protocol tests of the handshake: a new connection against
//! `mongo.testing.FakeServer`, its raw `Peer` for the bytes of hello and
//! its scripted server for the types of servers, over loopback. Every test
//! runs under a time limit of 5 s.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const wire = @import("../wire.zig");
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const Connection = @import("../engine/Connection.zig");
const connect = @import("../engine/connect.zig");
const handshake = @import("../engine/handshake.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;

/// Answers every command with `{ok: 1.0}`.
pub const Ok = struct {
    pub fn answer(o: *Ok, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ o, io, arena, request };
        return .{ .reply = Script.ok };
    }
};

/// The hello command of a client with `app_name`, from `testing.allocator`.
fn hello(app_name: ?[]const u8) !bson.OwnedDocument {
    const meta = try handshake.metadata(testing.allocator, app_name, null);
    defer meta.deinit();
    return handshake.command(testing.allocator, meta.raw(), .{});
}

fn address(listener: *const net.Server) Connection.Address {
    return .{ .host = "127.0.0.1", .port = FakeServer.port(listener) };
}

/// The setup of a client without a user, with `metadata`.
fn plain(metadata: bson.OwnedDocument) handshake.Setup {
    return .{ .metadata = metadata.raw() };
}

/// Opens a connection to `listener` under a deadline 5 s away.
fn open(io: Io, listener: *const net.Server, setup: *const handshake.Setup, d: *Diagnostics) connect.OpenError!*Connection {
    var attempt: connect.Attempt = .{};
    return connect.open(io, testing.allocator, address(listener), setup, .after(time.now(io), .fromSeconds(5)), &attempt, d);
}

/// The labels that CMAP gives a network error while a connection opens.
fn expectOverloaded(d: *const Diagnostics) !void {
    const server = d.server orelse return error.TestExpectedLabels;
    try testing.expectEqual(@as(i32, 0), server.code);
    try testing.expect(server.labels.contains(.system_overloaded_error));
    try testing.expect(server.labels.contains(.retryable_error));
}

const standalone = bson.literal(.{
    .helloOk = true,
    .ismaster = true,
    .maxBsonObjectSize = 16 * 1024 * 1024,
    .maxMessageSizeBytes = 48_000_000,
    .maxWriteBatchSize = 100_000,
    .connectionId = 42,
    .minWireVersion = 0,
    .maxWireVersion = 29,
    .ok = 1.0,
});

test "hello goes out byte for byte: isMaster, helloOk, the client's metadata and $db admin" {
    try within5s(testing.io, helloBytes, .{testing.io});
}

/// Accepts one client, checks that its first request is `expected`, and
/// answers it with `reply`.
fn expectHello(io: Io, listener: *net.Server, expected: bson.RawDocument, reply: bson.RawDocument) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer request.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, request.body.bytes);
    try testing.expectEqual(@as(u32, 0), request.flags);
    try peer.reply(&request, reply);
}

fn helloBytes(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    const expected = bson.literal(.{
        .isMaster = 1,
        .helloOk = true,
        .client = .{
            .application = .{ .name = "orders" },
            .driver = .{ .name = "zefir-mongo", .version = handshake.driver_version },
            .os = .{ .type = handshake.os_type, .architecture = @tagName(builtin.cpu.arch) },
            .platform = "Zig " ++ builtin.zig_version_string,
        },
        .@"$db" = "admin",
    });
    var server = try io.concurrent(expectHello, .{ io, &listener, expected, standalone });
    const meta = try handshake.metadata(testing.allocator, "orders", null);
    defer meta.deinit();
    var d: Diagnostics = .{};
    const conn = open(io, &listener, &plain(meta), &d) catch |err| {
        server.cancel(io) catch {};
        return err;
    };
    defer conn.destroy();
    try server.await(io);
    // The connection keeps what the server said and the round trip.
    try testing.expectEqual(@as(i32, 29), conn.hello.max_wire_version);
    try testing.expectEqual(@as(?i64, 42), conn.hello.connection_id);
    try testing.expectEqual(@as(u32, 48_000_000), conn.hello.max_message_size_bytes);
    try testing.expect(conn.rtt != null);
    try testing.expectEqual(@as(i32, 2), conn.next_id);
}

test "every server but a standalone mongod of wire version 21 or later is Unsupported, with its type in the text, and gets no command" {
    try within5s(testing.io, refusedServers, .{testing.io});
}

fn refusedServers(io: Io) !void {
    const cases = [_]struct { wire.Hello, []const u8 }{
        .{ .{ .server_type = .rs_primary, .set_name = "rs7" }, "the server at {f} is a replica set member (RSPrimary, setName=rs7); v0.1 supports standalone mongod only" },
        .{ .{ .server_type = .rs_secondary }, "the server at {f} is a replica set member (RSSecondary, setName=rs0); v0.1 supports standalone mongod only" },
        .{ .{ .server_type = .rs_arbiter }, "the server at {f} is a replica set member (RSArbiter, setName=rs0); v0.1 supports standalone mongod only" },
        .{ .{ .server_type = .rs_other }, "the server at {f} is a replica set member (RSOther, setName=rs0); v0.1 supports standalone mongod only" },
        .{ .{ .server_type = .rs_ghost }, "the server at {f} is a replica set member not initialized yet (RSGhost); v0.1 supports standalone mongod only" },
        .{ .{ .server_type = .mongos }, "the server at {f} is a mongos (Mongos); v0.1 supports standalone mongod only" },
        .{ .{ .max_wire_version = 20 }, "Server at {f} reports wire version 20, but this version of zefir-mongo requires at least 21 (MongoDB 7.0)." },
    };
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    inline for (cases) |case| {
        var ok: Ok = .{};
        var script: Script = .init(testing.allocator, .init(&ok));
        defer script.deinit();
        script.hello = case[0];
        var listener = try FakeServer.listen(io);
        defer listener.deinit(io);
        var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
        defer server.cancel(io) catch {};
        var d: Diagnostics = .{};
        try testing.expectError(error.Unsupported, open(io, &listener, &plain(meta), &d));
        var buffer: [256]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, case[1], .{address(&listener)}), d.message());
        try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
        try testing.expectEqual(@as(usize, 0), script.received(io));
    }
}

test "a server that closes the connection on hello is Unavailable, with a word on TLS" {
    try within5s(testing.io, closedOnHello, .{testing.io});
}

fn readAndClose(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    request.deinit();
}

fn closedOnHello(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(readAndClose, .{ io, &listener });
    defer server.await(io) catch {};
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, open(io, &listener, &plain(meta), &d));
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "the server at {f} closed the connection during hello; a server that requires TLS does so, and v0.1 does not speak TLS", .{address(&listener)}), d.message());
    try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
    try expectOverloaded(&d);
}

test "ok 0 from hello is Unavailable, with the server's error" {
    try within5s(testing.io, helloFails, .{testing.io});
}

fn helloFails(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    const failure = bson.literal(.{ .ok = 0.0, .errmsg = "Failing command via 'failCommand' failpoint", .code = 91, .codeName = "ShutdownInProgress" });
    const command = try hello(null);
    defer command.deinit();
    var expected: bson.Builder = .init(testing.allocator);
    defer expected.deinit();
    var it = command.raw().iterator();
    while (try it.next()) |element| try expected.putValue(element.key, element.value);
    try expected.putString("$db", "admin");
    const with_db = try expected.finish();
    defer with_db.deinit();
    var server = try io.concurrent(expectHello, .{ io, &listener, with_db.raw(), failure });
    defer server.await(io) catch {};
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, open(io, &listener, &plain(meta), &d));
    try testing.expectEqual(@as(i32, 91), d.server.?.code);
    try testing.expectEqualStrings("Failing command via 'failCommand' failpoint", d.message());
    try testing.expectEqual(Diagnostics.Phase.handshake, d.phase.?);
    // The server answered: no labels of overload.
    try testing.expect(!d.server.?.labels.contains(.system_overloaded_error));
}

test "an attempt that the server leaves unanswered ends at its deadline, and a closed port is Unavailable" {
    try within5s(testing.io, unanswered, .{testing.io});
}

fn holdSilent(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    _ = try peer.readToEnd();
}

fn unanswered(io: Io) !void {
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    const setup = plain(meta);
    var listener = try FakeServer.listen(io);
    {
        var server = try io.concurrent(holdSilent, .{ io, &listener });
        defer server.await(io) catch {};
        var attempt: connect.Attempt = .{};
        const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(100));
        try testing.expectError(error.Timeout, connect.open(io, testing.allocator, address(&listener), &setup, deadline, &attempt, null));
        try testing.expect(time.expired(io, deadline));
    }
    const gone = address(&listener);
    listener.deinit(io);
    var d: Diagnostics = .{};
    var attempt: connect.Attempt = .{};
    try testing.expectError(error.Unavailable, connect.open(io, testing.allocator, gone, &setup, .after(time.now(io), .fromSeconds(5)), &attempt, &d));
    try testing.expectEqual(Diagnostics.Phase.connect, d.phase.?);
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buffer, "cannot connect to {f}: ConnectionRefused", .{gone}), d.message());
    try expectOverloaded(&d);
    // A host name that cannot be read is no sign of an overloaded server.
    var named: Diagnostics = .{};
    var named_attempt: connect.Attempt = .{};
    try testing.expectError(error.Unavailable, connect.open(io, testing.allocator, .{ .host = "bad..name", .port = 27017 }, &setup, .after(time.now(io), .fromSeconds(5)), &named_attempt, &named));
    try testing.expectEqualStrings("cannot connect to bad..name:27017: InvalidHostName", named.message());
    try testing.expect(named.server == null);
}

const Client = @import("../Client.zig");
const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

/// Answers `breakme` by closing the connection and `nope` with ok 0, code
/// 59; anything else with `{ok: 1.0}`.
const Commands = struct {
    pub fn answer(c: *Commands, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ c, io };
        if (std.mem.eql(u8, request.name, "breakme")) return .close_connection;
        if (std.mem.eql(u8, request.name, "nope")) return .{ .reply = Script.failure(arena, .{ .code = 59, .code_name = "CommandNotFound", .errmsg = "no such command: 'nope'" }) catch return error.OutOfMemory };
        return .{ .reply = Script.ok };
    }
};

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    commands: Commands = .{},
    script: Script,
    listener: net.Server,
    server: Io.Future(FakeServer.ServeError!void),
    buffer: [64]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io) !void {
        s.* = .{ .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.commands));
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    fn uri(s: *Served) ![]const u8 {
        return FakeServer.uri(&s.listener, &s.buffer);
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }
};

test "connect opens the first connection, ping runs on it, and after close every call is Closed" {
    try within5s(testing.io, connectAndPing, .{testing.io});
}

fn connectAndPing(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri() });
    defer driver.deinit();
    const c = &driver;
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());

    try driver.connect(io, .root, &d);
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
    try testing.expectEqual(@as(usize, 1), driver.stats().idle);
    const reply = try c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
    defer reply.deinit();
    try testing.expectEqual(@as(f64, 1), try (try reply.raw().get("ok")).?.asF64());
    // A second connect keeps the connection it has.
    try driver.connect(io, .root, null);
    try testing.expectEqual(@as(u32, 1), served.script.accepted.load(.acquire));

    driver.close(io);
    driver.close(io);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
    try testing.expectError(error.Closed, c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectError(error.Closed, driver.connect(io, .root, &d));
}

test "connect may be tried again after it failed" {
    try within5s(testing.io, connectAgain, .{testing.io});
}

fn connectAgain(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    served.script.refuseConnections();
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri() });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, driver.connect(io, .root, &d));
    served.script.acceptConnections();
    try driver.connect(io, .root, &d);
    const reply = try driver.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
    reply.deinit();
}

test "the deadline of connect passing is DeadlineExceeded, and connectTimeoutMS passing is Unavailable" {
    try within5s(testing.io, connectTimeouts, .{testing.io});
}

fn connectTimeouts(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var buffer: [128]u8 = undefined;
    var expected: [128]u8 = undefined;
    {
        var server = try io.concurrent(holdSilent, .{ io, &listener });
        defer server.await(io) catch {};
        var driver: Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
        defer driver.deinit();
        var d: Diagnostics = .{};
        const ctx = core.Context.root.withDeadline(.after(time.now(io), .fromMilliseconds(100)));
        try testing.expectError(error.DeadlineExceeded, driver.connect(io, ctx, &d));
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "the deadline passed while the client connected to {f}", .{address(&listener)}), d.message());
    }
    var server = try io.concurrent(holdSilent, .{ io, &listener });
    defer server.await(io) catch {};
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}/?connectTimeoutMS=100", .{FakeServer.port(&listener)});
    var driver: Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, driver.connect(io, .root, &d));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{f} did not answer within connectTimeoutMS (100 ms)", .{address(&listener)}), d.message());
}

test "a connection that broke is opened again by the next call, and ok 0 is CommandFailed with the reply" {
    try within5s(testing.io, brokenAndFailed, .{testing.io});
}

fn brokenAndFailed(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri() });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    const c = &driver;
    var d: Diagnostics = .{};
    const breakme: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .breakme = 1 }) };
    try testing.expectError(error.ConnectionLost, c.runCommand(io, .of(.root), breakme, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
    const reply = try c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
    reply.deinit();
    try testing.expectEqual(@as(u32, 2), served.script.accepted.load(.acquire));

    var failure: ?bson.OwnedDocument = null;
    const nope: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .nope = 1 }) };
    try testing.expectError(error.CommandFailed, c.runCommand(io, .of(.root), nope, .{ .allocator = testing.allocator, .diagnostics = &d, .failure_reply = &failure }));
    defer failure.?.deinit();
    try testing.expectEqual(@as(i32, 59), d.server.?.code);
    try testing.expectEqualStrings("no such command: 'nope'", d.message());
    // ok 0 leaves the connection as it was.
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
}

test "init does no I/O" {
    var driver: Client = try .init(testing.allocator, testing.io, .{ .uri = "mongodb://127.0.0.1:1/?appName=orders" });
    driver.deinit();
}
