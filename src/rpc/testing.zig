//! `rpc.testing`: what tests of rpc transports and services use.
//!
//! - `MemoryTransport` — a transport inside one process, with hooks for
//!   failures: the engine and services are tested without a network.
//! - `RecordingDispatcher` — a fake engine for tests of a server
//!   transport: it records what the transport calls and checks the rules
//!   of `rpc.ServerTransport`.
//! - `conformance` — the suite every transport passes: the rules of
//!   `rpc.ClientTransport` and `rpc.ServerTransport`, checked through the
//!   engine and the recording dispatcher.

pub const MemoryTransport = @import("testing/MemoryTransport.zig");
pub const RecordingDispatcher = @import("testing/RecordingDispatcher.zig");
pub const conformance = @import("testing/conformance.zig");

test {
    _ = MemoryTransport;
    _ = RecordingDispatcher;
    _ = conformance;
    _ = @import("testing/conformance_tests.zig");
}
