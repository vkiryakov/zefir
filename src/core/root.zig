//! zefir-core — the execution context shared by Zefir modules: deadlines,
//! cancellation, W3C trace context and transport-neutral error codes.
//!
//! ```zig
//! var token: core.CancellationToken = .init;
//! const ctx = core.Context.root
//!     .withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(2)))
//!     .withCancellation(&token);
//!
//! fn getUser(ctx: core.Context, io: std.Io, id: u64) !User {
//!     try ctx.check(std.Io.Clock.awake.now(io));
//!     ...
//! }
//! ```
//!
//! Nothing here allocates, reads a clock or does I/O: the caller passes the
//! current time in. A `Context` owns nothing. It borrows the
//! `CancellationToken` and the tracestate bytes of its trace, so it must not
//! outlive the scope that owns them: the request, the call, the message or
//! the job. Pass contexts down by value, and the allocator and `std.Io` as
//! separate parameters.

const std = @import("std");
const errors = @import("errors.zig");
const trace = @import("trace.zig");

pub const Context = @import("Context.zig");
pub const CancellationToken = @import("CancellationToken.zig");
pub const TraceId = trace.TraceId;
pub const SpanId = trace.SpanId;
pub const TraceFlags = trace.TraceFlags;
pub const TraceState = trace.TraceState;
pub const TraceContext = trace.TraceContext;
pub const Deadline = @import("Deadline.zig");
pub const ErrorCode = errors.ErrorCode;
pub const ErrorInfo = errors.ErrorInfo;
pub const ContextError = errors.ContextError;

test {
    std.testing.refAllDecls(@This());
    _ = @import("Context.zig");
    _ = @import("CancellationToken.zig");
    _ = @import("Deadline.zig");
    _ = @import("errors.zig");
    _ = @import("trace.zig");
}
