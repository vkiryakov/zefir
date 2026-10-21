//! `redis.testing`: what tests of code on zefir-redis need without a Redis
//! server.
//!
//! - `sleepAtLeast` — a sleep that never ends before its time, which a
//!   sleep of std's `Io` on Windows may do: for delays and deadlines in
//!   tests.

const std = @import("std");

pub const sleepAtLeast = @import("testing/sleep.zig").sleepAtLeast;

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/sleep.zig");
    _ = @import("testing/reply_tests.zig");
}
