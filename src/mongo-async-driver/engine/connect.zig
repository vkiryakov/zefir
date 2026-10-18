//! Opening a connection to the server. `std.Io` has no portable timeout
//! for TCP connect, so a whole attempt, DNS, TCP and the handshake, runs
//! in a task of its own and races a timer (`race.zig`); a timer that wins
//! shuts the attempt's socket down, which ends an attempt blocked on it
//! even when it lost its cancelation. `close` of the client stops an
//! attempt the same way.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Connection = @import("Connection.zig");
const DeadlineStream = @import("DeadlineStream.zig");

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
