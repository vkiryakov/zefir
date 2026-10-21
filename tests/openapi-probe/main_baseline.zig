//! The probe's program of the baseline: the server, no document.
const std = @import("std");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    return @import("run.zig").run(init, @import("variants.zig").None);
}
