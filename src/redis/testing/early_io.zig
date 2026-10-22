//! For the tests of `redis.testing`: `std.testing.io` with sleeps that end
//! early, as a sleep of std's `Io` on Windows may end a tick of its timer
//! (about 15.6 ms) before its time. Everything but `sleep` is
//! `std.testing.io` itself.

const std = @import("std");
const Io = std.Io;

/// How much earlier than asked each sleep of `io()` ends.
pub const early: Io.Duration = .fromMilliseconds(16);

const vtable: Io.VTable = vtable: {
    var v = std.testing.io.vtable.*;
    v.sleep = sleep;
    break :vtable v;
};

/// `std.testing.io` whose sleeps end `early`.
pub fn io() Io {
    return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const shortened: Io.Timeout = switch (timeout) {
        .none => .none,
        .duration => |d| .{ .duration = .{ .raw = .fromNanoseconds(@max(0, d.raw.nanoseconds - early.nanoseconds)), .clock = d.clock } },
        .deadline => |d| .{ .deadline = d.subDuration(.{ .raw = early, .clock = d.clock }) },
    };
    return std.testing.io.vtable.sleep(userdata, shortened);
}
