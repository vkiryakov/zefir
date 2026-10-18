//! The clock of the driver: every deadline is a `core.Deadline` on the
//! awake clock, and one far away is waited for in steps of an hour at
//! most, since some `std.Io` implementations overflow on a very far one.

const std = @import("std");
const Io = std.Io;
const core = @import("core");

/// The longest single wait.
pub const max_step: Io.Duration = .fromSeconds(3600);

/// Now, on the clock of deadlines.
pub fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

pub fn expired(io: Io, deadline: core.Deadline) bool {
    return deadline.isExpired(now(io));
}

/// Where the next wait toward `deadline` ends: at the deadline, or
/// `max_step` from now.
pub fn step(io: Io, deadline: core.Deadline) core.Deadline {
    return deadline.earliest(.after(now(io), max_step));
}

/// Sleeps until `deadline`, and never wakes before it: a timer that fires
/// a little early sleeps again.
pub fn sleepUntil(io: Io, deadline: core.Deadline) Io.Cancelable!void {
    while (!expired(io, deadline)) try step(io, deadline).toTimeout().sleep(io);
}

const testing = std.testing;

test "a far deadline is waited for in steps of an hour at most" {
    const io = testing.io;
    const far: core.Deadline = .at(.{ .nanoseconds = std.math.maxInt(i96) });
    const next = step(io, far);
    try testing.expect(next.expires.nanoseconds <= now(io).nanoseconds + max_step.nanoseconds);
    const near: core.Deadline = .after(now(io), .fromMilliseconds(5));
    try testing.expectEqual(near, step(io, near));
}

test "sleepUntil never wakes before the deadline" {
    const io = testing.io;
    const deadline: core.Deadline = .after(now(io), .fromMilliseconds(20));
    try sleepUntil(io, deadline);
    try testing.expect(expired(io, deadline));
}
