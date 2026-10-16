//! Debug build: a second `conn()` of one `rpc_nats.ZefirNats` panics, as
//! one adapter serves one transport. build.zig runs this program and checks
//! the panic message on stderr and the exit code 3 of the panic handler
//! below.
const std = @import("std");
const nats = @import("nats");
const rpc_nats = @import("rpc-nats");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    // No connection is needed: nothing listens on port 1.
    var nc: nats.Client = try .init(init.gpa, init.io, .{ .servers = &.{"nats://127.0.0.1:1"} });
    defer nc.deinit();
    var adapter: rpc_nats.ZefirNats = .{ .client = &nc };
    _ = adapter.conn();
    // The interface for a second transport, on the same adapter.
    _ = adapter.conn();
    std.debug.print("no panic\n", .{});
    std.process.exit(0);
}
