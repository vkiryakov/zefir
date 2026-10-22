//! The server's side of a connection for the client's tests, played on a
//! `FakeServer.Peer`: a handshake as Redis 8.10.2 answers it, and the
//! commands that come after it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("../root.zig");
const Peer = redis.testing.FakeServer.Peer;
const replies = @import("hello_replies.zig");

/// Reads HELLO, answers it after `delay`, then reads CLIENT SETINFO twice
/// and answers both: the handshake of a client without a database.
pub fn shakeHands(peer: *Peer, io: Io, delay: Io.Duration) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hello = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("HELLO", hello[0]);
    try redis.testing.sleepAtLeast(io, delay);
    try peer.send(replies.redis_8_10_2);
    for (0..2) |_| _ = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try peer.send("+OK\r\n+OK\r\n");
}

/// Reads the next command and checks that it is `expected`.
pub fn expectCommand(peer: *Peer, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = (try peer.readCommand(arena.allocator())) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, arg| try testing.expectEqualStrings(want, arg);
}
