//! zefir-rpc-nats — the calls of zefir-rpc over NATS request-reply.
//!
//! Security first: zefir-nats has no TLS yet, so the link to the broker is
//! plain text, tokens from `authorization` and the data of calls included.
//! Until it has, run rpc over NATS only in a closed network, and give every
//! service NATS permissions of its own (the guide has a recipe).
//!
//! A request is published to the subject of its method,
//! `[subject_prefix.]service.v<version>.method`, with a reply subject in
//! the client's own inbox; the response comes back there. Errors travel in
//! the headers of the NATS Service API (ADR-32), so `nats req` and NATS
//! clients in other languages can call a zefir service.
//!
//! The transport needs six operations from a NATS connection,
//! `rpc_nats.Conn`; an adapter of a NATS library fills them in, and every
//! library then puts the same bytes on the wire.

const std = @import("std");

/// What the transport needs from a NATS connection.
pub const Conn = @import("Conn.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Conn.zig");
}
