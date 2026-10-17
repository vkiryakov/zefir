//! zefir-http: the web framework of zefir. An `http.Server` serves the
//! controllers of an application, whose routes are known when it is built:
//! a strict HTTP/1.1 parser of its own, the request input and output read
//! from the `field_rules` of zefir-validator, middleware of the
//! application, one error handler, static files, streamed responses and
//! SSE. The network backend runs on `std.Io` (zio in production), and an
//! in-memory backend serves the same server to tests.
//!
//! Status: in progress. So far the module holds its HTTP/1.1 parser
//! (h1/, internal); the API comes with the next commits.

const std = @import("std");

test "zefir-http is wired into the build" {
    try std.testing.expect(true);
}

test {
    _ = @import("h1/head.zig");
    _ = @import("h1/chunked.zig");
    _ = @import("h1/fuzz.zig");
}
