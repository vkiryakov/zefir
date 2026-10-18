//! What the watcher of a request sees on its socket. The watcher reads the
//! socket while the handler runs: a client that leaves (or half-closes
//! after its request) must end the read at once, canceling the watcher must
//! end it with `error.Canceled` before the socket closes, and the bytes of
//! the next request that it reads ahead must stay for that request. When
//! the server stops, `shutdown(.recv)` on an idle connection must wake its
//! blocked read; if it does not on some system, the server races the read
//! with its stop event instead.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const runtime = @import("runtime");
const probes = @import("root.zig");

/// How a read of the watcher ended, and when.
const ReadEnd = struct {
    result: net.Stream.Reader.Error!usize,
    ended: Io.Timestamp,
};

fn readEnd(io: Io, stream: net.Stream) ReadEnd {
    var buffer: [64]u8 = undefined;
    const result = probes.readSome(io, stream, &buffer);
    return .{ .result = result, .ended = probes.now(io) };
}

test "a blocked read ends with EndOfStream within 5 ms when the peer closes" {
    try runtime.forEachRuntime(testing.allocator, peerCloses);
}

fn peerCloses(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.server.close(io);
    var reader = try io.concurrent(readEnd, .{ io, pair.server });
    try io.sleep(.fromMilliseconds(50), .awake);
    const closed = probes.now(io);
    pair.client.close(io);
    const end = reader.await(io);
    const took = closed.durationTo(end.ended);
    probes.report("blocked read, peer closes: {s} after {d:.2} ms", .{ endName(end.result), probes.ms(took) });
    try testing.expectEqual(0, try end.result);
    try testing.expect(probes.ms(took) < 5);
}

test "a peer that half-closes after its request looks the same: EndOfStream" {
    try runtime.forEachRuntime(testing.allocator, peerHalfCloses);
}

fn peerHalfCloses(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    const request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    try probes.send(io, pair.client, request);
    try pair.client.shutdown(io, .send);
    var buffer: [128]u8 = undefined;
    var got: usize = 0;
    while (got < request.len) {
        const n = try probes.readSome(io, pair.server, buffer[got..]);
        if (n == 0) return error.TestEndBeforeRequest;
        got += n;
    }
    try testing.expectEqualStrings(request, buffer[0..got]);
    const start = probes.now(io);
    const after = probes.readSome(io, pair.server, &buffer);
    const took = probes.since(io, start);
    probes.report("read after the request of a half-closed peer: {s} after {d:.2} ms", .{ endName(after), probes.ms(took) });
    try testing.expectEqual(0, try after);
    try testing.expect(probes.ms(took) < 5);
}

test "canceling the reader returns Canceled; closing the socket after the join is safe" {
    try runtime.forEachRuntime(testing.allocator, cancelReader);
}

fn cancelReader(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.client.close(io);
    var reader = try io.concurrent(readEnd, .{ io, pair.server });
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = probes.now(io);
    const end = reader.cancel(io);
    const took = probes.since(io, start);
    // The reader has finished: nothing reads the socket any more.
    pair.server.close(io);
    probes.report("blocked read canceled: {s} after {d:.2} ms; then the socket closed", .{ endName(end.result), probes.ms(took) });
    try testing.expectError(error.Canceled, end.result);
    try testing.expect(probes.ms(took) < 5);
    // The client sees the close.
    var buffer: [64]u8 = undefined;
    const seen = probes.raceRead(io, pair.client, &buffer, .fromSeconds(1)) catch |err| switch (err) {
        error.ConnectionResetByPeer => 0,
        else => |e| return e,
    };
    try testing.expectEqual(0, seen);
}

test "shutdown(.recv) by the owner wakes a blocked read with EndOfStream" {
    try runtime.forEachRuntime(testing.allocator, shutdownWakes);
}

fn shutdownWakes(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    const Wake = union(enum) {
        read: ReadEnd,
        timer: Io.Cancelable!void,
    };
    var results: [2]Wake = undefined;
    var select: Io.Select(Wake) = .init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.read, readEnd, .{ io, pair.server });
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = probes.now(io);
    try pair.server.shutdown(io, .recv);
    // A read that shutdown does not wake would wait forever.
    try select.concurrent(.timer, Io.sleep, .{ io, .fromSeconds(1), .awake });
    switch (try select.await()) {
        .read => |end| {
            const took = start.durationTo(end.ended);
            probes.report("blocked read, shutdown(.recv) by the owner: {s} after {d:.2} ms", .{ endName(end.result), probes.ms(took) });
            try testing.expectEqual(0, try end.result);
            try testing.expect(probes.ms(took) < 5);
        },
        .timer => {
            probes.report("blocked read, shutdown(.recv) by the owner: still blocked after 1 s", .{});
            return error.TestReadNotWoken;
        },
    }
}

test "read-ahead keeps the next request's bytes and stops when its buffer is full" {
    try runtime.forEachRuntime(testing.allocator, readAheadStops);
}

/// What the client sends: more than the read-ahead buffer holds.
const payload: [100]u8 = payload: {
    var bytes: [100]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = 'a' + i % 26;
    break :payload bytes;
};

const ReadAhead = struct {
    filled: usize,
    reason: enum { deadline, end_of_stream },
};

/// The watcher's read-ahead: reads into `buffer` until it is full, then
/// reads no more and waits for `deadline`. The bytes are there before it
/// starts, so its reads do not wait; how a read waits until a deadline is
/// what timeouts.zig probes.
fn readAhead(io: Io, stream: net.Stream, buffer: []u8, deadline: Io.Clock.Timestamp) !ReadAhead {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try probes.readSome(io, stream, buffer[filled..]);
        if (n == 0) return .{ .filled = filled, .reason = .end_of_stream };
        filled += n;
    }
    try deadline.wait(io);
    return .{ .filled = filled, .reason = .deadline };
}

fn readAheadStops(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    try probes.send(io, pair.client, &payload);
    try io.sleep(.fromMilliseconds(20), .awake);
    var buffer: [64]u8 = undefined;
    const start = probes.now(io);
    const ahead = try readAhead(io, pair.server, &buffer, .fromNow(io, .{ .raw = .fromMilliseconds(100), .clock = .awake }));
    const took = probes.since(io, start);
    // The rest waits in the socket for the next read.
    var rest: [64]u8 = undefined;
    var rest_len: usize = 0;
    while (rest_len < payload.len - ahead.filled) {
        const n = try probes.readSome(io, pair.server, rest[rest_len..]);
        if (n == 0) break;
        rest_len += n;
    }
    probes.report("read-ahead into 64 bytes of 100 sent: {d} kept, stopped by the {t} after {d:.2} ms, {d} left in the socket", .{ ahead.filled, ahead.reason, probes.ms(took), rest_len });
    try testing.expectEqual(.deadline, ahead.reason);
    try testing.expectEqualSlices(u8, payload[0..64], buffer[0..ahead.filled]);
    try probes.expectWithin(took, 99, 150);
    try testing.expectEqualSlices(u8, payload[64..], rest[0..rest_len]);
}

/// The name of how a read ended, for `report`.
fn endName(result: net.Stream.Reader.Error!usize) []const u8 {
    const n = result catch |err| return @errorName(err);
    return if (n == 0) "EndOfStream" else "data";
}
