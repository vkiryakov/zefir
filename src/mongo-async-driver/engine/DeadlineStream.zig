//! A TCP stream whose reads and writes wait no longer than the deadline of
//! the exchange in progress: std's `net.Stream.Reader` and
//! `net.Stream.Writer` with `io.operateTimeout` where they call
//! `io.operate`. `begin` sets the deadline before an exchange; a read or a
//! write that reaches it fails, and `err` is `error.Timeout`.
//!
//! An `Io` whose `operateTimeout` cannot time an operation, and says
//! `error.ConcurrencyUnavailable`, keeps the deadline too: the operation
//! then runs in a task of its own against a timer, and a timer that wins
//! shuts the socket down.
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
/// Why the last read or write failed: `error.Timeout`, `error.Canceled`,
/// or an error of the socket.
err: ?Error = null,
reader: Io.Reader,
writer: Io.Writer,

pub const Error = Io.Operation.NetRead.Error || Io.Operation.NetWrite.Error || error{ Timeout, Canceled, ConcurrencyUnavailable };

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
/// ends the stream and a blocked write fails, whether or not its task still
/// sees cancelation. The socket stays open for its owner to close.
pub fn shutdown(io: Io, stream: net.Stream) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    stream.shutdown(io, .both) catch {};
}

/// Runs `operation`, waiting no longer than the deadline.
fn operate(ds: *DeadlineStream, operation: Io.Operation) Error!Io.Operation.Result {
    const io = ds.io;
    const deadline = ds.deadline orelse return io.operate(operation);
    while (true) {
        return io.operateTimeout(operation, time.step(io, deadline).toTimeout()) catch |err| switch (err) {
            // A step of a far deadline ended, or a timer fired a little
            // early: wait on.
            error.Timeout => {
                if (time.expired(io, deadline)) return error.Timeout;
                continue;
            },
            error.ConcurrencyUnavailable => return ds.operateInTask(operation, deadline),
            error.Canceled => return error.Canceled,
        };
    }
}

/// `operation` in a task of its own, against a timer that shuts the
/// socket down at `deadline`.
fn operateInTask(ds: *DeadlineStream, operation: Io.Operation, deadline: core.Deadline) Error!Io.Operation.Result {
    return race.race(ds.io, deadline, operateUntimed, .{ ds.io, operation }, forget, .{ .context = ds, .function = abort });
}

fn operateUntimed(io: Io, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return io.operate(operation);
}

/// A result that came after the deadline: the connection is lost anyway.
fn forget(io: Io, result: Io.Operation.Result) void {
    _ = io;
    _ = result;
}

fn abort(context: *anyopaque, io: Io) void {
    const ds: *DeadlineStream = @ptrCast(@alignCast(context));
    shutdown(io, ds.stream);
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
        ds.err = err;
        return error.ReadFailed;
    };
    const read = result.net_read catch |err| {
        ds.err = err;
        return error.ReadFailed;
    };
    if (read.data_len == 0) return error.EndOfStream;
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
        ds.err = err;
        return error.WriteFailed;
    };
    const n = result.net_write catch |err| {
        ds.err = err;
        return error.WriteFailed;
    };
    return io_w.consume(n);
}

const testing = std.testing;

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

test "an operation in a task of its own keeps the deadline and shuts the socket down at it" {
    // The way of an Io that cannot time an operation itself.
    const io = testing.io;
    var p: Pair = undefined;
    try p.open(io);
    defer p.close(io);
    var byte: [1]u8 = undefined;
    var data: [1][]u8 = .{&byte};
    const deadline: core.Deadline = .after(time.now(io), .fromMilliseconds(50));
    try testing.expectError(error.Timeout, p.ds.operateInTask(.{ .net_read = .{ .socket_handle = p.ds.stream.socket.handle, .data = &data } }, deadline));
    try testing.expect(time.expired(io, deadline));
    // The socket is shut down: the next read ends the stream at once.
    p.ds.begin(null);
    try testing.expectError(error.EndOfStream, p.ds.reader.takeByte());
}
