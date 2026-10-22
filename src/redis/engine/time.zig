//! The clock of the client: every deadline is a `core.Deadline` on the
//! awake clock, and one far away is waited for in steps of an hour at
//! most, since some `std.Io` implementations overflow on a very far one.
//!
//! `RoundTrips` keeps the round trips of HELLO on the client's new
//! connections. A call goes out only while more than the shortest of them
//! is left of its deadline: a reply could not come back in less.

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
/// `max_step` from now; with no deadline, `max_step` from now.
pub fn step(io: Io, deadline: ?core.Deadline) core.Deadline {
    const far: core.Deadline = .after(now(io), max_step);
    const d = deadline orelse return far;
    return d.earliest(far);
}

/// Sleeps until `deadline`, and never wakes before it: a timer that fires
/// a little early sleeps again.
pub fn sleepUntil(io: Io, deadline: core.Deadline) Io.Cancelable!void {
    while (!expired(io, deadline)) try step(io, deadline).toTimeout().sleep(io);
}

/// The round trips of HELLO on the client's new connections, the latest
/// 10 of them: the shortest is the least time a reply takes. Any task may
/// add or read.
pub const RoundTrips = struct {
    mutex: Io.Mutex = .init,
    samples: [window]Io.Duration = undefined,
    /// How many samples there are, `window` at most.
    len: usize = 0,
    /// Where the next sample goes: over the oldest once there are 10.
    next: usize = 0,

    pub const window = 10;

    pub fn add(r: *RoundTrips, io: Io, rtt: Io.Duration) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.samples[r.next] = rtt;
        r.next = (r.next + 1) % window;
        if (r.len < window) r.len += 1;
    }

    /// The shortest of the samples; 0 with fewer than two, since one
    /// round trip says too little to refuse a call by.
    pub fn min(r: *RoundTrips, io: Io) Io.Duration {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.len < 2) return .zero;
        var shortest = r.samples[0];
        for (r.samples[1..r.len]) |sample| {
            if (sample.nanoseconds < shortest.nanoseconds) shortest = sample;
        }
        return shortest;
    }
};

const testing = std.testing;

test "a far deadline is waited for in steps of an hour at most, and so is none" {
    const io = testing.io;
    const far: core.Deadline = .at(.{ .nanoseconds = std.math.maxInt(i96) });
    const next = step(io, far);
    try testing.expect(next.expires.nanoseconds <= now(io).nanoseconds + max_step.nanoseconds);
    const near: core.Deadline = .after(now(io), .fromMilliseconds(5));
    try testing.expectEqual(near, step(io, near));
    const before = now(io);
    const none = step(io, null);
    try testing.expect(none.expires.nanoseconds >= before.nanoseconds + max_step.nanoseconds);
    try testing.expect(none.expires.nanoseconds <= now(io).nanoseconds + max_step.nanoseconds);
}

test "sleepUntil never wakes before the deadline" {
    const io = testing.io;
    const deadline: core.Deadline = .after(now(io), .fromMilliseconds(20));
    try sleepUntil(io, deadline);
    try testing.expect(expired(io, deadline));
}

fn ms(n: i64) Io.Duration {
    return .fromMilliseconds(n);
}

test "the shortest round trip is the least of the latest 10, and 0 with fewer than two" {
    const io = testing.io;
    const cases = [_]struct { []const Io.Duration, Io.Duration }{
        .{ &.{}, .zero },
        .{ &.{ms(5)}, .zero },
        .{ &.{ ms(5), ms(3) }, ms(3) },
        .{ &.{ ms(3), ms(5), ms(4) }, ms(3) },
        // The first, the shortest, is one of 11: the latest 10 are left.
        .{ &.{ ms(1), ms(9), ms(8), ms(7), ms(6), ms(5), ms(6), ms(7), ms(8), ms(9), ms(10) }, ms(5) },
        .{ &.{ ms(9), ms(8), ms(7), ms(6), ms(5), ms(4), ms(3), ms(2), ms(1), ms(2), ms(3), ms(4) }, ms(1) },
    };
    for (cases) |case| {
        const samples, const expected = case;
        var trips: RoundTrips = .{};
        for (samples) |sample| trips.add(io, sample);
        try testing.expectEqual(expected, trips.min(io));
    }
}
