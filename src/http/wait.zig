//! Waiting for a `std.Io.Event` until a `core.Deadline`, as the server
//! waits for the end of a request's body and for the end of a stop.
//! Internal to the module.

const std = @import("std");
const core = @import("core");

/// The longest single wait handed to `std.Io`: a far deadline, such as a
/// long `.request_timeout`, is waited for in steps, so that no runtime has
/// to convert a timeout of years to units of its own.
pub const max_step: std.Io.Duration = .fromSeconds(60 * 60);

/// Waits until `event` is set or the awake clock reaches `deadline`.
/// `error.Timeout` only then: `Event.waitTimeout` also returns it on a
/// spurious wake-up, so this waits again. `error.Canceled` only when the
/// task is canceled. An event that is set wins over a deadline that has
/// passed.
pub fn untilSet(event: *std.Io.Event, io: std.Io, deadline: core.Deadline) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
    while (true) {
        const step = deadline.earliest(.after(std.Io.Clock.awake.now(io), max_step));
        if (event.waitTimeout(io, step.toTimeout())) |_| {
            return;
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => if (deadline.isExpired(std.Io.Clock.awake.now(io))) {
                if (event.isSet()) return;
                return error.Timeout;
            },
        }
    }
}

const testing = std.testing;

fn setLater(event: *std.Io.Event, io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(20), .awake);
    event.set(io);
}

test "untilSet: an event that is set wins, even past the deadline; else Timeout at the deadline, never before" {
    const io = testing.io;
    var set: std.Io.Event = .unset;
    set.set(io);
    try untilSet(&set, io, .after(std.Io.Clock.awake.now(io), .fromSeconds(-1)));

    var never: std.Io.Event = .unset;
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromMilliseconds(30));
    try testing.expectError(error.Timeout, untilSet(&never, io, deadline));
    try testing.expect(deadline.isExpired(std.Io.Clock.awake.now(io)));

    // Set by another task before a deadline years away.
    var later: std.Io.Event = .unset;
    var setter = try io.concurrent(setLater, .{ &later, io });
    defer setter.cancel(io) catch {};
    try untilSet(&later, io, .after(std.Io.Clock.awake.now(io), .fromSeconds(1 << 40)));
    try setter.await(io);
}

/// For the module's tests: a deadline 30 s away, for a test that only
/// needs a stop.
pub fn far(io: std.Io) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
}
