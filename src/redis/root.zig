//! zefir-redis — a client of Redis and Valkey for zefir applications,
//! written against `std.Io` only. It talks to one standalone server,
//! Redis 7.2 or later or Valkey 8 or later, in RESP3 over plain TCP: there
//! is no TLS, so it belongs on a trusted network only.
//!
//! - `redis.Value` — a reply of any shape, for replies that fit no Zig
//!   type: strings, numbers, doubles, booleans, arrays, sets, maps with
//!   their pairs in the server's order, and errors inside aggregates.

const std = @import("std");

/// RESP3, for the client and `testing.FakeServer` only.
const resp = @import("resp.zig");

pub const Value = resp.Value;

test {
    std.testing.refAllDecls(@This());
    _ = resp;
    _ = @import("resp/writer_tests.zig");
    _ = @import("resp/reader_tests.zig");
    _ = @import("resp/value_tests.zig");
    _ = @import("resp/fuzz.zig");
}

test "the package version reaches the module" {
    try std.testing.expect(@import("build_options").version.len > 0);
}
