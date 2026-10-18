//! One TCP connection to a mongod that sends hand-built OP_MSG requests
//! through `mongo.wire.opmsg` and reads their replies: the wire tools of
//! zefir-mongo against a real server, before any driver. One task uses it
//! at a time. It lives in the heap, since the reader and the writer of its
//! stream point into it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const mongo = @import("mongo");
const bson = mongo.bson;
const opmsg = mongo.wire.opmsg;
const RawConn = @This();

gpa: std.mem.Allocator,
stream: net.Stream,
reader: net.Stream.Reader,
writer: net.Stream.Writer,
read_buffer: [64 * 1024]u8,
write_buffer: [64 * 1024]u8,
next_id: i32 = 1,
/// What the server said in `handshake`, and the reply it is read from.
hello: mongo.wire.Hello = .{},
hello_reply: ?bson.OwnedDocument = null,

/// Connects to 127.0.0.1:`port`.
pub fn open(io: Io, gpa: std.mem.Allocator, port: u16) !*RawConn {
    const conn = try gpa.create(RawConn);
    errdefer gpa.destroy(conn);
    const address: net.IpAddress = try .parseIp4("127.0.0.1", port);
    conn.* = .{
        .gpa = gpa,
        .stream = try address.connect(io, .{ .mode = .stream }),
        .reader = undefined,
        .writer = undefined,
        .read_buffer = undefined,
        .write_buffer = undefined,
    };
    conn.reader = conn.stream.reader(io, &conn.read_buffer);
    conn.writer = conn.stream.writer(io, &conn.write_buffer);
    return conn;
}

pub fn close(conn: *RawConn, io: Io) void {
    if (conn.hello_reply) |reply| reply.deinit();
    conn.stream.close(io);
    conn.gpa.destroy(conn);
}

/// Sends `request`, with a requestID of its own, and returns the reply,
/// from `gpa`, checked by `opmsg.readReply` against the server's
/// maxMessageSizeBytes once `handshake` has read it.
pub fn exchange(conn: *RawConn, request: opmsg.Request, diagnostics: ?*mongo.Diagnostics) !bson.OwnedDocument {
    var numbered = request;
    numbered.request_id = conn.next_id;
    conn.next_id +%= 1;
    try opmsg.writeRequest(&conn.writer.interface, numbered);
    try conn.writer.interface.flush();
    return opmsg.readReply(&conn.reader.interface, conn.gpa, .{
        .request_id = numbered.request_id,
        .max_message_size = conn.hello.max_message_size_bytes,
    }, diagnostics);
}

/// Runs `body` in `database` and returns its reply after
/// `mongo.wire.checkReply` has passed it.
pub fn command(conn: *RawConn, database: []const u8, body: bson.RawDocument) !bson.OwnedDocument {
    const reply = try conn.exchange(.{ .request_id = 0, .body = body, .database = database }, null);
    errdefer reply.deinit();
    try mongo.wire.checkReply(reply.raw(), conn.gpa, null, null);
    return reply;
}

/// The first command of the connection, legacy hello as the handshake of
/// 2026 sends it: `{isMaster: 1, helloOk: true}` in admin. Its reply goes
/// into `hello`.
pub fn handshake(conn: *RawConn) !mongo.wire.Hello {
    const reply = try conn.command("admin", bson.literal(.{ .isMaster = 1, .helloOk = true }));
    errdefer reply.deinit();
    conn.hello = try mongo.wire.Hello.parse(reply.raw(), null);
    conn.hello_reply = reply;
    return conn.hello;
}
