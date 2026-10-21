//! zefir-redis — a client of Redis and Valkey for zefir applications,
//! written against `std.Io` only. It talks to one standalone server,
//! Redis 7.2 or later or Valkey 8 or later, in RESP3 over plain TCP: there
//! is no TLS, so it belongs on a trusted network only.
//!
//! - `redis.Value` — a reply of any shape, for replies that fit no Zig
//!   type: strings, numbers, doubles, booleans, arrays, sets, maps with
//!   their pairs in the server's order, and errors inside aggregates.
//! - `redis.Error`, `redis.CommandError`, `redis.outcome`,
//!   `redis.Diagnostics` — what can go wrong in a call, whether the server
//!   may have run the command, and the details for logs.

const std = @import("std");
const errors = @import("errors.zig");
const types = @import("cmd/types.zig");

/// RESP3, for the client and `testing.FakeServer` only.
const resp = @import("resp.zig");

pub const Value = resp.Value;

pub const Error = errors.Error;
pub const CommandError = errors.CommandError;
pub const Outcome = errors.Outcome;
pub const outcome = errors.outcome;
pub const Diagnostics = errors.Diagnostics;

pub const FieldValue = types.FieldValue;

test {
    std.testing.refAllDecls(@This());
    _ = @import("errors_tests.zig");
    _ = resp;
    _ = @import("resp/writer_tests.zig");
    _ = @import("resp/reader_tests.zig");
    _ = @import("resp/value_tests.zig");
    _ = @import("resp/args_tests.zig");
    _ = @import("resp/decode_tests.zig");
    _ = @import("resp/hash_tests.zig");
    _ = @import("resp/fuzz.zig");
}

test "the package version reaches the module" {
    try std.testing.expect(@import("build_options").version.len > 0);
}
