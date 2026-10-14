//! `rpc.testing`: what tests of rpc transports and services use.
//!
//! - `Server` — the handlers of a service on a memory transport, with the
//!   whole chain of `rpc.Server`, and clients on the same transport: a
//!   service is tested without a network.
//! - `StaticAuthenticator` — an authenticator that gives every call with
//!   credentials the same identity.
//! - `MemoryTransport` — a transport inside one process, with hooks for
//!   failures: the engine and services are tested without a network.
//! - `RecordingDispatcher` — a fake engine for tests of a server
//!   transport: it records what the transport calls and checks the rules
//!   of `rpc.ServerTransport`.
//! - `conformance` — the suite every transport passes: the rules of
//!   `rpc.ClientTransport` and `rpc.ServerTransport`, checked through the
//!   engine and the recording dispatcher.

pub const Server = @import("testing/Server.zig");
pub const StaticAuthenticator = @import("testing/StaticAuthenticator.zig");
pub const MemoryTransport = @import("testing/MemoryTransport.zig");
pub const RecordingDispatcher = @import("testing/RecordingDispatcher.zig");
pub const conformance = @import("testing/conformance.zig");

test {
    _ = Server;
    _ = StaticAuthenticator;
    _ = MemoryTransport;
    _ = RecordingDispatcher;
    _ = conformance;
    _ = @import("testing/conformance_tests.zig");
    _ = @import("testing/mini_app.zig");
}
