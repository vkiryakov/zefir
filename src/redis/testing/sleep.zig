//! Sleeps that last as long as they say. A sleep of `std.Io` may end
//! early: on Windows, std's `Io` wakes up to a tick of the system's timer,
//! about 15.6 ms, before its time. A test that holds a reply for 100 ms
//! and checks that the reply took 100 ms needs a sleep that never ends
//! sooner.

const std = @import("std");
const Io = std.Io;
const time = @import("../engine/time.zig");

/// Sleeps until `duration` has passed on the awake clock, at least: a
/// sleep that ends early is followed by one for the rest. A duration past
/// the end of the clock, such as `Io.Duration.max`, sleeps until the task
/// is canceled. A canceled task stops sleeping with `error.Canceled`.
pub fn sleepAtLeast(io: Io, duration: Io.Duration) Io.Cancelable!void {
    const until = Io.Clock.awake.now(io).nanoseconds +| duration.nanoseconds;
    while (true) {
        const left = until -| Io.Clock.awake.now(io).nanoseconds;
        if (left <= 0) return;
        // A step of an hour at most: some `std.Io` implementations
        // overflow on a sleep that is very long.
        try io.sleep(.{ .nanoseconds = @min(left, time.max_step.nanoseconds) }, .awake);
    }
}

const testing = std.testing;
const early_io = @import("early_io.zig");

test "sleepAtLeast never returns before its time on the clock, though each sleep of the Io ends early" {
    const io = early_io.io();
    for ([_]i64{ 0, 1, 5, 20, 50 }) |ms| {
        const duration: Io.Duration = .fromMilliseconds(ms);
        const start = Io.Clock.awake.now(io);
        try sleepAtLeast(io, duration);
        const took = start.durationTo(Io.Clock.awake.now(io));
        try testing.expect(took.nanoseconds >= duration.nanoseconds);
    }
}

test "sleepAtLeast of a canceled task ends with Canceled" {
    const io = testing.io;
    var future = try io.concurrent(sleepAtLeast, .{ io, Io.Duration.fromSeconds(60) });
    try testing.expectError(error.Canceled, future.cancel(io));
}

test "sleepAtLeast of Io.Duration.max sleeps until the task is canceled" {
    const io = testing.io;
    var future = try io.concurrent(sleepAtLeast, .{ io, Io.Duration.max });
    defer future.cancel(io) catch {};
    // Long enough for the task to be asleep when the cancel comes.
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
}
