//! zefir-redis — a client of Redis and Valkey for zefir applications,
//! written against `std.Io` only. It talks to one standalone server,
//! Redis 7.2 or later or Valkey 8 or later, in RESP3 over plain TCP: there
//! is no TLS, so it belongs on a trusted network only.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

test "the package version reaches the module" {
    try std.testing.expect(@import("build_options").version.len > 0);
}
