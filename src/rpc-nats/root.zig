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
//! ```zig
//! var bus: rpc_nats.Transport = try .init(gpa, adapter.conn(), .{});
//! defer bus.deinit(io);
//! var server: rpc.Server = try .init(gpa, .{ .transport = bus.serverTransport(), .handlers = .{&users} });
//! defer server.deinit();
//! ```
//!
//! The transport needs six operations from a NATS connection,
//! `rpc_nats.Conn`; an adapter of a NATS library fills them in, and every
//! library then puts the same bytes on the wire.

const std = @import("std");

/// What the transport needs from a NATS connection.
pub const Conn = @import("Conn.zig");
/// The NATS transport: both sides of rpc on one NATS connection.
pub const Transport = @import("Transport.zig");
/// Helpers for tests of services on NATS.
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("Conn.zig");
    _ = @import("subject.zig");
    _ = @import("wire.zig");
    _ = @import("Transport.zig");
    _ = @import("testing.zig");
    _ = @import("server_tests.zig");
    _ = @import("client_tests.zig");
}
