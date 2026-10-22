//! Debug build: a call that comes on another `std.Io` than the one of
//! `Client.init` panics: every wait of the client goes through its own.
//! build.zig runs this program and checks the panic message on stderr and
//! the exit code 3 of the panic handler below.
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var server: redis.testing.FakeServer = try .start(init.gpa, io, &.{});
    defer server.stop(io);
    var client: redis.Client = try .init(init.gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);

    // The mistake: the same functions behind another table, not the
    // client's io.
    var vtable = io.vtable.*;
    const other: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try client.connect(other, .root, null);
}
