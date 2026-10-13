//! Opening a TCP connection to a server, and running an attempt against a
//! deadline. `std.Io` has no portable connect timeout (Io.Threaded panics
//! on `ConnectOptions.timeout`), so a whole attempt, DNS, TCP and the
//! handshake, runs in a task of its own and races a timer.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ServerAddress = @import("../ServerAddress.zig");
const time = @import("time.zig");

pub const DialError = net.IpAddress.ConnectError || net.HostName.ConnectError ||
    net.HostName.ValidateError || net.Ip6Address.ResolveError;

/// Resolves `address` and opens a TCP connection to it. It has no time
/// limit of its own: run it under `race`.
pub fn dial(io: Io, address: *const ServerAddress) DialError!net.Stream {
    const host = address.host();
    if (net.IpAddress.parse(host, address.port)) |ip| {
        return ip.connect(io, .{ .mode = .stream });
    } else |_| {}
    if (std.mem.findScalar(u8, host, ':') != null) {
        // An IPv6 literal with a zone, such as fe80::1%en0: the OS looks
        // the interface up.
        const ip: net.IpAddress = .{ .ip6 = try .resolve(io, host, address.port) };
        return ip.connect(io, .{ .mode = .stream });
    }
    const name: net.HostName = try .init(host);
    return name.connect(io, address.port, .{ .mode = .stream });
}

/// The errors of `race(function, ...)`: those of `function`, plus Timeout
/// when the deadline came first.
pub fn RaceError(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.error_set ||
        error{ Timeout, Canceled, ConcurrencyUnavailable };
}

/// What `function` returns when it succeeds.
pub fn Payload(comptime Function: type) type {
    return @typeInfo(Result(Function)).error_union.payload;
}

fn Result(comptime Function: type) type {
    return @typeInfo(Function).@"fn".return_type.?;
}

/// Runs `function(args)` in a task of its own and waits for it until
/// `deadline`. When the deadline comes first, the task is canceled and
/// awaited, a value it returned anyway goes to `release`, and the caller
/// gets Timeout. Canceling the caller cancels the task the same way.
pub fn race(
    io: Io,
    deadline: Io.Clock.Timestamp,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    comptime release: fn (Io, Payload(@TypeOf(function))) void,
) RaceError(@TypeOf(function))!Payload(@TypeOf(function)) {
    const Race = union(enum) {
        done: Result(@TypeOf(function)),
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &results);
    try select.concurrent(.done, function, args);
    select.concurrent(.timer, sleepUntil, .{ io, deadline }) catch |err| {
        settle(Race, &select, io, release);
        return err;
    };
    const first = select.await() catch |err| {
        settle(Race, &select, io, release);
        return err;
    };
    settle(Race, &select, io, release);
    return switch (first) {
        .done => |result| result,
        .timer => error.Timeout,
    };
}

fn sleepUntil(io: Io, deadline: Io.Clock.Timestamp) Io.Cancelable!void {
    return deadline.wait(io);
}

/// Cancels and awaits what is still running; a value that arrives anyway
/// goes to `release`.
fn settle(comptime Race: type, select: *Io.Select(Race), io: Io, comptime release: anytype) void {
    while (select.cancel()) |left| switch (left) {
        .done => |result| if (result) |value| release(io, value) else |_| {},
        .timer => {},
    };
}

const testing = std.testing;

fn listen(io: Io) !net.Server {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return loopback.listen(io, .{ .reuse_address = true });
}

fn addressOf(server: *const net.Server, host: []const u8) !ServerAddress {
    var buffer: [300]u8 = undefined;
    return ServerAddress.parse(try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ host, server.socket.address.getPort() }));
}

fn acceptOne(io: Io, server: *net.Server) net.Server.AcceptError!net.Stream {
    return server.accept(io);
}

test "dial reaches a listener by IP address and by name" {
    const io = testing.io;
    var server = try listen(io);
    defer server.deinit(io);
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
        var peer = try io.concurrent(acceptOne, .{ io, &server });
        defer if (peer.cancel(io)) |stream| stream.close(io) else |_| {};
        const address = try addressOf(&server, host);
        const stream = try dial(io, &address);
        stream.close(io);
    }
}

test "dial to a closed port is refused" {
    const io = testing.io;
    var server = try listen(io);
    const address = try addressOf(&server, "127.0.0.1");
    server.deinit(io);
    try testing.expectError(error.ConnectionRefused, dial(io, &address));
}

fn sleepThenAnswer(io: Io, duration: Io.Duration) error{Canceled}!u32 {
    try io.sleep(duration, .awake);
    return 7;
}

fn fail() error{Broken}!u32 {
    return error.Broken;
}

fn keep(io: Io, value: u32) void {
    _ = io;
    _ = value;
}

test "race returns what comes in time" {
    const io = testing.io;
    try testing.expectEqual(7, try race(io, time.after(io, .fromSeconds(30)), sleepThenAnswer, .{ io, .fromMilliseconds(1) }, keep));
    try testing.expectError(error.Broken, race(io, time.after(io, .fromSeconds(30)), fail, .{}, keep));
}

test "race gives up at the deadline and cancels the slower task" {
    const io = testing.io;
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, race(io, time.after(io, .fromMilliseconds(30)), sleepThenAnswer, .{ io, .fromSeconds(30) }, keep));
    const waited = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(waited.nanoseconds >= 30 * std.time.ns_per_ms);
    try testing.expect(waited.toSeconds() < 10);
}

/// Allocates after 30 ms and cannot be canceled before that.
fn allocateLate(io: Io, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    io.sleep(.fromMilliseconds(30), .awake) catch {};
    return gpa.alloc(u8, 16);
}

fn free(io: Io, bytes: []u8) void {
    _ = io;
    testing.allocator.free(bytes);
}

test "a value that comes after the deadline is released" {
    // testing.allocator reports a leak if `free` is not called.
    const io = testing.io;
    try testing.expectError(error.Timeout, race(io, time.after(io, .zero), allocateLate, .{ io, testing.allocator }, free));
}
