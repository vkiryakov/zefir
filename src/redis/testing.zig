//! `redis.testing`: what tests of code on zefir-redis need without a Redis
//! server.
//!
//! - `FakeServer` — a scripted Redis on loopback, at
//!   `redis://127.0.0.1:<port>`, for a real `redis.Client`: the tests of
//!   applications run on the real client, with real deadlines and
//!   cancelation. It answers the handshake itself, plays the steps of its
//!   script, and keeps a journal of the commands that came.
//! - `sleepAtLeast` — a sleep that never ends before its time, which a
//!   sleep of std's `Io` on Windows may do: for delays and deadlines in
//!   tests.

const std = @import("std");

pub const FakeServer = @import("testing/FakeServer.zig");
pub const sleepAtLeast = @import("testing/sleep.zig").sleepAtLeast;

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/sleep.zig");
    _ = @import("testing/reply_tests.zig");
    _ = @import("testing/fake_server_tests.zig");
}
