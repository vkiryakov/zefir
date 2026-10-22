//! Debug build: a `redis.Iterator` called by a second task while the first
//! waits for its page panics: one task at a time calls next. build.zig
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

const last_page: redis.testing.FakeServer.Reply = .{ .array = &.{ .{ .string = "0" }, .{ .array = &.{} } } };
const later: redis.testing.FakeServer.Reply = .{ .delayed = .{ .after = .fromSeconds(2), .reply = &last_page } };

fn first(io: std.Io, keys: *redis.Iterator([]const u8)) void {
    _ = keys.next(io, .of(.root)) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var server: redis.testing.FakeServer = try .start(init.gpa, io, &.{.expect(.{ "SCAN", "0" }, later)});
    defer server.stop(io);
    var client: redis.Client = try .init(init.gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    var keys = client.iterate(redis.cmd.scan(.{}), .{ .allocator = init.gpa });
    defer keys.deinit();
    var call = try io.concurrent(first, .{ io, &keys });
    defer call.cancel(io);
    // Once the server has the command, the first call waits for its page.
    var waited: usize = 0;
    while (server.received(io) == 0) : (waited += 1) {
        if (waited == 4000) return error.CommandNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // The mistake: a second task calls next meanwhile.
    _ = try keys.next(io, .of(.root));
}
