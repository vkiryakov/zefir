//! `mongo.testing.FakeServer`: a MongoDB server for tests, on loopback, for
//! drivers that speak the wire protocol. It has two modes.
//!
//! `serve` plays a `Script`: it accepts connections, each in a task of its
//! own, answers hello by `script.hello`, and hands the commands to the
//! script's handler. A driver connects to `mongodb://127.0.0.1:<port>`,
//! without TLS and without credentials:
//!
//! ```zig
//! var listener = try FakeServer.listen(io);
//! defer listener.deinit(io);
//! var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
//! defer server.cancel(io) catch {};
//! var buffer: [64]u8 = undefined;
//! var driver: MyDriver = try .init(gpa, io, .{ .uri = try FakeServer.uri(&listener, &buffer) });
//! ```
//!
//! What the server answers itself, and what goes to the handler:
//!
//! - The first hello of a connection (`hello`, `isMaster` or `ismaster`)
//!   is its handshake: answered by `script.hello`, without
//!   `logicalSessionTimeoutMinutes` unless the script sets it, so that
//!   drivers with sessions start none, and not recorded.
//! - Every command after it is recorded in the script's journal. A later
//!   hello is answered by `script.hello`; `ping` and `endSessions` get
//!   `{ok: 1.0}`; `saslStart` and `saslContinue` fail with code 18, since
//!   the server has no users; a command without `$db` fails with code
//!   40414, as in mongod 8.0 and later. The handler answers the rest.
//! - A message that is not OP_MSG, OP_QUERY among them, or that breaks
//!   it, closes the connection.
//!
//! A raw `Peer` lets a protocol test play the server's side of one
//! connection itself: accept, read a request, answer it, byte by byte.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const Script = @import("Script.zig");

/// Listens on 127.0.0.1, on a port the system picks.
pub fn listen(io: Io) !net.Server {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return loopback.listen(io, .{ .reuse_address = true });
}

/// The port `listener` listens on.
pub fn port(listener: *const net.Server) u16 {
    return listener.socket.address.getPort();
}

/// The URI of `listener`, "mongodb://127.0.0.1:<port>", for a driver.
pub fn uri(listener: *const net.Server, buffer: []u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "mongodb://127.0.0.1:{d}", .{port(listener)});
}

/// Serves `script` on `listener` until canceled, which ends the
/// connections too: run it in a task of its own and cancel it at the end
/// of the test. While the script refuses connections, a new connection is
/// closed at once.
pub fn serve(io: Io, listener: *net.Server, script: *Script) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted, error.WouldBlock, error.ProtocolFailure, error.BlockedByFirewall => continue,
            else => return,
        };
        const number = script.openConnection() orelse {
            stream.close(io);
            continue;
        };
        group.concurrent(io, serveConnection, .{ io, stream, script, number }) catch stream.close(io);
    }
}

/// One connection of `serve`, in the heap: its reader and writer point into
/// it.
const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [16 * 1024]u8,
    /// The requestID of the next reply.
    next_id: i32 = 1,
};

fn serveConnection(io: Io, stream: net.Stream, script: *Script, number: u32) void {
    defer stream.close(io);
    const conn = script.allocator.create(Connection) catch return;
    defer script.allocator.destroy(conn);
    conn.* = .{ .stream = stream, .reader = undefined, .writer = undefined, .read_buffer = undefined, .write_buffer = undefined };
    conn.reader = stream.reader(io, &conn.read_buffer);
    conn.writer = stream.writer(io, &conn.write_buffer);
    var arena: std.heap.ArenaAllocator = .init(script.allocator);
    defer arena.deinit();
    var handshaken = false;
    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        // The end of the stream, a message that breaks OP_MSG, OP_QUERY
        // among them, or a canceled server: the connection ends.
        const incoming = opmsg.readRequest(&conn.reader.interface, a, script.hello.max_message_size_bytes, null) catch return;
        const request: Script.Request = .of(number, &incoming);
        const answers = incoming.flags & opmsg.flag_more_to_come == 0;
        if (!handshaken) {
            handshaken = true;
            if (isHello(request.name)) {
                const reply = helloReply(io, a, script.hello, &request) catch return;
                writeReply(conn, &incoming, reply) catch return;
                continue;
            }
        }
        script.record(io, &request) catch return;
        const built_in = ownAnswer(io, a, script, &request) catch return;
        const answer = if (built_in) |own| own else script.answer(io, a, &request) catch return;
        if (!answers) continue;
        switch (answer) {
            .reply => |reply| writeReply(conn, &incoming, reply) catch return,
            .delayed => |d| {
                io.sleep(d.after, .awake) catch return;
                writeReply(conn, &incoming, d.reply) catch return;
            },
            .close_connection => return,
            .refuse_connections => {
                script.refuseConnections();
                return;
            },
            .malformed => |defect| writeMalformed(conn, &incoming, defect) catch return,
        }
    }
}

fn isHello(name: []const u8) bool {
    return std.mem.eql(u8, name, "hello") or std.mem.eql(u8, name, "isMaster") or std.mem.eql(u8, name, "ismaster");
}

/// What `serve` answers itself to `request`, a command after the
/// handshake, or null for the commands it hands to the script's handler.
pub fn ownAnswer(io: Io, arena: Allocator, script: *Script, request: *const Script.Request) bson.Builder.Error!?Script.Answer {
    const name = request.name;
    if (request.database.len == 0) return .{ .reply = try Script.failure(arena, .{
        .code = 40414,
        .code_name = "IDLFailedToParse",
        .errmsg = try std.fmt.allocPrint(arena, "BSON field '{s}.$db' is missing but a required field", .{name}),
    }) };
    if (isHello(name)) return .{ .reply = try helloReply(io, arena, script.hello, request) };
    if (std.mem.eql(u8, name, "ping") or std.mem.eql(u8, name, "endSessions")) return .{ .reply = Script.ok };
    if (std.mem.eql(u8, name, "saslStart") or std.mem.eql(u8, name, "saslContinue")) return .{ .reply = no_users };
    return null;
}

const no_users = bson.literal(.{
    .ok = 0.0,
    .errmsg = "Authentication failed: mongo.testing.FakeServer has no users; connect without credentials",
    .code = 18,
    .codeName = "AuthenticationFailed",
});

/// The reply to the hello `request`, as mongod writes it, from `hello`:
/// `ismaster` for the legacy `isMaster`, `isWritablePrimary` for `hello`,
/// `helloOk` when the request asks for it, the flags of the server's type,
/// the limits, `localTime`, `connectionId` (the connection's number unless
/// `hello` names one), the wire versions and `ok`. `setName` is "rs0" for a
/// member of a replica set unless `hello` names one.
pub fn helloReply(io: Io, arena: Allocator, hello: wire.Hello, request: *const Script.Request) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(arena);
    const asks_hello_ok = if (request.body.get("helloOk") catch null) |value| value == .boolean and value.boolean else false;
    if (asks_hello_ok) try b.putBoolean("helloOk", true);
    const primary = switch (hello.server_type) {
        .standalone, .mongos, .rs_primary => true,
        else => false,
    };
    try b.putBoolean(if (std.mem.eql(u8, request.name, "hello")) "isWritablePrimary" else "ismaster", primary);
    switch (hello.server_type) {
        .standalone => {},
        .mongos => try b.putString("msg", "isdbgrid"),
        .rs_ghost => {
            try b.putBoolean("secondary", false);
            try b.putBoolean("isreplicaset", true);
        },
        .rs_primary, .rs_secondary, .rs_arbiter, .rs_other => |member| {
            try b.putString("setName", hello.set_name orelse "rs0");
            try b.putBoolean("secondary", member == .rs_secondary);
            if (member == .rs_arbiter) try b.putBoolean("arbiterOnly", true);
            if (member == .rs_other) try b.putBoolean("hidden", true);
        },
    }
    try putNumber(&b, "maxBsonObjectSize", hello.max_bson_object_size);
    try putNumber(&b, "maxMessageSizeBytes", hello.max_message_size_bytes);
    try putNumber(&b, "maxWriteBatchSize", hello.max_write_batch_size);
    try b.putDateTime("localTime", .now(io));
    if (hello.logical_session_timeout_minutes) |minutes| try putNumber(&b, "logicalSessionTimeoutMinutes", minutes);
    try putNumber(&b, "connectionId", hello.connection_id orelse request.connection);
    try b.putInt32("minWireVersion", hello.min_wire_version);
    try b.putInt32("maxWireVersion", hello.max_wire_version);
    try b.putBoolean("readOnly", false);
    try b.putDouble("ok", 1);
    return (try b.finish()).raw();
}

/// A number as mongod writes one: an int32 when it fits.
fn putNumber(b: *bson.Builder, key: []const u8, n: anytype) bson.Builder.Error!void {
    if (std.math.cast(i32, n)) |small| return b.putInt32(key, small);
    return b.putInt64(key, std.math.cast(i64, n) orelse std.math.maxInt(i64));
}

fn writeReply(conn: *Connection, request: *const opmsg.Incoming, reply: bson.RawDocument) !void {
    try opmsg.writeReply(&conn.writer.interface, conn.next_id, request.header.request_id, reply);
    conn.next_id +%= 1;
    try conn.writer.interface.flush();
}

/// A reply of `{ok: 1.0}` that breaks OP_MSG as `defect` says; the
/// connection stays open, so that a driver that uses it again shows in the
/// journal.
fn writeMalformed(conn: *Connection, request: *const opmsg.Incoming, defect: Script.Malformed) !void {
    const w = &conn.writer.interface;
    const body = Script.ok.bytes;
    // A section of kind 1 with one empty document.
    const sequence = "documents";
    const sequence_len = 4 + sequence.len + 1 + 5;
    var header: opmsg.Header = .{
        .message_length = @intCast(opmsg.header_len + 4 + 1 + body.len),
        .request_id = conn.next_id,
        .response_to = request.header.request_id,
        .op_code = opmsg.op_code,
    };
    conn.next_id +%= 1;
    var flags: u32 = 0;
    var doc = body;
    switch (defect) {
        .wrong_response_to => header.response_to = request.header.request_id +% 1,
        .unknown_required_flag => flags = 1 << 2,
        .sequence_in_reply => header.message_length += 1 + sequence_len,
        .truncated => {
            // The message ends 3 bytes before its document does.
            doc = body[0 .. body.len - 3];
            header.message_length -= 3;
        },
    }
    try header.write(w);
    try w.writeInt(u32, flags, .little);
    try w.writeByte(0);
    try w.writeAll(doc);
    if (defect == .sequence_in_reply) {
        try w.writeByte(1);
        try w.writeInt(i32, sequence_len, .little);
        try w.writeAll(sequence ++ "\x00");
        try w.writeAll(&.{ 5, 0, 0, 0, 0 });
    }
    try w.flush();
}

/// The server's side of one connection, played by the test itself. It
/// points into itself: initialize it in place with `accept`.
pub const Peer = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [16 * 1024]u8,
    /// The requestID of the next reply.
    next_id: i32,

    /// Waits for one client.
    pub fn accept(peer: *Peer, io: Io, listener: *net.Server) !void {
        const stream = try listener.accept(io);
        peer.io = io;
        peer.stream = stream;
        peer.reader = stream.reader(io, &peer.read_buffer);
        peer.writer = stream.writer(io, &peer.write_buffer);
        peer.next_id = 1;
    }

    pub fn close(peer: *Peer) void {
        peer.stream.close(peer.io);
    }

    /// The next request, checked as `opmsg.readRequest` checks it, from
    /// `allocator`; free it with `deinit`. Null when the client hung up.
    pub fn readRequest(peer: *Peer, allocator: Allocator) !?opmsg.Incoming {
        return opmsg.readRequest(&peer.reader.interface, allocator, opmsg.default_max_message_size, null) catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => switch (peer.reader.err orelse error.Unexpected) {
                error.ConnectionResetByPeer => null,
                else => |e| e,
            },
            else => |e| e,
        };
    }

    /// Answers `request` with `reply`.
    pub fn reply(peer: *Peer, request: *const opmsg.Incoming, doc: bson.RawDocument) !void {
        try opmsg.writeReply(&peer.writer.interface, peer.next_id, request.header.request_id, doc);
        peer.next_id +%= 1;
        try peer.writer.interface.flush();
    }

    /// Writes `bytes` as they are, such as a message that breaks OP_MSG.
    pub fn send(peer: *Peer, bytes: []const u8) !void {
        try peer.writer.interface.writeAll(bytes);
        try peer.writer.interface.flush();
    }

    /// Reads until the client closes the connection; returns how many
    /// bytes came.
    pub fn readToEnd(peer: *Peer) !usize {
        var total: usize = 0;
        while (true) {
            const n = peer.reader.interface.discard(.unlimited) catch |err| switch (err) {
                error.EndOfStream => return total,
                else => |e| return e,
            };
            total += n;
        }
    }
};
