//! Debug build: a `redis.Subscriber` whose `next` a second task calls while
//! the first waits in it panics: one task at a time calls next. build.zig
//! runs this program and checks the panic message on stderr and the exit
//! code 3 of the panic handler below.
const std = @import("std");
const redis = @import("redis");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

fn first(io: std.Io, sub: *redis.Subscriber) void {
    if (sub.next(io)) |_| {} else |_| {}
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var server: redis.testing.FakeServer = try .start(init.gpa, io, &.{.expect(.{ "SUBSCRIBE", "orders" }, .subscribed(&.{"orders"}))});
    defer server.stop(io);
    var client: redis.Client = try .init(init.gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    // A short idle_ping: the first next sends PING soon, and goes on
    // waiting after its +PONG.
    var sub = try client.subscribe(io, .of(.root), .{ .channels = &.{"orders"}, .idle_ping = .fromMilliseconds(20) });
    defer sub.close(io);
    var call = try io.concurrent(first, .{ io, &sub });
    defer call.cancel(io);
    // Once the server has the PING, the first next waits in its loop.
    var waited: usize = 0;
    while (server.count(io, "PING") == 0) : (waited += 1) {
        if (waited == 4000) return error.PingNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // The mistake: a second task calls next meanwhile.
    _ = try sub.next(io);
}
