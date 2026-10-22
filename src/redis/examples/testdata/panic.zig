//! A program of the guide that panics: build.zig runs it through
//! example_main.zig and checks that the panic ends the run with code 3 and
//! its message, as a failed safety check in a program would, instead of an
//! abort.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
    @panic("a program of the guide panicked");
}
