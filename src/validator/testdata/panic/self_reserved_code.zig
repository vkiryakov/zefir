//! Debug build: a validateSelf result with a reserved code panics. build.zig
//! runs this program and checks the panic message on stderr and the exit
//! code 3 of the panic handler below.
const std = @import("std");
const v = @import("validator");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const Bad = struct {
    n: u32,
    pub fn validateSelf(_: *const Bad) ?v.Violation {
        return .{ .code = "validation.fake", .message = "fake" };
    }
};

pub fn main() void {
    var buf: [64]u8 = undefined;
    _ = v.check(&Bad{ .n = 1 }, &buf);
}
