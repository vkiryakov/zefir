//! `rpc.testing`: what tests of rpc transports and services use.
//!
//! - `MemoryTransport` — a transport inside one process, with hooks for
//!   failures: the engine and services are tested without a network.
//! - `RecordingDispatcher` — a fake engine for tests of a server
//!   transport: it records what the transport calls and checks the rules
//!   of `rpc.ServerTransport`.

pub const MemoryTransport = @import("testing/MemoryTransport.zig");
pub const RecordingDispatcher = @import("testing/RecordingDispatcher.zig");

test {
    _ = MemoryTransport;
    _ = RecordingDispatcher;
}
