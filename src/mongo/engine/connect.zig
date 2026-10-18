//! Opening a connection to the server. `std.Io` has no portable timeout
//! for TCP connect, so a whole attempt, DNS, TCP, the handshake and
//! authentication, runs in a task of its own and races a timer
//! (`race.zig`); a timer that wins cuts the attempt's stream, which ends
//! an attempt blocked on it even when it lost its cancelation, also where
//! a shutdown of the socket does not end a read, as on Windows. `close` of
//! the client stops an attempt the same way.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("../root.zig");
const Diagnostics = mongo.Diagnostics;
const Connection = @import("Connection.zig");
const DeadlineStream = @import("DeadlineStream.zig");
const handshake = @import("handshake.zig");
const race = @import("race.zig");

/// The errors of `open`: those of the attempt, which leave the details in
/// the diagnostics; `Timeout` when the deadline came first; `Canceled`
/// when the caller's task was canceled, which stays canceled; `Stopped`
/// when another task stopped the attempt; `ConcurrencyUnavailable` when
/// the attempt found no task to run in.
pub const OpenError = error{ Unavailable, Unsupported, AuthenticationFailed, OutOfMemory, Canceled, Stopped, Timeout, ConcurrencyUnavailable };

/// Opens a connection to `address` and runs the handshake of `setup` on
/// it, all of it before `deadline`, in a task of its own; null: no limit,
/// and the caller's task does it. `attempt` lets another task stop it.
pub fn open(io: Io, gpa: Allocator, address: Connection.Address, setup: *const handshake.Setup, deadline: ?core.Deadline, attempt: *Attempt, d: ?*Diagnostics) OpenError!*Connection {
    // The attempt's own diagnostics: what it says counts only when its
    // error is the one returned.
    var attempt_d: Diagnostics = .{};
    const limit = deadline orelse return openNow(io, gpa, address, setup, attempt, d orelse &attempt_d);
    return race.race(io, .{ .deadline = limit }, openNow, .{ io, gpa, address, setup, attempt, &attempt_d }, destroy, .{
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

const AttemptError = handshake.Error || error{Stopped};

/// The attempt in the task that runs it. A stopped attempt ends with
/// `error.Stopped`, whatever its socket said: a socket that its own side
/// shut down ends the stream on most systems, and answers
/// `error.Unexpected` on Windows. The task's own cancelation stays what it
/// is, so that the task keeps it.
fn openNow(io: Io, gpa: Allocator, address: Connection.Address, setup: *const handshake.Setup, attempt: *Attempt, d: *Diagnostics) AttemptError!*Connection {
    return openUnlessStopped(io, gpa, address, setup, attempt, d) catch |err| {
        if (err != error.Canceled and attempt.isStopped(io)) return error.Stopped;
        return err;
    };
}

fn openUnlessStopped(io: Io, gpa: Allocator, address: Connection.Address, setup: *const handshake.Setup, attempt: *Attempt, d: *Diagnostics) AttemptError!*Connection {
    const stream = dial(io, address) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            d.set(.connect, err, "cannot connect to {f}: {t}", .{ address, err });
            if (!isNameError(err)) handshake.markOverloaded(d);
            return error.Unavailable;
        },
    };
    const conn = Connection.create(gpa, io, stream, address) catch {
        stream.close(io);
        return error.OutOfMemory;
    };
    errdefer conn.destroy();
    if (!attempt.hold(io, &conn.stream)) return error.Stopped;
    // It runs before the errdefer above: the attempt lets the stream go
    // before the stream is freed.
    defer attempt.release(io);
    try handshake.run(conn, setup.*, gpa, d);
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

/// Whether an error of `dial` comes from the name of the host: DNS, a
/// name that is not one, an IPv6 zone that cannot be read. CMAP counts it
/// as no sign of an overloaded server.
fn isNameError(err: DialError) bool {
    return switch (err) {
        error.UnknownHostName,
        error.ResolvConfParseFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.DetectingNetworkConfigurationFailed,
        error.InvalidHostName,
        error.NameTooLong,
        error.ParseFailed,
        error.InterfaceNotFound,
        => true,
        else => false,
    };
}

/// The stream of an attempt in progress, for the timer of its race or for
/// `close` to cut. The mutex keeps the cut off a stream that is gone or no
/// longer the attempt's.
pub const Attempt = struct {
    mutex: Io.Mutex = .init,
    stream: ?*DeadlineStream = null,
    stopped: bool = false,

    /// Makes the attempt end soon: now, or as soon as it has a stream. The
    /// cut ends the read or the write in progress, also one in a task of
    /// its own, which the cancelation of the attempt's task may not reach.
    pub fn stop(a: *Attempt, io: Io) void {
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        a.stopped = true;
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
const FakeServer = mongo.testing.FakeServer;
const WindowsLike = @import("../tests/windows_like_io.zig").WindowsLike;
const within5s = @import("../tests/connection_tests.zig").within5s;

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

test "an attempt stopped during hello is Stopped, whatever its socket says, and one stopped before it has a socket keeps none" {
    var windows: WindowsLike = undefined;
    for ([_]Io{ testing.io, windows.io() }) |io| {
        try within5s(testing.io, stopInHello, .{io});
        try within5s(testing.io, stopBeforeSocket, .{io});
    }
}

/// Accepts one client and reads its hello, says so, and reads until the
/// client goes.
fn hearHello(io: Io, listener: *net.Server, heard: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const request = (try peer.readRequest(testing.allocator)) orelse return error.TestUnexpectedResult;
    request.deinit();
    heard.set(io);
    _ = try peer.readToEnd();
}

fn stopInHello(io: Io) !void {
    var listener = try FakeServer.listen(testing.io);
    defer listener.deinit(testing.io);
    var heard: Io.Event = .unset;
    var server = try testing.io.concurrent(hearHello, .{ testing.io, &listener, &heard });
    defer server.await(testing.io) catch {};
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    const setup: handshake.Setup = .{ .metadata = meta.raw() };
    var attempt: Attempt = .{};
    var d: Diagnostics = .{};
    var opening = try io.concurrent(openNow, .{ io, testing.allocator, .{ .host = "127.0.0.1", .port = FakeServer.port(&listener) }, &setup, &attempt, &d });
    // The client waits for the reply to hello when the server has it.
    const waited = heard.wait(testing.io);
    attempt.stop(io);
    const opened = opening.await(io);
    if (opened) |conn| conn.destroy() else |_| {}
    try waited;
    try testing.expectError(error.Stopped, opened);
}

/// Accepts one client and reads until it goes.
fn hearNothing(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try testing.expectEqual(@as(usize, 0), try peer.readToEnd());
}

fn stopBeforeSocket(io: Io) !void {
    var listener = try FakeServer.listen(testing.io);
    defer listener.deinit(testing.io);
    var server = try testing.io.concurrent(hearNothing, .{ testing.io, &listener });
    defer server.await(testing.io) catch {};
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    const setup: handshake.Setup = .{ .metadata = meta.raw() };
    var attempt: Attempt = .{};
    attempt.stop(io);
    var d: Diagnostics = .{};
    // It dials, closes the socket it got and sends nothing.
    const opened = openNow(io, testing.allocator, .{ .host = "127.0.0.1", .port = FakeServer.port(&listener) }, &setup, &attempt, &d);
    if (opened) |conn| conn.destroy() else |_| {}
    try testing.expectError(error.Stopped, opened);
    try server.await(testing.io);
}
