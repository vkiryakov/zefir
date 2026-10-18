//! Opening a connection to the server. `std.Io` has no portable timeout
//! for TCP connect, so a whole attempt, DNS, TCP, the handshake and
//! authentication, runs in a task of its own and races a timer
//! (`race.zig`); a timer that wins shuts the attempt's socket down, which
//! ends an attempt blocked on it even when it lost its cancelation.
//! `close` of the client stops an attempt the same way.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("mongo");
const Diagnostics = mongo.Diagnostics;
const Connection = @import("Connection.zig");
const DeadlineStream = @import("DeadlineStream.zig");
const handshake = @import("handshake.zig");
const race = @import("race.zig");

/// The errors of `open`: those of the attempt, which leave the details in
/// the diagnostics, and `Timeout` when the deadline came first,
/// `Canceled` when the caller's task was canceled or the attempt stopped,
/// `ConcurrencyUnavailable` when the attempt found no task to run in.
pub const OpenError = error{ Unavailable, Unsupported, AuthenticationFailed, OutOfMemory, Canceled, Timeout, ConcurrencyUnavailable };

/// Opens a connection to `address` and runs the handshake of `setup` on
/// it, all of it before `deadline`, in a task of its own; null: no limit,
/// and the caller's task does it. `attempt` lets another task stop it.
pub fn open(io: Io, gpa: Allocator, address: Connection.Address, setup: *const handshake.Setup, deadline: ?core.Deadline, attempt: *Attempt, d: ?*Diagnostics) OpenError!*Connection {
    // The attempt's own diagnostics: what it says counts only when its
    // error is the one returned.
    var attempt_d: Diagnostics = .{};
    const limit = deadline orelse return openNow(io, gpa, address, setup, attempt, d orelse &attempt_d);
    return race.race(io, limit, openNow, .{ io, gpa, address, setup, attempt, &attempt_d }, destroy, .{
        .context = attempt,
        .function = Attempt.abort,
    }) catch |err| {
        switch (err) {
            error.Unavailable, error.Unsupported, error.AuthenticationFailed => if (d) |x| {
                x.* = attempt_d;
            },
            else => {},
        }
        return err;
    };
}

fn openNow(io: Io, gpa: Allocator, address: Connection.Address, setup: *const handshake.Setup, attempt: *Attempt, d: *Diagnostics) handshake.Error!*Connection {
    const stream = dial(io, address) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            d.set(.connect, err, "cannot connect to {f}: {t}", .{ address, err });
            return error.Unavailable;
        },
    };
    if (!attempt.hold(io, stream)) {
        stream.close(io);
        return error.Canceled;
    }
    defer attempt.release(io);
    const conn = Connection.create(gpa, io, stream, address) catch {
        stream.close(io);
        return error.OutOfMemory;
    };
    handshake.run(conn, setup.*, gpa, d) catch |err| {
        conn.destroy();
        return err;
    };
    return conn;
}

/// A connection that came after the deadline.
fn destroy(io: Io, conn: *Connection) void {
    _ = io;
    conn.destroy();
}

pub const DialError = net.IpAddress.ConnectError || net.HostName.ConnectError ||
    net.HostName.ValidateError || net.Ip6Address.ResolveError;

/// Resolves `address` and opens a TCP connection to it. It has no time
/// limit of its own: run it under `race`.
pub fn dial(io: Io, address: Connection.Address) DialError!net.Stream {
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

/// The socket of an attempt in progress, for the timer of its race or for
/// `close` to shut down. The mutex keeps the shutdown off a socket that is
/// closed or no longer the attempt's.
pub const Attempt = struct {
    mutex: Io.Mutex = .init,
    stream: ?net.Stream = null,
    stopped: bool = false,

    /// Makes the attempt end soon: now, or as soon as it has a socket.
    pub fn stop(a: *Attempt, io: Io) void {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.stopped = true;
        if (a.stream) |stream| DeadlineStream.shutdown(io, stream);
    }

    /// Registers the attempt's socket; false when the attempt was stopped
    /// already.
    pub fn hold(a: *Attempt, io: Io, stream: net.Stream) bool {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        if (a.stopped) return false;
        a.stream = stream;
        return true;
    }

    /// From here on the socket is no longer the attempt's to shut down.
    pub fn release(a: *Attempt, io: Io) void {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.stream = null;
    }

    /// For `race`: stops the attempt when the timer wins.
    pub fn abort(context: *anyopaque, io: Io) void {
        const a: *Attempt = @ptrCast(@alignCast(context));
        a.stop(io);
    }
};

const testing = std.testing;

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

test "a stopped attempt shuts its socket down, and one stopped before it has a socket keeps none" {
    const io = testing.io;
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try dial(io, .{ .host = "127.0.0.1", .port = listener.socket.address.getPort() });
    defer stream.close(io);
    const accepted = try listener.accept(io);
    defer accepted.close(io);

    var attempt: Attempt = .{};
    try testing.expect(attempt.hold(io, stream));
    attempt.stop(io);
    var buffer: [16]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());

    var stopped: Attempt = .{};
    stopped.stop(io);
    try testing.expect(!stopped.hold(io, stream));
}
