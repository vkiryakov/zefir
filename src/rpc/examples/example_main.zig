//! The root of every program of the guide when the build runs it: the
//! program's own `main` and `std_options`, and a panic that prints its
//! message and exits with code 3 instead of aborting, so a broken run ends
//! at once and says why.

const std = @import("std");
const example = @import("example");

pub const panic = std.debug.FullPanic(exitOnPanic);

pub const std_options: std.Options = if (@hasDecl(example, "std_options")) example.std_options else .{};

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) @typeInfo(@TypeOf(example.main)).@"fn".return_type.? {
    return example.main(init);
}
