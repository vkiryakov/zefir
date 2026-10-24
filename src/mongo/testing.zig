//! `mongo.testing`: what tests of code on zefir-mongo need without a
//! MongoDB server.
//!
//! - `Script` — a scripted server: what it says in hello, a handler that
//!   answers each command (ready ones: a queue of answers, a cursor from a
//!   list of batches, a write that refuses given items), and the journal
//!   of what came.
//! - `FakeServer` — serves a `Script` on loopback, at
//!   `mongodb://127.0.0.1:<port>`, to a `mongo.Client`: the tests of code
//!   on the collection API and of applications run on the real client,
//!   with real deadlines and cancelation. Or it lets a test play the
//!   server's side of one connection with a raw `Peer`.
//! - `sleepAtLeast` — a sleep that never ends before its time, which a
//!   sleep of std's `Io` on Windows may do: for delays and deadlines in
//!   tests.

const std = @import("std");

pub const Script = @import("testing/Script.zig");
pub const FakeServer = @import("testing/FakeServer.zig");
pub const sleepAtLeast = @import("testing/sleep.zig").sleepAtLeast;

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/script_tests.zig");
    _ = @import("testing/fake_server_tests.zig");
    _ = @import("testing/sleep.zig");
}
