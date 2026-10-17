//! `http.native` (design sections 14 and 15): the backend of a server on
//! the network, over `std.Io` (zio in production): connections, the heads
//! of requests, responses, keep-alive and pipelining, and the watcher that
//! sees a client leave.
//!
//! ```zig
//! var native = try http.native.Backend.init(gpa, .{
//!     .port = 8080,
//!     .timeouts = .{ .idle = .fromSeconds(30) },
//! });
//! defer native.deinit();
//! var server = try http.Server.init(gpa, .{ .backend = native.backend(), .controllers = .{&todos_v1} });
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
