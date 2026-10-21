//! The probe's program of variant B: the model of the document built at compile time, its JSON written at run time.
const std = @import("std");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    return @import("run.zig").run(init, @import("openapi").B);
}
