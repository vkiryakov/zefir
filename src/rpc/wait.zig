//! Waiting for a `std.Io.Event` until a `core.Deadline`, as the engine and
//! the transport helpers of rpc wait. Internal to the module.

const std = @import("std");
const core = @import("core");

/// The longest single wait handed to `std.Io`. Implementations convert a
/// timeout to units of their own, and some overflow on a far deadline:
/// `std.Io.Threaded` panics in a futex wait past about 68 years on 32-bit
/// Linux (`timespec.sec` is 32 bits) and in `sleep` past about 29 000 years
/// on Windows. A farther deadline is waited for in steps.
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

fn ages(io: std.Io) core.Deadline {
    // About 35 000 years: one wait that long overflows on some targets (see
    // `max_step`).
    return .after(std.Io.Clock.awake.now(io), .fromSeconds(1 << 40));
}

fn setLater(event: *std.Io.Event, io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(20), .awake);
    event.set(io);
}

test "an event that is set returns at once, even past the deadline" {
    const io = testing.io;
    var event: std.Io.Event = .unset;
    event.set(io);
    try untilSet(&event, io, .after(std.Io.Clock.awake.now(io), .fromSeconds(-1)));
}

test "the deadline gives Timeout, never before it" {
    const io = testing.io;
    var event: std.Io.Event = .unset;
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromMilliseconds(30));
    try testing.expectError(error.Timeout, untilSet(&event, io, deadline));
    try testing.expect(deadline.isExpired(std.Io.Clock.awake.now(io)));
}

test "an event set by another task ends a wait with a far deadline" {
    const io = testing.io;
    var event: std.Io.Event = .unset;
    var setter = try io.concurrent(setLater, .{ &event, io });
    defer setter.cancel(io) catch {};
    try untilSet(&event, io, ages(io));
    try setter.await(io);
}

fn waitForCancel(event: *std.Io.Event, io: std.Io) !void {
    untilSet(event, io, ages(io)) catch |err| switch (err) {
        error.Canceled => {
            // A real cancelation: recancel re-arms it (in Debug it checks
            // that one came), and the next cancelation point sees it.
            io.recancel();
            return io.checkCancel();
        },
        error.Timeout => return error.TestUnexpectedResult,
    };
    return error.TestUnexpectedResult;
}

test "canceling the task ends the wait with Canceled" {
    const io = testing.io;
    var event: std.Io.Event = .unset;
    var waiter = try io.concurrent(waitForCancel, .{ &event, io });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, waiter.cancel(io));
}

/// For the module's tests: a deadline 30 s away, for a test that only
/// needs a stop.
pub fn far(io: std.Io) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
}
