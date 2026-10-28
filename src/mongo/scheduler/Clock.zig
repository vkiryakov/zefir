//! The estimate of the server's clock in `mongo.SchedulerStore`: the
//! process's real clock and an offset. `ensureIndexes` measures it, and
//! every reply that carries the server's time refines it. A sample from a
//! call that took longer than a second is dropped: its error could pass
//! the margin of a claim.

const std = @import("std");
const Io = std.Io;
const Instant = @import("scheduler").Instant;
const Clock = @This();

/// The server's clock less the process's, in milliseconds.
offset_ms: std.atomic.Value(i64) = .init(0),

const longest_ms = 1000;

pub fn now(c: *const Clock, io: Io) Instant {
    return local(io).add(.fromMilliseconds(c.offset_ms.load(.monotonic)));
}

/// The process's real clock.
pub fn local(io: Io) Instant {
    return .fromTimestamp(Io.Clock.real.now(io));
}

/// The server said `server` during a call that began at `before` and
/// ended at `after`, by `local`: its time is taken for the middle of the
/// call.
pub fn sample(c: *Clock, server: Instant, before: Instant, after: Instant) void {
    const took = after.unix_ms -| before.unix_ms;
    if (took > longest_ms or took < 0) return;
    c.offset_ms.store(server.unix_ms -| (before.unix_ms + @divFloor(took, 2)), .monotonic);
}
