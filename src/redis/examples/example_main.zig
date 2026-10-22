//! The root of every program of the guide when the build runs it, in
//! tests/redis: the program's own `main` and `std_options`, a panic that
//! prints its message and exits with code 3 instead of aborting, so a
//! broken run ends at once and says why, and a time limit: a run that has
//! not ended after it prints so and exits with code 4, so that a run that
//! hangs fails its step instead of holding the build until the job's
//! timeout. testdata/panic.zig and testdata/hang.zig check both.

const std = @import("std");
const example = @import("example");

pub const panic = std.debug.FullPanic(exitOnPanic);

pub const std_options: std.Options = if (@hasDecl(example, "std_options")) example.std_options else .{};

/// How long a run may take: two minutes, or the program's own
/// `time_limit`, as testdata/hang.zig has it.
const time_limit: std.Io.Duration = if (@hasDecl(example, "time_limit")) example.time_limit else .fromSeconds(120);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    var watchdog = try init.io.concurrent(exitAfterTimeLimit, .{init.io});
    defer watchdog.cancel(init.io);
    return example.main(init);
}

/// Waits for `time_limit` and exits with code 4, unless the end of the run
/// cancels it first.
fn exitAfterTimeLimit(io: std.Io) void {
    io.sleep(time_limit, .awake) catch return;
    std.debug.print("the run did not end within {d} s: exit with code 4\n", .{time_limit.toSeconds()});
    std.process.exit(4);
}
