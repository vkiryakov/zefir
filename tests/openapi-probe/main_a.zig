//! The probe's program of variant A: the document as JSON built at compile time by pure functions that return the text of each object and array.
const std = @import("std");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    return @import("run.zig").run(init, @import("openapi").A);
}
