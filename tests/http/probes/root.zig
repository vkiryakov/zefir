//! Probes of how zio behaves on each system, for the design of zefir-http:
//! how to time out a read or a write on a socket (`timeouts.zig`), how the
//! watcher of a request sees a client go and how a stop wakes it
//! (`watcher.zig`), and what the tasks of a request cost (`cost.zig`).
//! Each scenario runs on zio with one executor, then with four, over
//! loopback TCP. They print what they measure, one line per case, and fail
//! when zio does not behave as the design needs.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const runtime = @import("runtime");

test {
    _ = @import("timeouts.zig");
    _ = @import("watcher.zig");
    _ = @import("cost.zig");
}

/// The two ends of a TCP connection over loopback.
pub const Pair = struct {
    /// The accepted end: the server's side of the connection.
    server: net.Stream,
    /// The connecting end: the client.
    client: net.Stream,

    pub fn close(p: Pair, io: Io) void {
        p.server.close(io);
        p.client.close(io);
    }
};

/// Connects a client to a listener on 127.0.0.1 and a free port, and
/// accepts it; the listener is closed again.
pub fn loopbackPair(io: Io) !Pair {
    const address: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);
    return .{ .server = try listener.accept(io), .client = client };
}

pub fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

pub fn since(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(now(io));
}

/// A timeout `millis` milliseconds from now, on the clock that does not
/// count suspend.
pub fn timeout(millis: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(millis), .clock = .awake } };
}

/// Writes all of `bytes`.
pub fn send(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = try (try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{rest} } })).net_write;
        rest = rest[n..];
    }
}

/// One read of what has arrived, waiting for something if nothing has:
/// 0 bytes means that the peer ended its side, the end of the stream.
/// (`net.Stream.read` of Zig 0.17 does not compile, hence `operate`.)
pub fn readSome(io: Io, stream: net.Stream, buffer: []u8) net.Stream.Reader.Error!usize {
    var data: [1][]u8 = .{buffer};
    const result = try io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } });
    return (try result.net_read).data_len;
}

pub const TimedReadError = net.Stream.Reader.Error || Io.OperateTimeoutError;

/// `readSome` that zio ends with `error.Timeout` at `limit`: the
/// operateTimeout way, one operation with a timer of its own.
pub fn readTimeout(io: Io, stream: net.Stream, buffer: []u8, limit: Io.Timeout) TimedReadError!usize {
    var data: [1][]u8 = .{buffer};
    const result = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }, limit);
    return (try result.net_read).data_len;
}

pub const TimedWriteError = Io.Operation.NetWrite.Error || Io.OperateTimeoutError;

/// One write of `bytes` that zio ends with `error.Timeout` at `limit`;
/// returns how many bytes went.
pub fn writeTimeout(io: Io, stream: net.Stream, bytes: []const u8, limit: Io.Timeout) TimedWriteError!usize {
    const result = try io.operateTimeout(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{bytes} } }, limit);
    return try result.net_write;
}

pub const RaceReadError = net.Stream.Reader.Error || Io.Timeout.Error || Io.ConcurrentError;

/// `readSome` that ends with `error.Timeout` after `limit`: the select
/// way, a race of the read with a sleep in two tasks of an `Io.Select`,
/// where the loser is canceled. A read that ends at the same time as the
/// sleep keeps its bytes.
pub fn raceRead(io: Io, stream: net.Stream, buffer: []u8, limit: Io.Duration) RaceReadError!usize {
    const Race = union(enum) {
        read: net.Stream.Reader.Error!usize,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.read, readSome, .{ io, stream, buffer });
    select.concurrent(.timer, Io.sleep, .{ io, limit, .awake }) catch |err| {
        select.cancelDiscard();
        return err;
    };
    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    switch (first) {
        .read => |read| {
            select.cancelDiscard();
            return read;
        },
        .timer => |slept| {
            var late: ?usize = null;
            while (select.cancel()) |result| {
                switch (result) {
                    .read => |read| late = read catch null,
                    .timer => {},
                }
            }
            if (late) |n| return n;
            try slept;
            return error.Timeout;
        },
    }
}

/// Prints one line of what a probe measured, after the runtime it ran on.
pub fn report(comptime format: []const u8, args: anytype) void {
    std.debug.print("    zio x{d}: " ++ format ++ "\n", .{runtime.executors} ++ args);
}

/// Milliseconds with two decimals, for `report`.
pub fn ms(d: Io.Duration) f64 {
    return @as(f64, @floatFromInt(d.toNanoseconds())) / std.time.ns_per_ms;
}

/// Fails unless `d` lies in [min_ms, max_ms).
pub fn expectWithin(d: Io.Duration, min_ms: f64, max_ms: f64) !void {
    const got = ms(d);
    if (got < min_ms or got >= max_ms) {
        std.debug.print("    took {d:.2} ms, expected [{d}, {d}) ms\n", .{ got, min_ms, max_ms });
        return error.TestUnexpectedTime;
    }
}
