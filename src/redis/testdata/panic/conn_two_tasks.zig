//! Debug build: a `redis.Conn` called by a second task while the first
//! waits for its reply panics: one task at a time calls a Conn. build.zig
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

const get = redis.cmd.raw(?i64, .{ "GET", "k" });
const seven: redis.testing.FakeServer.Reply = .{ .integer = 7 };
const later: redis.testing.FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(2), .reply = &seven } };

fn first(io: std.Io, conn: *redis.Conn) void {
    _ = conn.run(io, .of(.root), get, .{}) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var server: redis.testing.FakeServer = try .start(init.gpa, io, &.{.expect(.{ "GET", "k" }, later)});
    defer server.stop(io);
    var client: redis.Client = try .init(init.gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    var call = try io.concurrent(first, .{ io, &conn });
    defer call.cancel(io);
    // Once the server has the command, the first call waits for its reply.
    var waited: usize = 0;
    while (server.received(io) == 0) : (waited += 1) {
        if (waited == 4000) return error.CommandNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // The mistake: a second task calls the Conn meanwhile.
    _ = try conn.run(io, .of(.root), get, .{});
}
