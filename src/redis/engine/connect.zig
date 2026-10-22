//! Opening a connection to the server. `std.Io` has no portable timeout
//! for TCP connect, so a whole attempt, DNS, TCP and the handshake, runs
//! in a task of its own and races a timer (`race.zig`); a timer that wins
//! cuts the attempt's stream, which ends an attempt blocked on it even
//! when it lost its cancelation, also where a shutdown of the socket does
//! not end a read, as on Windows. `close` of the client stops an attempt
//! the same way, and ends the race at once: an attempt still in DNS or TCP
//! connect, with no stream to cut yet, is canceled with it.
//!
//! The budget of an attempt is `connect_timeout`, or the deadline of the
//! call when that comes first.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = @import("../errors.zig").Diagnostics;
const Address = @import("Address.zig");
const Connection = @import("Connection.zig");
const DeadlineStream = @import("DeadlineStream.zig");
const handshake = @import("handshake.zig");
const race = @import("race.zig");

/// The errors of `open`: those of the attempt, which leave the details in
/// the diagnostics; `Timeout` when the deadline came first; `Canceled`
/// when the caller's task was canceled, which stays canceled; `Stopped`
/// when another task stopped the attempt; `ConcurrencyUnavailable` when
/// the attempt found no task to run in.
pub const OpenError = handshake.Error || error{ Stopped, Timeout, ConcurrencyUnavailable };

/// Opens a connection to `address` and runs the handshake of `setup` on
/// it, all of it before `deadline`, in a task of its own; null: no limit,
/// and the caller's task does it. A reply of the connection may take
/// `max_reply_bytes` on the wire. `attempt` lets another task stop it.
pub fn open(io: Io, gpa: Allocator, address: Address, max_reply_bytes: usize, setup: *const handshake.Setup, deadline: ?core.Deadline, attempt: *Attempt, d: ?*Diagnostics) OpenError!*Connection {
    // The attempt's own diagnostics: what it says counts only when its
    // error is the one returned.
    var attempt_d: Diagnostics = .{};
    const limit = deadline orelse return openNow(io, gpa, address, max_reply_bytes, setup, attempt, d orelse &attempt_d);
    return race.race(io, .{ .deadline = limit, .stop = &attempt.stopping }, openNow, .{ io, gpa, address, max_reply_bytes, setup, attempt, &attempt_d }, destroy, .{
        .context = attempt,
        .function = Attempt.abort,
    }) catch |err| {
        switch (err) {
            error.Unavailable, error.Unsupported, error.AuthenticationFailed, error.InvalidArgument => if (d) |x| {
                x.* = attempt_d;
            },
            else => {},
        }
        return err;
    };
}

const AttemptError = handshake.Error || error{Stopped};

/// The attempt in the task that runs it. A stopped attempt ends with
/// `error.Stopped`, whatever its socket said: a socket that its own side
/// shut down ends the stream on most systems, and answers
/// `error.Unexpected` on Windows. The task's own cancelation stays what it
/// is, so that the task keeps it.
fn openNow(io: Io, gpa: Allocator, address: Address, max_reply_bytes: usize, setup: *const handshake.Setup, attempt: *Attempt, d: *Diagnostics) AttemptError!*Connection {
    return openUnlessStopped(io, gpa, address, max_reply_bytes, setup, attempt, d) catch |err| {
        if (err != error.Canceled and attempt.isStopped(io)) return error.Stopped;
        return err;
    };
}

fn openUnlessStopped(io: Io, gpa: Allocator, address: Address, max_reply_bytes: usize, setup: *const handshake.Setup, attempt: *Attempt, d: *Diagnostics) AttemptError!*Connection {
    const stream = dial(io, address) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            d.set(.connect, err, "cannot connect to {f}: {t}", .{ address, err });
            return error.Unavailable;
        },
    };
    const conn = Connection.create(gpa, io, stream, address, max_reply_bytes) catch {
        stream.close(io);
        return error.OutOfMemory;
    };
    errdefer conn.destroy();
    if (!attempt.hold(io, &conn.stream)) return error.Stopped;
    // It runs before the errdefer above: the attempt lets the stream go
    // before the stream is freed.
    defer attempt.release(io);
    try handshake.run(conn, setup.*, d);
    return conn;
}

/// A connection that came after the deadline.
fn destroy(io: Io, conn: *Connection) void {
    _ = io;
    conn.destroy();
}

/// What ends an attempt to open a connection first.
pub const Budget = struct {
    deadline: core.Deadline,
    /// Which limit `deadline` is: the deadline of the call, or
    /// `connect_timeout`.
    by: enum { deadline, connect_timeout },
};

/// The budget of an attempt that starts at `now`: `connect_timeout`, or
/// the deadline of the call when that comes first or at the same time.
pub fn budget(now: Io.Timestamp, connect_timeout: Io.Duration, deadline: ?core.Deadline) Budget {
    const limit: core.Deadline = .after(now, connect_timeout);
    if (deadline) |d| if (d.expires.nanoseconds <= limit.expires.nanoseconds) return .{ .deadline = d, .by = .deadline };
    return .{ .deadline = limit, .by = .connect_timeout };
}

pub const DialError = net.IpAddress.ConnectError || net.HostName.ConnectError ||
    net.HostName.ValidateError || net.Ip6Address.ResolveError;

/// Resolves `address` and opens a TCP connection to it. It has no time
/// limit of its own: run it under `race`.
pub fn dial(io: Io, address: Address) DialError!net.Stream {
    const host = address.host;
    if (net.IpAddress.parse(host, address.port)) |ip| {
        return ip.connect(io, .{ .mode = .stream });
    } else |_| {}
    if (std.mem.findScalar(u8, host, ':') != null) {
        // An IPv6 address with a zone, such as fe80::1%en0: the system
        // looks the interface up.
        const ip: net.IpAddress = .{ .ip6 = try .resolve(io, host, address.port) };
        return ip.connect(io, .{ .mode = .stream });
    }
    const name: net.HostName = try .init(host);
    return name.connect(io, address.port, .{ .mode = .stream });
}

/// The stream of an attempt in progress, for the timer of its race or for
/// `close` to cut. The mutex keeps the cut off a stream that is gone or no
/// longer the attempt's.
pub const Attempt = struct {
    mutex: Io.Mutex = .init,
    stream: ?*DeadlineStream = null,
    stopped: bool = false,
    /// Set by `stop`: it ends the wait of the race that the attempt runs
    /// in, which then cancels the attempt's task, in DNS or TCP connect
    /// too.
    stopping: Io.Event = .unset,

    /// Makes the attempt end soon: now, or as soon as it has a stream. The
    /// cut ends the read or the write in progress, also one in a task of
    /// its own, which the cancelation of the attempt's task may not reach;
    /// the race of `open` ends at once, and cancels the attempt before it
    /// has a stream.
    pub fn stop(a: *Attempt, io: Io) void {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.stopped = true;
        a.stopping.set(io);
        if (a.stream) |stream| stream.cut(io, .stop);
    }

    /// Registers the attempt's stream; false when the attempt was stopped
    /// already.
    pub fn hold(a: *Attempt, io: Io, stream: *DeadlineStream) bool {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        if (a.stopped) return false;
        a.stream = stream;
        return true;
    }

    /// From here on the stream is no longer the attempt's to cut.
    pub fn release(a: *Attempt, io: Io) void {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.stream = null;
    }

    pub fn isStopped(a: *Attempt, io: Io) bool {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        return a.stopped;
    }

    /// For `race`: stops the attempt when the timer wins.
    pub fn abort(context: *anyopaque, io: Io) void {
        const a: *Attempt = @ptrCast(@alignCast(context));
        a.stop(io);
    }
};

const testing = std.testing;

test "the budget of an attempt is connect_timeout, or the deadline of the call when that comes first or at the same time" {
    const now: Io.Timestamp = .fromNanoseconds(1_000_000_000);
    const second: Io.Duration = .fromSeconds(1);
    const timeout: Io.Duration = .fromSeconds(5);
    const at = struct {
        fn at(t: Io.Timestamp, d: Io.Duration) core.Deadline {
            return .after(t, d);
        }
    }.at;
    try testing.expectEqual(Budget{ .deadline = at(now, timeout), .by = .connect_timeout }, budget(now, timeout, null));
    try testing.expectEqual(Budget{ .deadline = at(now, second), .by = .deadline }, budget(now, timeout, at(now, second)));
    try testing.expectEqual(Budget{ .deadline = at(now, timeout), .by = .connect_timeout }, budget(now, timeout, at(now, .fromSeconds(9))));
    try testing.expectEqual(Budget{ .deadline = at(now, timeout), .by = .deadline }, budget(now, timeout, at(now, timeout)));
    // A deadline that has passed is the budget: the race ends at once.
    const past: core.Deadline = .at(.fromNanoseconds(1));
    try testing.expectEqual(Budget{ .deadline = past, .by = .deadline }, budget(now, timeout, past));
}

test "dial reaches a listener by IP address and by name, and a closed port refuses" {
    const io = testing.io;
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
        const stream = try dial(io, .{ .host = host, .port = port });
        stream.close(io);
        const accepted = try listener.accept(io);
        accepted.close(io);
    }
    listener.deinit(io);
    try testing.expectError(error.ConnectionRefused, dial(io, .{ .host = "127.0.0.1", .port = port }));
}
