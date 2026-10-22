//! The timeout of a blocking command, taken from the deadline of its call.
//! A blocking command holds its connection until the server answers it:
//! with a value, or empty once its timeout ends. Under a deadline, the
//! server gets what the deadline leaves beyond `margin` and the shortest
//! round trip, or the command's own timeout when that is shorter, so that
//! even a quiet server answers before the deadline: the call ends with an
//! empty reply, the connection stays, and no element is lost. Without a
//! deadline the server gets the command's own timeout.
//!
//! | Deadline        | Timeout of the command | Sent to the server         |
//! |-----------------|------------------------|----------------------------|
//! | `left` of it    | `.at_most = t`         | min(t, left − M − rtt)     |
//! | `left` of it    | `.forever`             | left − M − rtt             |
//! | none            | `.at_most = t`         | t                          |
//! | none            | `.forever`             | 0, forever                 |
//!
//! The values are milliseconds, rounded down: never 0 under a deadline,
//! since 0 is forever to a server; with less than 1 ms left beyond the
//! margin and the round trip, the call is `error.DeadlineExceeded` before
//! anything goes out.

const std = @import("std");
const Io = std.Io;
const contract = @import("../cmd/contract.zig");
const Block = @import("../cmd/types.zig").Block;

/// M, what a blocking command leaves of its deadline beyond the shortest
/// round trip when it takes its timeout from it. Redis checks the
/// timeouts of blocked clients only before its event loop sleeps
/// (`beforeSleep` → `blockedBeforeSleep` → `handleBlockedClientsTimeout`),
/// and a quiet server sleeps until its next timer, `serverCron`, which
/// wakes it every `1000/hz` ms: every 100 ms at the default `hz` of 10.
/// So a quiet server answers a timeout up to 100 ms late, and Valkey,
/// which runs the same loop, too. Without the margin that empty reply
/// would come after the deadline: `error.Timeout` instead of null, the
/// connection closed, and an element lost when the server handed one out
/// in that window. 150 ms covers the 100 ms and the way back of the reply.
/// It is no option: the loop of the server sets it, not the application.
pub const margin: Io.Duration = .fromMilliseconds(150);

/// The milliseconds that the blocking commands of a call may wait on the
/// server when the call has `left` of its deadline, `rtt` the shortest
/// round trip to the server: what is left beyond `margin` and `rtt`,
/// rounded down. Less than 1 ms is `error.DeadlineExceeded`.
pub fn room(left: Io.Duration, rtt: Io.Duration) error{DeadlineExceeded}!u64 {
    const ns = left.nanoseconds - margin.nanoseconds - rtt.nanoseconds;
    if (ns < std.time.ns_per_ms) return error.DeadlineExceeded;
    return @intCast(@min(@divFloor(ns, std.time.ns_per_ms), std.math.maxInt(i64)));
}

/// The timeout in milliseconds that a blocking command of `block` sends,
/// 0 for forever: its own without `room_ms`, when the call has no
/// deadline; the lesser of the two with it, never 0 then.
pub fn timeout(block: Block, room_ms: ?u64) u64 {
    const own = contract.given(block);
    const limit = room_ms orelse return own;
    return if (own == 0) limit else @min(own, limit);
}

/// What a blocking command of `block` sends when its call has `left` of
/// its deadline, or no deadline: `timeout` within `room`.
pub fn derive(block: Block, left: ?Io.Duration, rtt: Io.Duration) error{DeadlineExceeded}!u64 {
    const limit: ?u64 = if (left) |rest| try room(rest, rtt) else null;
    return timeout(block, limit);
}
