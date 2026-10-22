//! `redis.testing.FakeServer.Peer`: the server's side of a connection,
//! played by the test itself, byte by byte: for protocol tests of a
//! client, such as the bytes of its handshake, or a reply that no script
//! writes. It listens on 127.0.0.1, accepts one client at a time, reads its
//! commands as Redis does and writes whatever bytes the test gives.
//!
//! ```zig
//! var peer: FakeServer.Peer = try .listen(io);
//! defer peer.close(io);
//! // ... a client connects to peer.url(), in a task of its own ...
//! try peer.accept(io);
//! const hello = (try peer.readCommand(arena)).?; // { "HELLO", "3" }
//! try peer.send("-ERR unknown command 'HELLO'\r\n");
//! ```
//!
//! Once it accepts, it points into itself: keep it in place.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const command = @import("command.zig");

const Peer = @This();

/// Null once closed.
listener: ?net.Server,
url_buffer: [32]u8,
url_len: usize,
/// The connection accepted last, while open.
stream: ?net.Stream = null,
reader: net.Stream.Reader = undefined,
writer: net.Stream.Writer = undefined,
read_buffer: [16 * 1024]u8 = undefined,
write_buffer: [16 * 1024]u8 = undefined,

/// Listens on 127.0.0.1, on a port the system picks.
pub fn listen(io: Io) !Peer {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var peer: Peer = .{
        .listener = try loopback.listen(io, .{ .reuse_address = true }),
        .url_buffer = undefined,
        .url_len = 0,
    };
    const port = peer.listener.?.socket.address.getPort();
    peer.url_len = (std.fmt.bufPrint(&peer.url_buffer, "redis://127.0.0.1:{d}", .{port}) catch unreachable).len;
    return peer;
}

/// "redis://127.0.0.1:<port>", for a client.
pub fn url(peer: *const Peer) []const u8 {
    return peer.url_buffer[0..peer.url_len];
}

/// Waits for the next client. The connection accepted before, if still
/// open, is closed first: a client that opens a new connection, after a
/// lost one say, gets the peer's whole attention.
pub fn accept(peer: *Peer, io: Io) !void {
    peer.closeConnection(io);
    const listener = if (peer.listener) |*open| open else return error.SocketNotListening;
    const stream = try listener.accept(io);
    peer.stream = stream;
    peer.reader = stream.reader(io, &peer.read_buffer);
    peer.writer = stream.writer(io, &peer.write_buffer);
}

/// The next command of the client, its arguments, the name first, in
/// `arena`; null when the client has hung up. Bytes that are not a
/// command, an array of bulk strings, are a ProtocolViolation.
pub fn readCommand(peer: *Peer, arena: Allocator) !?[]const []const u8 {
    if (peer.stream == null) return error.NotConnected;
    return command.read(&peer.reader.interface, arena) catch |err| switch (err) {
        error.ReadFailed => switch (peer.reader.err orelse error.Unexpected) {
            error.ConnectionResetByPeer => null,
            else => |e| e,
        },
        else => |e| e,
    };
}

/// Writes `bytes` as they are, at once.
pub fn send(peer: *Peer, bytes: []const u8) !void {
    if (peer.stream == null) return error.NotConnected;
    try peer.writer.interface.writeAll(bytes);
    try peer.writer.interface.flush();
}

/// Reads until the client closes the connection; returns how many bytes
/// came, those read ahead by `readCommand` and not taken included.
pub fn readToEnd(peer: *Peer) !usize {
    if (peer.stream == null) return error.NotConnected;
    const in = &peer.reader.interface;
    var total: usize = 0;
    while (true) {
        const buffered = in.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return total,
            error.ReadFailed => switch (peer.reader.err orelse error.Unexpected) {
                error.ConnectionResetByPeer => return total,
                else => |e| return e,
            },
        };
        total += buffered.len;
        in.toss(buffered.len);
    }
}

/// Closes the connection and stops listening. Idempotent.
pub fn close(peer: *Peer, io: Io) void {
    peer.closeConnection(io);
    if (peer.listener) |*listener| listener.deinit(io);
    peer.listener = null;
}

fn closeConnection(peer: *Peer, io: Io) void {
    const stream = peer.stream orelse return;
    stream.close(io);
    peer.stream = null;
}
