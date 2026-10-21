//! Test support for services that use zefir-jwt. `verify` and `sign` read
//! the time from the clock of their `std.Io`, so a test sets the time
//! through that `Io` with `FixedClock`, and the code under test stays as
//! it runs in production.

const std = @import("std");

/// A `std.Io` whose clock `.real` says the time the test sets, in seconds
/// of Unix time; every other operation, the other clocks among them, goes
/// to the base `Io` unchanged.
///
/// ```zig
/// var clock: jwt.testing.FixedClock = try .init(std.testing.io, 1_760_000_000);
/// defer clock.deinit();
/// const io = clock.io(); // for the server, the backend, the verifier and the signer
/// clock.set(1_760_000_000 + 3600); // the token has expired now
/// ```
///
/// Its limits:
/// - One clock per process: the `now` of an `Io` gets the base's userdata,
///   not the clock, so the time lives in this module, and a second `init`
///   while one clock lives is `error.ClockInUse`. The tests that use it run
///   one at a time, as the test runner runs the tests of one binary.
/// - `.awake` is not changed: the timeouts and sleeps of the `Io` itself,
///   and the deadlines of http and rpc, run on it.
/// - Every user of the returned `Io` sees the fixed `.real`, such as the
///   `Date` header of http.
pub const FixedClock = struct {
    /// The base `Io`'s userdata.
    userdata: ?*anyopaque,

    /// Takes the clock of the process at `seconds`. `ClockInUse`: another
    /// `FixedClock` lives; `deinit` gives the clock back.
    pub fn init(base: std.Io, seconds: i64) error{ClockInUse}!FixedClock {
        if (in_use.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ClockInUse;
        fixed_seconds.store(seconds, .release);
        base_vtable = base.vtable;
        patched = base.vtable.*;
        patched.now = now;
        return .{ .userdata = base.userdata };
    }

    /// The `Io` with the fixed clock; a copy of the `FixedClock` gives the
    /// same one.
    pub fn io(clock: *const FixedClock) std.Io {
        return .{ .userdata = clock.userdata, .vtable = &patched };
    }

    /// Sets the time of `.real`, in seconds of Unix time.
    pub fn set(clock: *const FixedClock, seconds: i64) void {
        _ = clock;
        fixed_seconds.store(seconds, .release);
    }

    /// Gives the clock of the process back; the `Io` of `io()` must not
    /// be used afterwards.
    pub fn deinit(clock: *FixedClock) void {
        clock.* = undefined;
        in_use.store(false, .release);
    }
};

var in_use: std.atomic.Value(bool) = .init(false);
var fixed_seconds: std.atomic.Value(i64) = .init(0);
var base_vtable: *const std.Io.VTable = undefined;
var patched: std.Io.VTable = undefined;

fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    return switch (clock) {
        .real => .fromNanoseconds(@as(i96, fixed_seconds.load(.acquire)) * std.time.ns_per_s),
        else => base_vtable.now(userdata, clock),
    };
}

test "FixedClock answers real with its time and leaves awake alone" {
    var clock: FixedClock = try .init(std.testing.io, 1_760_000_000);
    defer clock.deinit();
    const io = clock.io();
    try std.testing.expectEqual(1_760_000_000, std.Io.Clock.real.now(io).toSeconds());
    clock.set(1_760_003_600);
    try std.testing.expectEqual(1_760_003_600, std.Io.Clock.real.now(io).toSeconds());
    const before = std.Io.Clock.awake.now(std.testing.io);
    const during = std.Io.Clock.awake.now(io);
    const after = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(before.nanoseconds <= during.nanoseconds);
    try std.testing.expect(during.nanoseconds <= after.nanoseconds);
    // A copy of the clock gives the same Io.
    const moved = clock;
    try std.testing.expectEqual(1_760_003_600, std.Io.Clock.real.now(moved.io()).toSeconds());
}

test "a second FixedClock while one lives is ClockInUse" {
    var first: FixedClock = try .init(std.testing.io, 1);
    try std.testing.expectError(error.ClockInUse, FixedClock.init(std.testing.io, 2));
    first.deinit();
    var second: FixedClock = try .init(std.testing.io, 3);
    defer second.deinit();
    try std.testing.expectEqual(3, std.Io.Clock.real.now(second.io()).toSeconds());
}
