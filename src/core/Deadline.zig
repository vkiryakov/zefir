//! The moment an operation must be done by.
//!
//! Times are `std.Io.Timestamp` values on the `std.Io.Clock.awake` clock:
//! monotonic, unaffected by changes to the system time, and meaningful only
//! inside one process. Read the clock with `std.Io.Clock.awake.now(io)`.
//!
//! Never send a timestamp to another machine. Send the remaining budget
//! (`remaining`) and let the receiver build its own deadline with `after`.

const std = @import("std");
const Timestamp = std.Io.Timestamp;
const Duration = std.Io.Duration;

const Deadline = @This();

/// When the deadline expires, on the `std.Io.Clock.awake` clock.
expires: Timestamp,

/// A deadline at `expires`, a time you already have on the awake clock.
pub fn at(expires: Timestamp) Deadline {
    return .{ .expires = expires };
}

/// A deadline `budget` after `now`. Saturates instead of overflowing; a
/// negative budget gives a deadline that has expired at `now`.
pub fn after(now: Timestamp, budget: Duration) Deadline {
    const non_negative = @max(budget.nanoseconds, 0);
    return .{ .expires = .{ .nanoseconds = now.nanoseconds +| non_negative } };
}

/// A deadline has expired from the moment `now` reaches `expires`.
pub fn isExpired(deadline: Deadline, now: Timestamp) bool {
    return now.nanoseconds >= deadline.expires.nanoseconds;
}

/// Time left until the deadline; zero once it has expired, never negative.
pub fn remaining(deadline: Deadline, now: Timestamp) Duration {
    if (deadline.isExpired(now)) return .zero;
    return .{ .nanoseconds = deadline.expires.nanoseconds -| now.nanoseconds };
}

/// The earlier of two deadlines, `a` when they are equal. `Context.withDeadline`
/// combines deadlines this way.
pub fn earliest(a: Deadline, b: Deadline) Deadline {
    return if (b.expires.nanoseconds < a.expires.nanoseconds) b else a;
}

/// The deadline as a timeout for `std.Io` operations that take one.
pub fn toTimeout(deadline: Deadline) std.Io.Timeout {
    return .{ .deadline = deadline.expires.withClock(.awake) };
}

fn ts(nanoseconds: i96) Timestamp {
    return .fromNanoseconds(nanoseconds);
}

test "expires when now reaches the deadline" {
    const deadline: Deadline = .at(ts(1_000));
    try std.testing.expect(!deadline.isExpired(ts(999)));
    try std.testing.expect(deadline.isExpired(ts(1_000)));
    try std.testing.expect(deadline.isExpired(ts(1_001)));
}

test "remaining counts down and stops at zero" {
    const deadline: Deadline = .at(ts(1_000));
    try std.testing.expectEqual(@as(i96, 400), deadline.remaining(ts(600)).nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), deadline.remaining(ts(1_000)).nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), deadline.remaining(ts(5_000)).nanoseconds);
}

test "after adds the budget to now" {
    const deadline: Deadline = .after(ts(1_000), .fromMilliseconds(2));
    try std.testing.expectEqual(@as(i96, 2_001_000), deadline.expires.nanoseconds);
}

test "a negative budget has already expired" {
    const deadline: Deadline = .after(ts(1_000), .fromNanoseconds(-5));
    try std.testing.expectEqual(@as(i96, 1_000), deadline.expires.nanoseconds);
    try std.testing.expect(deadline.isExpired(ts(1_000)));
}

test "arithmetic saturates at the limits of i96" {
    const max = std.math.maxInt(i96);
    const min = std.math.minInt(i96);

    try std.testing.expectEqual(max, Deadline.after(ts(max - 1), .max).expires.nanoseconds);
    try std.testing.expectEqual(max, Deadline.at(ts(max)).remaining(ts(min)).nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), Deadline.at(ts(min)).remaining(ts(max)).nanoseconds);
    try std.testing.expect(!Deadline.at(ts(max)).isExpired(ts(min)));
}

test "earliest keeps the earlier deadline" {
    const early: Deadline = .at(ts(100));
    const late: Deadline = .at(ts(200));
    try std.testing.expectEqual(early, early.earliest(late));
    try std.testing.expectEqual(early, late.earliest(early));
}

test "toTimeout uses the awake clock" {
    const timeout = Deadline.at(ts(1_234)).toTimeout();
    try std.testing.expectEqual(std.Io.Clock.awake, timeout.deadline.clock);
    try std.testing.expectEqual(@as(i96, 1_234), timeout.deadline.raw.nanoseconds);
}
