//! Debug build: a registry copied after its first `registerConnection()`
//! panics on its next call, since its connections and waits belong to the
//! old place. build.zig runs this program and checks the panic message on
//! stderr and the exit code 3 of the panic handler below.
const std = @import("std");
const odm = @import("odm");

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
    var fake: odm.testing.FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var registry: odm.Registry = .init(init.gpa, io, fake.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });

    // The mistake: a copy of the registry, after its first registration.
    var moved = registry;
    try moved.connect(io, .root, "shared-1");
}
