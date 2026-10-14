//! `rpc.testing`: what tests of rpc transports and services use.
//!
//! - `RecordingDispatcher` — a fake engine for tests of a server
//!   transport: it records what the transport calls and checks the rules
//!   of `rpc.ServerTransport`.

pub const RecordingDispatcher = @import("testing/RecordingDispatcher.zig");

test {
    _ = RecordingDispatcher;
}
