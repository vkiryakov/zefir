//! The probe's program of the real generator: the server and its document,
//! built by zefir.openapi.document at compile time and written at run time.
const std = @import("std");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    return @import("run.zig").run(init, @import("variants.zig").Real);
}
