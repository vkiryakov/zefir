//! `mongo.testing`: what tests of code on zefir-mongo need without a
//! MongoDB server.
//!
//! - `Script` — a scripted server: what it says in hello, a handler that
//!   answers each command (ready ones: a queue of answers, a cursor from a
//!   list of batches, a write that refuses given items), and the journal
//!   of what came.
//! - `FakeServer` — serves a `Script` on loopback to a driver that speaks
//!   MongoDB's wire protocol, or lets a test play the server's side of one
//!   connection with a raw `Peer`.
//! - `FakeDriver` — a `mongo.Client` in the process over a `Script`, for
//!   the tests of code on the collection API and of applications: no
//!   network, real deadlines and cancelation.

const std = @import("std");

pub const Script = @import("testing/Script.zig");
pub const FakeServer = @import("testing/FakeServer.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/script_tests.zig");
    _ = @import("testing/fake_server_tests.zig");
}
