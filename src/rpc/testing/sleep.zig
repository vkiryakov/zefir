//! A sleep that lasts as long as it says, for the delays and holds of
//! `rpc.testing`. A sleep of `std.Io` may end early: on Windows, std's
//! `Io` wakes up to a tick of the system's timer, about 15.6 ms, before its
//! time. A test that holds a call for 50 ms and checks that the call took
//! 50 ms needs a sleep that never ends sooner.

const std = @import("std");
const Io = std.Io;

/// Sleeps until `duration` has passed on the awake clock, at least: a
/// sleep that ends early is followed by one for the rest. A canceled task
/// stops sleeping with `error.Canceled`.
pub fn sleepAtLeast(io: Io, duration: Io.Duration) Io.Cancelable!void {
    const until = Io.Clock.awake.now(io).addDuration(duration);
    while (true) {
        const left = Io.Clock.awake.now(io).durationTo(until);
        if (left.nanoseconds <= 0) return;
        try io.sleep(left, .awake);
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
