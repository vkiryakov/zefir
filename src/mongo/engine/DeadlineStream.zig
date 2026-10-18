//! A TCP stream whose reads and writes wait no longer than the deadline of
//! the exchange in progress: std's `net.Stream.Reader` and
//! `net.Stream.Writer` with `io.operateTimeout` where they call
//! `io.operate`. `begin` sets the deadline before an exchange; a read or a
//! write that reaches it fails, and `err` is `error.Timeout`.
//!
//! A stream is cut for good, by its deadline or by its owner from another
//! task (`cut`): the socket is shut down, and from then on every read and
//! write fails with the error of the cut, `error.Timeout` or
//! `error.Stopped`, whatever the socket says. Most systems end the stream
//! of a socket that their own side shut down; Windows answers
//! `error.Unexpected` instead, and that is no error of the network.
//!
//! An `Io` whose `operateTimeout` cannot time an operation, and says
//! `error.ConcurrencyUnavailable`, as std's on Windows, keeps the deadline
//! and the cut too: every operation, with a deadline or without, then runs
//! in a task of its own, and the wait for it ends at the deadline, which
//! cuts the stream, or at a cut; then that task is canceled. Windows does
//! not end a read that waits on a socket its own side shut down, but the
//! cancelation of its task does.
//!
//! It points into itself: `init` it in place, in an object that does not
//! move.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const core = @import("core");
const time = @import("time.zig");
const race = @import("race.zig");
const DeadlineStream = @This();

io: Io,
stream: net.Stream,
/// The deadline of the exchange in progress; null for none.
deadline: ?core.Deadline = null,
/// Why the last read or write failed: `error.Timeout`, `error.Stopped`,
/// `error.Canceled`, or an error of the socket.
err: ?Error = null,
/// Who cut the stream, if anybody did; set once, from any task.
cut_by: std.atomic.Value(Cut) = .init(.none),
/// Set once the stream is cut: it ends the wait for an operation in a
/// task of its own.
cut_event: Io.Event = .unset,
reader: Io.Reader,
writer: Io.Writer,

pub const Error = Io.Operation.NetRead.Error || Io.Operation.NetWrite.Error || error{ Timeout, Stopped, Canceled, ConcurrencyUnavailable };

/// Who cut a stream.
pub const Cut = enum(u8) {
    none,
    /// The timer of the deadline: `error.Timeout`.
    deadline,
    /// The owner, through `cut`: `error.Stopped`.
    stop,
};

const max_iovecs_len = 8;

pub fn init(ds: *DeadlineStream, io: Io, stream: net.Stream, read_buffer: []u8, write_buffer: []u8) void {
    ds.* = .{
        .io = io,
        .stream = stream,
        .reader = .{ .vtable = &.{ .stream = streamImpl, .readVec = readVec }, .buffer = read_buffer, .seek = 0, .end = 0 },
        .writer = .{ .vtable = &.{ .drain = drain }, .buffer = write_buffer },
    };
}

/// Starts an exchange that must end by `deadline`; null for none.
pub fn begin(ds: *DeadlineStream, deadline: ?core.Deadline) void {
    ds.deadline = deadline;
    ds.err = null;
}

/// Shuts `stream` down both ways, from any task: a read blocked on it
/// ends and a blocked write fails, whether or not its task still sees
/// cancelation. The socket stays open for its owner to close.
fn shutdown(io: Io, stream: net.Stream) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    stream.shutdown(io, .both) catch {};
}

/// Cuts the stream from any task, for good: the read or write in progress
/// ends, and it and every later one fail with the error of `by`; the
/// first cut decides it. The socket stays open for its owner to close.
pub fn cut(ds: *DeadlineStream, io: Io, by: Cut) void {
    std.debug.assert(by != .none);
    _ = ds.cut_by.cmpxchgStrong(.none, by, .acq_rel, .monotonic);
    shutdown(io, ds.stream);
    ds.cut_event.set(io);
}

/// The error of a cut stream; null while nobody cut it.
fn cutError(ds: *const DeadlineStream) ?Error {
    return switch (ds.cut_by.load(.acquire)) {
        .none => null,
        .deadline => error.Timeout,
        .stop => error.Stopped,
    };
}

/// What a failed read or write says: the error of the cut, when the
/// stream was cut, but the cancelation of the task as it is, so that the
/// task keeps it.
fn failure(ds: *const DeadlineStream, err: Error) Error {
    if (err == error.Canceled) return err;
    return ds.cutError() orelse err;
}

/// Runs `operation`, waiting no longer than the deadline, if any; on a
/// cut stream it fails at once.
fn operate(ds: *DeadlineStream, operation: Io.Operation) Error!Io.Operation.Result {
    const io = ds.io;
    if (ds.cutError()) |err| return err;
    while (true) {
        return io.operateTimeout(operation, time.step(io, ds.deadline).toTimeout()) catch |err| switch (err) {
            // A step of a far deadline or of none ended, or a timer fired
            // a little early: wait on.
            error.Timeout => {
                if (ds.deadline) |deadline| if (time.expired(io, deadline)) return error.Timeout;
                continue;
            },
            error.ConcurrencyUnavailable => return ds.operateInTask(operation),
            error.Canceled => return error.Canceled,
        };
    }
}

/// `operation` in a task of its own, for an `Io` that cannot time it: the
/// wait for it ends at the deadline, which cuts the stream, or at a cut,
/// and then the task is canceled. What that cancelation makes of the
/// operation is the cut's: `failure` says `error.Timeout` or
/// `error.Stopped`. An operation that moved bytes before its task could be
/// stopped took place, and the cut fails the next one; one that the cut
/// ended, at the end of the stream or with an error, fails with the cut's
/// error. `error.Canceled` is the caller's own cancelation.
fn operateInTask(ds: *DeadlineStream, operation: Io.Operation) Error!Io.Operation.Result {
    var outcome: ?(Io.Cancelable!Io.Operation.Result) = null;
    return race.race(ds.io, .{ .deadline = ds.deadline, .stop = &ds.cut_event }, operateUntimed, .{ ds.io, operation, &outcome }, forget, .{ .context = ds, .function = abort }) catch |err| switch (err) {
        error.Timeout, error.Stopped => if (outcome) |o| movedBytes(o) orelse err else err,
        else => err,
    };
}

/// The result of an operation that read or wrote bytes; null for any other.
fn movedBytes(outcome: Io.Cancelable!Io.Operation.Result) ?Io.Operation.Result {
    const result = outcome catch return null;
    switch (result) {
        .net_read => |r| {
            const read = r catch return null;
            return if (read.data_len > 0) result else null;
        },
        .net_write => |w| {
            const n = w catch return null;
            return if (n > 0) result else null;
        },
        else => return null,
    }
}

/// `operation`, and what it got, into `outcome`, which the race of
/// `operateInTask` leaves for it to see once the task has ended.
fn operateUntimed(io: Io, operation: Io.Operation, outcome: *?(Io.Cancelable!Io.Operation.Result)) Io.Cancelable!Io.Operation.Result {
    const result = io.operate(operation);
    outcome.* = result;
    return result;
}

/// The race's copy of a result that came after the deadline or the cut:
/// `operateInTask` takes it from the outcome.
fn forget(io: Io, result: Io.Operation.Result) void {
    _ = io;
    _ = result;
}

fn abort(context: *anyopaque, io: Io) void {
    const ds: *DeadlineStream = @ptrCast(@alignCast(context));
    ds.cut(io, .deadline);
}

fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(io_r, &data);
    io_w.advance(n);
    return n;
}

fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const ds: *DeadlineStream = @alignCast(@fieldParentPtr("reader", io_r));
    var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
    const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];
    std.debug.assert(dest[0].len > 0);
    const result = ds.operate(.{ .net_read = .{ .socket_handle = ds.stream.socket.handle, .data = dest } }) catch |err| {
        ds.err = ds.failure(err);
        return error.ReadFailed;
    };
    const read = result.net_read catch |err| {
        ds.err = ds.failure(err);
        return error.ReadFailed;
    };
    if (read.data_len == 0) {
        // The end of a stream that was cut is the cut's.
        ds.err = ds.cutError() orelse return error.EndOfStream;
        return error.ReadFailed;
    }
    if (read.data_len > data_size) {
        io_r.end += read.data_len - data_size;
        return data_size;
    }
    return read.data_len;
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const ds: *DeadlineStream = @alignCast(@fieldParentPtr("writer", io_w));
    const result = ds.operate(.{ .net_write = .{
        .socket_handle = ds.stream.socket.handle,
        .header = io_w.buffered(),
        .data = data,
        .splat = splat,
    } }) catch |err| {
        ds.err = ds.failure(err);
        return error.WriteFailed;
    };
    const n = result.net_write catch |err| {
        ds.err = ds.failure(err);
        return error.WriteFailed;
    };
    return io_w.consume(n);
}

const testing = std.testing;
const WindowsLike = @import("../tests/windows_like_io.zig").WindowsLike;
const within5s = @import("../tests/connection_tests.zig").within5s;

/// A stream to a loopback listener, and the listener's side of it.
const Pair = struct {
    listener: net.Server,
    server: net.Stream,
    ds: DeadlineStream,
    read_buffer: [64]u8,
    write_buffer: [64]u8,

    fn open(p: *Pair, io: Io) !void {
        const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
        p.listener = try loopback.listen(io, .{ .reuse_address = true });
        errdefer p.listener.deinit(io);
        const address: net.IpAddress = try .parseIp4("127.0.0.1", p.listener.socket.address.getPort());
        const client = try address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        p.server = try p.listener.accept(io);
        p.ds.init(io, client, &p.read_buffer, &p.write_buffer);
    }

    fn close(p: *Pair, io: Io) void {
        p.ds.stream.close(io);
        p.server.close(io);
        p.listener.deinit(io);
    }
};

test "a read waits no longer than the deadline, and a write goes out under one" {
    const io = testing.io;
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);

    p.ds.begin(.after(time.now(io), .fromSeconds(5)));
    try p.ds.writer.writeAll("ping");
    try p.ds.writer.flush();
    var buffer: [4]u8 = undefined;
    var server_buffer: [16]u8 = undefined;
    var server_reader = p.server.reader(io, &server_buffer);
    try server_reader.interface.readSliceAll(&buffer);
    try testing.expectEqualStrings("ping", &buffer);

    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
    p.ds.begin(deadline);
    try testing.expectError(error.ReadFailed, p.ds.reader.takeByte());
    try testing.expectEqual(Error.Timeout, p.ds.err.?);
    try testing.expect(time.expired(io, deadline));
}

test "without a deadline a read waits for what comes" {
    const io = testing.io;
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var server_buffer: [16]u8 = undefined;
    var server_writer = p.server.writer(io, &server_buffer);
    try server_writer.interface.writeAll("x");
    try server_writer.interface.flush();
    p.ds.begin(null);
    try testing.expectEqual(@as(u8, 'x'), try p.ds.reader.takeByte());
}

test "an operation in a task of its own keeps the deadline, and the stream it cut fails every later read with Timeout" {
    // The way of an Io that cannot time an operation itself, as std's
    // test Io on Windows.
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| {
        var p: Pair = undefined;
        try p.open(io);
        defer p.close(io);
        var byte: [1]u8 = undefined;
        var data: [1][]u8 = .{&byte};
        const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
        p.ds.begin(deadline);
        try testing.expectError(error.Timeout, p.ds.operateInTask(.{ .net_read = .{ .socket_handle = p.ds.stream.socket.handle, .data = &data } }));
        try testing.expect(time.expired(io, deadline));
        // Cut at the deadline: whatever the socket would say, a read of
        // any later exchange fails at once with the deadline's error.
        p.ds.begin(null);
        try testing.expectError(error.ReadFailed, p.ds.reader.takeByte());
        try testing.expectEqual(Error.Timeout, p.ds.err.?);
        p.ds.begin(null);
        try p.ds.writer.writeAll("ping");
        try testing.expectError(error.WriteFailed, p.ds.writer.flush());
        try testing.expectEqual(Error.Timeout, p.ds.err.?);
    }
}

test "a stream its owner cuts fails the read in progress with Stopped at once, with a deadline or without, also where a shutdown does not end the read" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| {
        try within5s(testing.io, cutWhileReading, .{ io, null });
        // Far beyond the time limit of the test: the cut does not wait
        // for it.
        const far: core.Deadline = .after(time.now(io), .fromSeconds(30));
        try within5s(testing.io, cutWhileReading, .{ io, far });
    }
}

fn takeFails(ds: *DeadlineStream) !void {
    try testing.expectError(error.ReadFailed, ds.reader.takeByte());
}

fn cutWhileReading(io: Io, deadline: ?core.Deadline) !void {
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    p.ds.begin(deadline);
    var reading = try io.concurrent(takeFails, .{&p.ds});
    // Long enough for the read to wait on the socket; a cut that comes
    // before it ends the read the same way.
    try io.sleep(.fromMilliseconds(50), .awake);
    p.ds.cut(io, .stop);
    try reading.await(io);
    try testing.expectEqual(Error.Stopped, p.ds.err.?);
}

/// `std.testing.io` whose writes go out and then wait, deaf to
/// cancelation, for the second shutdown of their socket: the one that
/// `operateInTask` makes once a cut has won its race. So a write ends just
/// after the cut, as one that the cut overtakes.
const LateWrites = struct {
    vtable: Io.VTable,

    var shutdowns: std.atomic.Value(u32) = .init(0);
    var released: Io.Event = .unset;

    fn io(l: *LateWrites) Io {
        l.vtable = testing.io.vtable.*;
        l.vtable.operate = operateLate;
        l.vtable.netShutdown = netShutdown;
        shutdowns.store(0, .monotonic);
        released = .unset;
        return .{ .userdata = testing.io.userdata, .vtable = &l.vtable };
    }

    fn operateLate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const result = try testing.io.vtable.operate(userdata, operation);
        if (operation == .net_write) released.waitUncancelable(testing.io);
        return result;
    }

    fn netShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
        defer if (shutdowns.fetchAdd(1, .monotonic) == 1) released.set(testing.io);
        return testing.io.vtable.netShutdown(userdata, handle, how);
    }
};

fn cutSoon(io: Io, ds: *DeadlineStream) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(20), .awake);
    ds.cut(io, .stop);
}

test "an operation in a task of its own that ends as a cut wins its race took place, and the cut fails the next one" {
    var late: LateWrites = undefined;
    const io = late.io();
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    p.ds.begin(null);
    var cutter = try io.concurrent(cutSoon, .{ io, &p.ds });
    var data: [1][]const u8 = .{"ping"};
    const result = p.ds.operateInTask(.{ .net_write = .{ .socket_handle = p.ds.stream.socket.handle, .header = "", .data = &data, .splat = 1 } });
    try cutter.await(io);
    try testing.expectEqual(@as(usize, 4), try (try result).net_write);
    var buffer: [4]u8 = undefined;
    var server_buffer: [16]u8 = undefined;
    var server_reader = p.server.reader(testing.io, &server_buffer);
    try server_reader.interface.readSliceAll(&buffer);
    try testing.expectEqualStrings("ping", &buffer);
    p.ds.begin(null);
    try testing.expectError(error.ReadFailed, p.ds.reader.takeByte());
    try testing.expectEqual(Error.Stopped, p.ds.err.?);
}

test "without a cut the socket's own errors stay what they are" {
    var windows: WindowsLike = undefined;
    const io = windows.io();
    var p: Pair = undefined;
    try p.open(io);
    defer {
        p.ds.stream.close(io);
        p.listener.deinit(io);
    }
    // The server ends the stream, which this Io reads as error.Unexpected.
    p.server.close(io);
    p.ds.begin(null);
    try testing.expectError(error.ReadFailed, p.ds.reader.takeByte());
    try testing.expectEqual(Error.Unexpected, p.ds.err.?);
}
