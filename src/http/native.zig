//! `http.native`: the backend of a server on
//! the network, over `std.Io` (zio in production): connections, the heads
//! and bodies of requests, responses, keep-alive and pipelining, and the
//! watcher that sees a client leave. A server makes its own from
//! `.listen = .{ .port = 8080 }`, or from these options:
//!
//! ```zig
//! var server = try http.Server.init(gpa, .{ .controllers = .{&todos_v1} }, .{
//!     .listen = .{ .native = .{ .port = 8080, .timeouts = .{ .idle = .fromSeconds(30) } } },
//! });
//! ```
const backend = @import("native/Backend.zig");

pub const Backend = backend;
pub const Limits = backend.Limits;
pub const Timeouts = backend.Timeouts;
pub const Options = backend.Options;
pub const InitError = backend.InitError;

test {
    _ = backend;
}
