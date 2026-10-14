//! zefir-rpc — typed RPC with pluggable transports.
//!
//! A call is one request and one response between two services. zefir-rpc
//! has two layers:
//!
//! - The application layer: a contract written in Zig and shared by the
//!   server and its clients, handlers that implement it, `rpc.Server` and
//!   `rpc.Client`. Requests and responses are your own structs, sent as
//!   JSON and checked with zefir-validator.
//! - The engine under it: `rpc.RawServer` and `rpc.RawClient` route calls,
//!   run handlers, keep limits, deadlines and cancellation, authenticate
//!   callers, run middleware and shut down gracefully, the same way on every
//!   transport. The engine sees bodies as bytes.
//!
//! A transport only delivers the bytes of each call. The engine talks to it
//! through small interfaces, a pointer and a table of functions like
//! `std.mem.Allocator`: `rpc.ClientTransport` on the client side and
//! `rpc.ServerTransport` on the server side, where calls come in through
//! `rpc.transport.Dispatcher` and `rpc.transport.Incoming` and go out through
//! `rpc.transport.Reply`. Zefir ships a memory transport for tests and NATS
//! request-reply in the module `zefir-rpc-nats`. A transport of your own is
//! a type with the methods these interfaces list; `rpc.transport` holds the
//! types and helpers it needs.
//!
//! The transport interfaces are experimental until zefir 1.0: a minor
//! release may change them and says how in its release notes. New entries
//! of the function tables and new fields of `rpc.transport.Info` always come
//! with defaults, so a transport keeps compiling with later releases of the
//! same line.

const std = @import("std");
const model = @import("model.zig");

pub const Route = model.Route;
pub const Metadata = model.Metadata;
pub const Response = model.Response;
pub const Status = model.Status;
pub const Failure = model.Failure;
pub const Violation = model.Violation;

/// The client side of a transport.
pub const ClientTransport = @import("ClientTransport.zig");
/// The server side of a transport.
pub const ServerTransport = @import("ServerTransport.zig");
/// The types and helpers a transport works with.
pub const transport = @import("transport.zig");
/// Helpers for tests of transports and services.
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("model.zig");
    _ = @import("rules.zig");
    _ = @import("signature.zig");
    _ = @import("transport.zig");
    _ = @import("wait.zig");
    _ = @import("ClientTransport.zig");
    _ = @import("ServerTransport.zig");
    _ = @import("Dispatcher.zig");
    _ = @import("Incoming.zig");
    _ = @import("Reply.zig");
    _ = @import("Pending.zig");
    _ = @import("testing.zig");
}
