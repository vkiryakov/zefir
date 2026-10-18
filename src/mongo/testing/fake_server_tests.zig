//! Tests of `mongo.testing.FakeServer`: a client in the test talks to it
//! over loopback, and every scenario runs under a time limit of 5 s, so
//! that a mistake fails a test instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const bson = @import("../bson.zig");
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const errors = @import("../contract/errors.zig");
const Script = @import("Script.zig");
const FakeServer = @import("FakeServer.zig");

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

/// One connection of a client in the test. It points into itself: open it
/// in place.
const Client = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [16 * 1024]u8,
    next_id: i32,

    fn open(c: *Client, io: Io, port: u16) !void {
        const address: net.IpAddress = try .parseIp4("127.0.0.1", port);
        c.io = io;
        c.stream = try address.connect(io, .{ .mode = .stream });
        c.reader = c.stream.reader(io, &c.read_buffer);
        c.writer = c.stream.writer(io, &c.write_buffer);
        c.next_id = 1;
    }

    fn close(c: *Client) void {
        c.stream.close(c.io);
    }

    /// Sends `body` in `database`, with a section of kind 1 when given;
    /// returns its requestID.
    fn send(c: *Client, database: []const u8, body: bson.RawDocument, sequence: ?opmsg.Sequence) !i32 {
        const id = c.next_id;
        c.next_id += 1;
        try opmsg.writeRequest(&c.writer.interface, .{ .request_id = id, .body = body, .database = database, .sequence = sequence });
        try c.writer.interface.flush();
        return id;
    }

    fn reply(c: *Client, id: i32, diagnostics: ?*errors.Diagnostics) !bson.OwnedDocument {
        return opmsg.readReply(&c.reader.interface, testing.allocator, .{ .request_id = id }, diagnostics);
    }

    fn command(c: *Client, database: []const u8, body: bson.RawDocument) !bson.OwnedDocument {
        return c.reply(try c.send(database, body, null), null);
    }

    /// Writes `bytes` as they are.
    fn sendRaw(c: *Client, bytes: []const u8) !void {
        try c.writer.interface.writeAll(bytes);
        try c.writer.interface.flush();
    }

    /// One message, by the length in its header; free it with
    /// `testing.allocator`.
    fn readRaw(c: *Client) ![]u8 {
        const head = try c.reader.interface.peekArray(opmsg.header_len);
        const len = std.mem.readInt(i32, head[0..4], .little);
        const bytes = try testing.allocator.alloc(u8, @intCast(len));
        errdefer testing.allocator.free(bytes);
        try c.reader.interface.readSliceAll(bytes);
        return bytes;
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

fn expectOk(reply: bson.OwnedDocument) !void {
    defer reply.deinit();
    try testing.expectEqual(@as(f64, 1), try (try reply.raw().get("ok")).?.asF64());
}

/// A server for `script`, served until the test ends.
const Serving = struct {
    listener: net.Server,
    future: Io.Future(Io.Cancelable!void),

    fn start(s: *Serving, io: Io, script: *Script) !void {
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.future = try io.concurrent(FakeServer.serve, .{ io, &s.listener, script });
    }

    fn stop(s: *Serving, io: Io) void {
        s.future.cancel(io) catch {};
        s.listener.deinit(io);
    }

    fn port(s: *const Serving) u16 {
        return FakeServer.port(&s.listener);
    }
};

test "uri names the port the server listens on" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var buffer: [64]u8 = undefined;
    var expected: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "mongodb://127.0.0.1:{d}", .{FakeServer.port(&listener)}), try FakeServer.uri(&listener, &buffer));
    try testing.expect(FakeServer.port(&listener) != 0);
}

test "serve answers the handshake by script.hello, ping, endSessions and saslStart itself, the rest by the handler" {
    const io = testing.io;
    const found = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ .n = 1 }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 });
    var queue: Script.Queue = .{ .answers = &.{.{ .reply = found }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    script.hello.max_message_size_bytes = 4096;
    script.hello.max_wire_version = 25;
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, handshakeAndCommands, .{ io, serving.port(), &script, found });

    // The handshake is not in the journal; every command after it is.
    try testing.expectEqual(@as(usize, 5), script.received(io));
    for ([_][]const u8{ "ping", "endSessions", "saslStart", "find", "hello" }, 0..) |name, i| {
        const entry = script.entry(io, i);
        try testing.expectEqualStrings(name, entry.name);
        try testing.expectEqual(@as(u32, 1), entry.connection);
    }
    try testing.expectEqualStrings("app", script.entry(io, 3).database);
    try testing.expectEqual(@as(usize, 0), queue.left());
}

fn handshakeAndCommands(io: Io, port: u16, script: *Script, found: bson.RawDocument) !void {
    var c: Client = undefined;
    try c.open(io, port);
    defer c.close();
    const hello = try c.command("admin", bson.literal(.{ .isMaster = 1, .helloOk = true }));
    defer hello.deinit();
    const parsed = try wire.Hello.parse(hello.raw(), null);
    try testing.expectEqual(wire.Hello.ServerType.standalone, parsed.server_type);
    try testing.expectEqual(@as(u32, 3), parsed.max_write_batch_size);
    try testing.expectEqual(@as(u32, 4096), parsed.max_message_size_bytes);
    try testing.expectEqual(script.hello.max_bson_object_size, parsed.max_bson_object_size);
    try testing.expectEqual(@as(i32, 25), parsed.max_wire_version);
    try testing.expectEqual(@as(?i64, 1), parsed.connection_id);
    // No sessions: drivers that have them do not start any.
    try testing.expect(parsed.logical_session_timeout_minutes == null);
    try testing.expect((try hello.raw().get("helloOk")).?.boolean);
    try testing.expect((try hello.raw().get("ismaster")).?.boolean);

    try expectOk(try c.command("admin", bson.literal(.{ .ping = 1 })));
    try expectOk(try c.command("admin", bson.literal(.{ .endSessions = .{.{ .id = 1 }} })));
    const sasl = try c.command("admin", bson.literal(.{ .saslStart = 1, .mechanism = "SCRAM-SHA-256" }));
    defer sasl.deinit();
    const refused = errors.ServerError.fromReply(sasl.raw());
    try testing.expectEqual(@as(i32, 18), refused.code);
    try testing.expectEqualStrings("AuthenticationFailed", refused.code_name.slice());

    const reply = try c.command("app", bson.literal(.{ .find = "users" }));
    defer reply.deinit();
    try testing.expectEqualSlices(u8, found.bytes, reply.bytes);
    // A hello after the handshake is a command like the others, answered
    // by the server.
    const again = try c.command("admin", bson.literal(.{ .hello = 1 }));
    defer again.deinit();
    try testing.expect((try again.raw().get("isWritablePrimary")).?.boolean);
    try testing.expect((try again.raw().get("ismaster")) == null);
}

test "each connection gets a number of its own, and its commands carry it in the journal" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = Script.ok }, .{ .reply = Script.ok } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, twoConnections, .{ io, serving.port() });
    try testing.expectEqual(@as(usize, 2), script.received(io));
    try testing.expectEqual(@as(u32, 1), script.entry(io, 0).connection);
    try testing.expectEqual(@as(u32, 2), script.entry(io, 1).connection);
    try testing.expectEqual(@as(u32, 2), script.acceptedConnections());
}

fn twoConnections(io: Io, port: u16) !void {
    var first: Client = undefined;
    try first.open(io, port);
    defer first.close();
    (try first.command("admin", bson.literal(.{ .isMaster = 1 }))).deinit();
    try expectOk(try first.command("app", bson.literal(.{ .count = "users" })));
    var second: Client = undefined;
    try second.open(io, port);
    defer second.close();
    (try second.command("admin", bson.literal(.{ .isMaster = 1 }))).deinit();
    try expectOk(try second.command("app", bson.literal(.{ .count = "users" })));
}

test "a write's section of kind 1 reaches the handler and the journal" {
    const io = testing.io;
    var write: Script.Write = .{ .refuse = &.{.{ .index = 1 }} };
    var script: Script = .init(testing.allocator, write.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, insertTwo, .{ io, serving.port() });
    const entry = script.entry(io, 0);
    try testing.expectEqualStrings("insert", entry.name);
    try testing.expectEqualStrings("documents", entry.sequence.?.identifier);
    var docs = entry.sequence.?.documents();
    try testing.expectEqualSlices(u8, bson.literal(.{ ._id = 1 }).bytes, docs.next().?.bytes);
}

fn insertTwo(io: Io, port: u16) !void {
    var c: Client = undefined;
    try c.open(io, port);
    defer c.close();
    const docs = [_]bson.RawDocument{ bson.literal(.{ ._id = 1 }), bson.literal(.{ ._id = 2 }) };
    const id = try c.send("app", bson.literal(.{ .insert = "users", .ordered = false }), .{ .identifier = "documents", .documents = &docs });
    const reply = try c.reply(id, null);
    defer reply.deinit();
    try testing.expectEqual(@as(i64, 1), try (try reply.raw().get("n")).?.asI64());
    try testing.expectEqual(@as(i64, 1), try (try reply.raw().getPath("writeErrors.0.index")).?.asI64());
}

test "a delayed answer comes after its delay" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{.{ .delayed = .{ .after = .fromMilliseconds(100), .reply = Script.ok } }} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, delayed, .{ io, serving.port() });
}

fn delayed(io: Io, port: u16) !void {
    var c: Client = undefined;
    try c.open(io, port);
    defer c.close();
    const start = Io.Clock.awake.now(io);
    try expectOk(try c.command("app", bson.literal(.{ .count = "users" })));
    const took = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(took.nanoseconds >= 100 * std.time.ns_per_ms);
}

test "close_connection closes after the command; refuse_connections refuses new ones until acceptConnections" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{ .close_connection, .refuse_connections, .{ .reply = Script.ok } } };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, closeAndRefuse, .{ io, serving.port(), &script });
    // The commands of the closed connections were read: they are in the
    // journal. The refused connection sent nothing that was read.
    try testing.expectEqual(@as(usize, 3), script.received(io));
    try testing.expectEqual(@as(u32, 3), script.entry(io, 2).connection);
}

fn closeAndRefuse(io: Io, port: u16, script: *Script) !void {
    var first: Client = undefined;
    try first.open(io, port);
    defer first.close();
    _ = try first.send("app", bson.literal(.{ .count = "users" }), null);
    try first.expectClosed();

    var second: Client = undefined;
    try second.open(io, port);
    defer second.close();
    _ = try second.send("app", bson.literal(.{ .count = "users" }), null);
    try second.expectClosed();
    try testing.expect(script.isRefusing());

    var refused: Client = undefined;
    try refused.open(io, port);
    defer refused.close();
    try refused.expectClosed();

    script.acceptConnections();
    var third: Client = undefined;
    try third.open(io, port);
    defer third.close();
    try expectOk(try third.command("app", bson.literal(.{ .count = "users" })));
}

test "a malformed reply breaks OP_MSG as it says, and the server goes on serving the connection" {
    const io = testing.io;
    const kinds = [_]Script.Malformed{ .wrong_response_to, .unknown_required_flag, .sequence_in_reply, .truncated };
    var answers: [kinds.len * 2]Script.Answer = undefined;
    for (kinds, 0..) |kind, i| {
        answers[2 * i] = .{ .malformed = kind };
        answers[2 * i + 1] = .{ .reply = Script.ok };
    }
    var queue: Script.Queue = .{ .answers = &answers };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, malformed, .{ io, serving.port(), &kinds });
}

fn malformed(io: Io, port: u16, kinds: []const Script.Malformed) !void {
    var c: Client = undefined;
    try c.open(io, port);
    defer c.close();
    for (kinds) |kind| {
        const id = try c.send("app", bson.literal(.{ .count = "users" }), null);
        const bytes = try c.readRaw();
        defer testing.allocator.free(bytes);
        var reader: Io.Reader = .fixed(bytes);
        var d: errors.Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, opmsg.readReply(&reader, testing.allocator, .{ .request_id = id }, &d));
        const expected: []const u8 = switch (kind) {
            .wrong_response_to => "answers request",
            .unknown_required_flag => "flag bits 0x4",
            .sequence_in_reply => "more than one section",
            .truncated => "bytes are left of the message",
        };
        if (std.mem.find(u8, d.message(), expected) == null) {
            std.debug.print("{t}: {s}\n", .{ kind, d.message() });
            return error.TestUnexpectedMessage;
        }
        // The server read the message to its end: the next command works.
        try expectOk(try c.command("app", bson.literal(.{ .count = "users" })));
    }
}

test "OP_QUERY, and any message that breaks OP_MSG, closes the connection; a command without $db gets mongod's error" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var serving: Serving = undefined;
    try serving.start(io, &script);
    defer serving.stop(io);
    try within5s(io, brokenRequests, .{ io, serving.port() });
    try testing.expectEqual(@as(usize, 1), script.received(io));
    try testing.expectEqualStrings("", script.entry(io, 0).database);
}

fn brokenRequests(io: Io, port: u16) !void {
    // OP_QUERY of isMaster on admin.$cmd, as drivers before OP_MSG sent it.
    var query: Client = undefined;
    try query.open(io, port);
    defer query.close();
    const is_master = comptime bson.literal(.{ .isMaster = 1 });
    var message: [16 + 4 + 11 + 8 + is_master.bytes.len]u8 = undefined;
    std.mem.writeInt(i32, message[0..4], message.len, .little);
    std.mem.writeInt(i32, message[4..8], 1, .little);
    std.mem.writeInt(i32, message[8..12], 0, .little);
    std.mem.writeInt(i32, message[12..16], 2004, .little);
    std.mem.writeInt(u32, message[16..20], 0, .little);
    @memcpy(message[20..31], "admin.$cmd\x00");
    std.mem.writeInt(i32, message[31..35], 0, .little);
    std.mem.writeInt(i32, message[35..39], -1, .little);
    @memcpy(message[39..], is_master.bytes);
    try query.sendRaw(&message);
    try query.expectClosed();

    // OP_MSG whose section is of kind 2.
    var bad_kind: Client = undefined;
    try bad_kind.open(io, port);
    defer bad_kind.close();
    const ping = comptime bson.literal(.{ .ping = 1 });
    var kind2: [opmsg.header_len + 4 + 1 + ping.bytes.len]u8 = undefined;
    try writeMessage(&kind2, 2, ping);
    try bad_kind.sendRaw(&kind2);
    try bad_kind.expectClosed();

    // OP_MSG without $db.
    var no_db: Client = undefined;
    try no_db.open(io, port);
    defer no_db.close();
    var plain: [opmsg.header_len + 4 + 1 + ping.bytes.len]u8 = undefined;
    try writeMessage(&plain, 0, ping);
    try no_db.sendRaw(&plain);
    const reply = try no_db.reply(1, null);
    defer reply.deinit();
    const failure = errors.ServerError.fromReply(reply.raw());
    try testing.expectEqual(@as(i32, 40414), failure.code);
    try testing.expectEqualStrings("IDLFailedToParse", failure.code_name.slice());
    try testing.expectEqualStrings("BSON field 'ping.$db' is missing but a required field", (try reply.raw().get("errmsg")).?.string);
}

/// An OP_MSG of requestID 1 with one section of `kind` holding `doc`.
fn writeMessage(out: []u8, kind: u8, doc: bson.RawDocument) !void {
    var w: Io.Writer = .fixed(out);
    try (opmsg.Header{ .message_length = @intCast(out.len), .request_id = 1, .response_to = 0, .op_code = opmsg.op_code }).write(&w);
    try w.writeInt(u32, 0, .little);
    try w.writeByte(kind);
    try w.writeAll(doc.bytes);
}

test "a raw Peer accepts one client, reads its request and answers it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var peer = try io.concurrent(servePeer, .{ io, &listener });
    defer peer.cancel(io) catch {};
    try within5s(io, talkToPeer, .{ io, FakeServer.port(&listener) });
    try peer.await(io);
}

fn servePeer(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestNoRequest;
    defer request.deinit();
    try testing.expectEqualStrings("ping", (try request.body.first()).?.key);
    try peer.reply(&request, bson.literal(.{ .pong = true, .ok = 1.0 }));
    // The client hangs up: no request more.
    try testing.expect(try peer.readRequest(testing.allocator) == null);
}

fn talkToPeer(io: Io, port: u16) !void {
    var c: Client = undefined;
    try c.open(io, port);
    const reply = try c.command("admin", bson.literal(.{ .ping = 1 }));
    defer reply.deinit();
    try testing.expect((try reply.raw().get("pong")).?.boolean);
    c.close();
}

test "helloReply describes every type of server so that Hello.parse reads it back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const types = [_]wire.Hello.ServerType{ .standalone, .mongos, .rs_primary, .rs_secondary, .rs_arbiter, .rs_other, .rs_ghost };
    for (types) |server_type| {
        for ([_][]const u8{ "isMaster", "hello" }) |command| {
            const hello: wire.Hello = .{ .server_type = server_type, .max_wire_version = 29, .max_write_batch_size = 7, .logical_session_timeout_minutes = 30 };
            var body: bson.Builder = .init(a);
            try body.putInt32(command, 1);
            const doc = (try body.finish()).raw();
            const request: Script.Request = .{ .connection = 4, .name = command, .database = "admin", .body = doc, .sequence = null };
            const reply = try FakeServer.helloReply(testing.io, a, hello, &request);
            const parsed = try wire.Hello.parse(reply, null);
            try testing.expectEqual(server_type, parsed.server_type);
            try testing.expectEqual(@as(i32, 29), parsed.max_wire_version);
            try testing.expectEqual(@as(u32, 7), parsed.max_write_batch_size);
            try testing.expectEqual(@as(?i64, 4), parsed.connection_id);
            try testing.expectEqual(@as(?i64, 30), parsed.logical_session_timeout_minutes);
            const legacy = std.mem.eql(u8, command, "isMaster");
            try testing.expectEqual(legacy, try reply.get("ismaster") != null);
            try testing.expectEqual(!legacy, try reply.get("isWritablePrimary") != null);
            // helloOk only when the request asked for it.
            try testing.expect(try reply.get("helloOk") == null);
        }
    }
}

test "serve ends when canceled, and closes the connections it served" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &.{} };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    var canceled = false;
    defer if (!canceled) server.cancel(io) catch {};
    var c: Client = undefined;
    try c.open(io, FakeServer.port(&listener));
    defer c.close();
    (try c.command("admin", bson.literal(.{ .isMaster = 1 }))).deinit();
    canceled = true;
    try testing.expectError(error.Canceled, server.cancel(io));
    try within5s(io, Client.expectClosed, .{&c});
}
