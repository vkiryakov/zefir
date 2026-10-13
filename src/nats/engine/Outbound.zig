//! The outbound queue: frames waiting for the writer, in order. A frame is
//! copied once, into a chunk; the writer sends whole chunks in batches.
//!
//! `limits.outbound_bytes` is a soft limit: a frame waits for room while
//! the queue holds that much or more, and is then taken whole, so a frame
//! of any size gets in once the queue drains below the limit. PINGs skip
//! the limit but keep their place in line. PONGs owed to the server go out
//! before the next batch, outside the queue.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const encoder = @import("../protocol/encoder.zig");
const time = @import("time.zig");
const Outbound = @This();

pub const Kind = enum {
    /// PUB or HPUB of a publish or a reply.
    publish,
    /// PUB or HPUB of a request; it is dropped when the connection is lost.
    request,
    /// SUB and UNSUB; the subscriptions restore them after a reconnect.
    service,
    /// PING; it skips the limit.
    ping,
};

/// A frame in the queue.
pub const Frame = struct {
    kind: Kind,
    len: usize,
    /// Bytes of it the socket already took: only the first frame in the
    /// queue can have some.
    written: usize = 0,
};

pub const PingKind = enum { flush, heartbeat };

/// What `take` lends the writer.
pub const Batch = struct {
    slices: []const []const u8,
    /// The bytes of all slices.
    len: usize,
};

pub const PutError = error{ Closed, Canceled, OutOfMemory, ProtocolError };
pub const WaitError = error{ Closed, Timeout, Canceled };

/// The size of a chunk; a larger frame gets a chunk of its own size.
pub const chunk_size = 64 * 1024;

const Chunk = struct {
    bytes: []u8,
    /// Bytes the socket took.
    head: usize = 0,
    /// Bytes filled.
    tail: usize = 0,
};

/// What a frame's record costs on top of its bytes.
const record_cost = @sizeOf(Frame);
/// The most PONGs sent in one batch.
const max_pongs_per_batch = 16;
const pong_run: [max_pongs_per_batch * encoder.pong.len]u8 = run: {
    var bytes: [max_pongs_per_batch * encoder.pong.len]u8 = undefined;
    for (0..max_pongs_per_batch) |i| @memcpy(bytes[i * encoder.pong.len ..][0..encoder.pong.len], encoder.pong);
    break :run bytes;
};

gpa: Allocator,
/// Frames other than PINGs wait while `queued` is at least this.
limit: usize,
mutex: Io.Mutex = .init,
/// Signaled when the queue drops below the limit.
room: Io.Condition = .init,
/// Signaled when there is something to write.
ready: Io.Condition = .init,
/// Signaled when a PONG arrives.
answered: Io.Condition = .init,
/// The bytes of the frames, oldest first.
chunks: std.Deque(*Chunk) = .empty,
/// An empty chunk kept for the next frames.
spare: ?*Chunk = null,
/// The frames in `chunks`, oldest first.
frames: std.Deque(Frame) = .empty,
/// What the frames other than PINGs cost: their bytes and their records.
queued: usize = 0,
/// Puts waiting for room.
room_waiters: u32 = 0,
/// PONGs owed to the server.
pongs_owed: u32 = 0,
/// PONGs in the batch the writer has.
pongs_in_flight: u32 = 0,
/// PINGs queued and PONGs received: PONG number n answers PING number n.
pings_queued: u64 = 0,
pongs_received: u64 = 0,
/// Heartbeat PINGs since the last PONG.
pings_out: u32 = 0,
closed: bool = false,

pub fn init(gpa: Allocator, limit: usize) Outbound {
    return .{ .gpa = gpa, .limit = limit };
}

/// Frees whatever is queued. The writer must have stopped.
pub fn deinit(q: *Outbound) void {
    while (q.chunks.popFront()) |chunk| q.destroyChunk(chunk);
    q.chunks.deinit(q.gpa);
    if (q.spare) |chunk| q.destroyChunk(chunk);
    q.frames.deinit(q.gpa);
    q.* = undefined;
}

/// Queues one frame of exactly `len` bytes, written by
/// `encode(writer, args...)`. Unless it is a PING, it waits while the queue
/// is full; the wait can be canceled.
pub fn put(q: *Outbound, io: Io, kind: Kind, len: usize, encode: anytype, args: anytype) PutError!void {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    if (kind != .ping) try q.awaitRoom(io);
    if (q.closed) return error.Closed;
    const chunk = try q.reserve(len);
    var w: Writer = .fixed(chunk.bytes[chunk.tail..][0..len]);
    // `len` comes from the encoder's *Len twin; a frame of another length
    // would break the stream, so it is refused.
    @call(.auto, encode, .{&w} ++ args) catch return error.ProtocolError;
    if (w.end != len) return error.ProtocolError;
    q.commit(chunk, kind, len);
    q.ready.signal(io);
}

fn awaitRoom(q: *Outbound, io: Io) Io.Cancelable!void {
    q.room_waiters += 1;
    defer q.room_waiters -= 1;
    while (!q.closed and q.queued >= q.limit) try q.room.wait(io, &q.mutex);
}

/// Queues a PING and returns its number. It skips the limit; PONG number n
/// answers PING number n.
pub fn putPing(q: *Outbound, io: Io, kind: PingKind) error{ Closed, OutOfMemory }!u64 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.closed) return error.Closed;
    const chunk = try q.reserve(encoder.ping.len);
    @memcpy(chunk.bytes[chunk.tail..][0..encoder.ping.len], encoder.ping);
    q.commit(chunk, .ping, encoder.ping.len);
    q.pings_queued += 1;
    if (kind == .heartbeat) q.pings_out +|= 1;
    q.ready.signal(io);
    return q.pings_queued;
}

/// A PONG came: it answers the oldest PING still unanswered.
pub fn pongReceived(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    q.pongs_received += 1;
    q.pings_out = 0;
    q.answered.broadcast(io);
}

/// Waits until PING number `ping` is answered, `deadline` passes or the
/// queue closes.
pub fn waitPong(q: *Outbound, io: Io, ping: u64, deadline: ?Io.Clock.Timestamp) WaitError!void {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    while (q.pongs_received < ping) {
        if (q.closed) return error.Closed;
        try q.answered.waitTimeout(io, &q.mutex, time.until(deadline));
    }
}

/// Heartbeat PINGs sent since the last PONG.
pub fn pingsOut(q: *Outbound, io: Io) u32 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.pings_out;
}

/// The server sent PING: a PONG goes out before the next batch.
pub fn queuePong(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.closed) return;
    q.pongs_owed +|= 1;
    q.ready.signal(io);
}

/// For the writer: waits for something to write and lends it out, PONGs
/// first, then whole frames, at most `slices.len` slices. Null once the
/// queue is closed: what is left is not sent. Call `written` before the
/// next `take`.
pub fn take(q: *Outbound, io: Io, slices: [][]const u8) Io.Cancelable!?Batch {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    while (!q.closed and q.pongs_owed == 0 and q.frames.len == 0) try q.ready.wait(io, &q.mutex);
    if (q.closed) return null;
    var count: usize = 0;
    var len: usize = 0;
    q.pongs_in_flight = if (slices.len > 0) @min(q.pongs_owed, max_pongs_per_batch) else 0;
    if (q.pongs_in_flight > 0) {
        slices[0] = pong_run[0 .. q.pongs_in_flight * encoder.pong.len];
        len = slices[0].len;
        count = 1;
    }
    var chunks = q.chunks.iterator();
    while (count < slices.len) {
        const chunk = chunks.next() orelse break;
        if (chunk.head == chunk.tail) continue;
        slices[count] = chunk.bytes[chunk.head..chunk.tail];
        len += slices[count].len;
        count += 1;
    }
    return .{ .slices = slices[0..count], .len = len };
}

/// For the writer: the socket took the first `n` bytes of the last batch.
pub fn written(q: *Outbound, io: Io, n: usize) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    const pong_bytes = q.pongs_in_flight * encoder.pong.len;
    q.pongs_owed -= @intCast(@min(n, pong_bytes) / encoder.pong.len);
    q.pongs_in_flight = 0;
    var left = n -| pong_bytes;
    while (left > 0) {
        const chunk = q.chunks.front() orelse break;
        const step = @min(left, chunk.tail - chunk.head);
        if (step == 0) break;
        chunk.head += step;
        left -= step;
        q.dropWritten(step);
        if (chunk.head < chunk.tail) break;
        if (q.chunks.len > 1) {
            _ = q.chunks.popFront();
            q.recycle(chunk);
        } else {
            chunk.head = 0;
            chunk.tail = 0;
        }
    }
    if (q.queued < q.limit) q.room.broadcast(io);
}

/// Copies the queued frames, oldest first, into `out` as far as it holds
/// them.
pub fn unsent(q: *Outbound, io: Io, out: []Frame) []Frame {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    var frames = q.frames.iterator();
    var count: usize = 0;
    while (count < out.len) : (count += 1) out[count] = frames.next() orelse break;
    return out[0..count];
}

/// Refuses new frames and wakes everyone: waiting puts and PING waiters get
/// Closed, the writer gets null.
pub fn close(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    q.closed = true;
    q.room.broadcast(io);
    q.ready.broadcast(io);
    q.answered.broadcast(io);
}

/// A chunk with room for `len` bytes after its tail: the last one, or a
/// new one at the end.
fn reserve(q: *Outbound, len: usize) error{OutOfMemory}!*Chunk {
    try q.frames.ensureUnusedCapacity(q.gpa, 1);
    if (q.chunks.back()) |last| {
        if (last.bytes.len - last.tail >= len) return last;
        // An empty chunk too small for this frame must not stay in front
        // of the new one.
        if (last.head == last.tail) {
            _ = q.chunks.popBack();
            q.recycle(last);
        }
    }
    const chunk = try q.createChunk(len);
    q.chunks.pushBack(q.gpa, chunk) catch |err| {
        q.recycle(chunk);
        return err;
    };
    return chunk;
}

fn commit(q: *Outbound, chunk: *Chunk, kind: Kind, len: usize) void {
    chunk.tail += len;
    q.frames.pushBackAssumeCapacity(.{ .kind = kind, .len = len });
    if (kind != .ping) q.queued += len + record_cost;
}

/// Marks `bytes` more of the oldest frames written and forgets those the
/// socket took whole.
fn dropWritten(q: *Outbound, bytes: usize) void {
    var left = bytes;
    while (left > 0) {
        const frame = q.frames.frontPtr() orelse return;
        const rest = frame.len - frame.written;
        if (left < rest) {
            frame.written += left;
            return;
        }
        left -= rest;
        if (frame.kind != .ping) q.queued -= frame.len + record_cost;
        _ = q.frames.popFront();
    }
}

fn createChunk(q: *Outbound, len: usize) error{OutOfMemory}!*Chunk {
    if (len <= chunk_size) {
        if (q.spare) |chunk| {
            q.spare = null;
            return chunk;
        }
    }
    const chunk = try q.gpa.create(Chunk);
    errdefer q.gpa.destroy(chunk);
    chunk.* = .{ .bytes = try q.gpa.alloc(u8, @max(len, chunk_size)) };
    return chunk;
}

/// Keeps an emptied chunk of the usual size as the spare, frees others.
fn recycle(q: *Outbound, chunk: *Chunk) void {
    if (q.spare == null and chunk.bytes.len == chunk_size) {
        chunk.head = 0;
        chunk.tail = 0;
        q.spare = chunk;
    } else {
        q.destroyChunk(chunk);
    }
}

fn destroyChunk(q: *Outbound, chunk: *Chunk) void {
    q.gpa.free(chunk.bytes);
    q.gpa.destroy(chunk);
}

fn roomWaiters(q: *Outbound, io: Io) u32 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.room_waiters;
}

const testing = std.testing;

fn writePub(w: *Writer, subject: []const u8, payload: []const u8) Writer.Error!void {
    return encoder.writePub(w, subject, null, payload);
}

fn putPub(q: *Outbound, io: Io, kind: Kind, subject: []const u8, payload: []const u8) PutError!void {
    return q.put(io, kind, encoder.pubLen(subject, null, payload.len), writePub, .{ subject, payload });
}

/// Takes one batch, appends its bytes to `out` and marks them written.
fn drainOnce(q: *Outbound, io: Io, out: *std.ArrayList(u8)) !void {
    var slices: [16][]const u8 = undefined;
    const batch = (try q.take(io, &slices)) orelse return error.TestClosed;
    var len: usize = 0;
    for (batch.slices) |slice| {
        try out.appendSlice(testing.allocator, slice);
        len += slice.len;
    }
    try testing.expectEqual(len, batch.len);
    q.written(io, batch.len);
}

fn awaitRoomWaiter(q: *Outbound, io: Io) !void {
    const give_up = time.after(io, .fromSeconds(5));
    while (q.roomWaiters(io) == 0) {
        if (time.expired(io, give_up)) return error.TestPutNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "frames come out whole and in order, PONGs first" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1");
    try putPub(&q, io, .request, "b", "22");
    try testing.expectEqual(1, try q.putPing(io, .flush));
    q.queuePong(io);
    q.queuePong(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PONG\r\nPONG\r\nPUB a 1\r\n1\r\nPUB b 2\r\n22\r\nPING\r\n", out.items);
    var frames: [4]Frame = undefined;
    try testing.expectEqual(0, q.unsent(io, &frames).len);
}

test "a frame larger than a chunk, among small ones in many chunks" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 24);
    defer q.deinit();
    const big = try testing.allocator.alloc(u8, chunk_size + 100);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    var subject_buffer: [16]u8 = undefined;
    for (0..3000) |i| {
        const subject = try std.fmt.bufPrint(&subject_buffer, "s.{d}", .{i});
        const payload: []const u8 = if (i == 1500) big else "payload";
        try putPub(&q, io, .publish, subject, payload);
        var w: Writer.Allocating = .init(testing.allocator);
        defer w.deinit();
        try encoder.writePub(&w.writer, subject, null, payload);
        try expected.appendSlice(testing.allocator, w.written());
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    while (out.items.len < expected.items.len) try drainOnce(&q, io, &out);
    try testing.expectEqualSlices(u8, expected.items, out.items);
}

fn putLater(q: *Outbound, io: Io) PutError!void {
    return putPub(q, io, .publish, "late", "x");
}

test "a full queue makes put wait until the writer takes frames" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 64);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    try putPub(&q, io, .publish, "second", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try putter.await(io);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPUB second 10\r\n0123456789\r\nPUB late 1\r\nx\r\n", out.items);
}

test "a canceled put queues nothing" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);
    try testing.expectError(error.Canceled, putter.cancel(io));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(1, q.unsent(io, &frames).len);
}

test "PINGs skip the limit but keep their place" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1");
    try testing.expectEqual(1, try q.putPing(io, .flush));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB a 1\r\n1\r\nPING\r\n", out.items);
}

fn takeOne(q: *Outbound, io: Io) Io.Cancelable!?Batch {
    var slices: [4][]const u8 = undefined;
    return q.take(io, &slices);
}

fn waitFirstPong(q: *Outbound, io: Io) WaitError!void {
    return q.waitPong(io, 1, null);
}

test "close wakes a waiting put, the writer and PING waiters" {
    const io = testing.io;
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        try putPub(&q, io, .publish, "first", "0123456789");
        var putter = try io.concurrent(putLater, .{ &q, io });
        defer putter.cancel(io) catch {};
        try awaitRoomWaiter(&q, io);
        q.close(io);
        try testing.expectError(error.Closed, putter.await(io));
        try testing.expectError(error.Closed, putPub(&q, io, .publish, "after", "close"));
        try testing.expectError(error.Closed, q.putPing(io, .flush));
    }
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        var writer = try io.concurrent(takeOne, .{ &q, io });
        defer _ = writer.cancel(io) catch null;
        try io.sleep(.fromMilliseconds(10), .awake);
        q.close(io);
        try testing.expect(try writer.await(io) == null);
    }
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        _ = try q.putPing(io, .flush);
        var waiter = try io.concurrent(waitFirstPong, .{ &q, io });
        defer waiter.cancel(io) catch {};
        try io.sleep(.fromMilliseconds(10), .awake);
        q.close(io);
        try testing.expectError(error.Closed, waiter.await(io));
    }
}

test "PINGs are numbered and each PONG answers the oldest" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    try testing.expectEqual(1, try q.putPing(io, .flush));
    try testing.expectEqual(2, try q.putPing(io, .heartbeat));
    try testing.expectEqual(1, q.pingsOut(io));
    try testing.expectError(error.Timeout, q.waitPong(io, 1, time.after(io, .zero)));

    q.pongReceived(io);
    try q.waitPong(io, 1, null);
    try testing.expectEqual(0, q.pingsOut(io));
    try testing.expectError(error.Timeout, q.waitPong(io, 2, time.after(io, .fromMilliseconds(10))));
    q.pongReceived(io);
    try q.waitPong(io, 2, time.after(io, .fromSeconds(5)));
}

test "a partial write marks the frame it stopped in" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1"); // 12 bytes
    _ = try q.putPing(io, .heartbeat); // 6 bytes
    try putPub(&q, io, .request, "b", "2");

    var slices: [4][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    try testing.expectEqual(30, batch.len);
    q.written(io, 12 + 2);
    var frames: [4]Frame = undefined;
    const left = q.unsent(io, &frames);
    try testing.expectEqual(2, left.len);
    try testing.expectEqual(Frame{ .kind = .ping, .len = 6, .written = 2 }, left[0]);
    try testing.expectEqual(Frame{ .kind = .request, .len = 12, .written = 0 }, left[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("NG\r\nPUB b 1\r\n2\r\n", out.items);
}

fn exercise(gpa: Allocator) !void {
    const io = testing.io;
    var q: Outbound = .init(gpa, 1 << 20);
    defer q.deinit();
    const big = try gpa.alloc(u8, chunk_size + 1);
    defer gpa.free(big);
    @memset(big, 'y');
    for (0..20) |i| {
        try putPub(&q, io, if (i % 2 == 0) .publish else .request, "s", if (i == 10) big else "p");
        if (i % 7 == 0) _ = try q.putPing(io, .flush);
    }
    var slices: [16][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    q.written(io, batch.len / 2);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, exercise, .{});
}
