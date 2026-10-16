//! `rpc_nats.testing`: what tests of services on NATS use.
//!
//! - `FakeConn` — an in-memory NATS server and a connection to it: the
//!   transport and the services on it are tested without a network, and
//!   the hooks of `FakeConn` break the link, close it, delay messages and
//!   deny permissions.

pub const FakeConn = @import("testing/FakeConn.zig");

test {
    _ = FakeConn;
}
