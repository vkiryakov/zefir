//! A program of the guide that hangs: build.zig runs it through
//! example_main.zig and checks that its time limit ends the run with code 4,
//! so that a program of the guide that hangs fails its step at once instead
//! of holding the build until the job's timeout.

const std = @import("std");

/// The limit of this run, instead of the two minutes of the others.
pub const time_limit: std.Io.Duration = .fromSeconds(1);

pub fn main(init: std.process.Init) !void {
    try init.io.sleep(.fromSeconds(3600), .awake);
}
