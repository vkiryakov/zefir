//! zefir-redis — a client of Redis and Valkey for zefir applications,
//! written against `std.Io` only. It talks to one standalone server,
//! Redis 7.2 or later or Valkey 8 or later, in RESP3 over plain TCP: there
//! is no TLS, so it belongs on a trusted network only.
//!
//! - `redis.cmd` — the commands, as values that the client runs, and
//!   `cmd.raw` for a command that the catalog lacks, with its reply in a
//!   type of the caller's.
//! - `redis.Value` — a reply of any shape, for replies that fit no Zig
//!   type: strings, numbers, doubles, booleans, arrays, sets, maps with
//!   their pairs in the server's order, and errors inside aggregates.
//! - `redis.Error`, `redis.CommandError`, `redis.outcome`,
//!   `redis.Diagnostics` — what can go wrong in a call, whether the server
//!   may have run the command, and the details for logs.
//! - The types of the results and the arguments of the catalog:
//!   `redis.Ttl`, `redis.KeyType`, `redis.ScanPage(T)`, `redis.StreamId`,
//!   `redis.Entry(T)`, `redis.FieldValue` and the others of `cmd/types.zig`.
//! - `redis.testing` — what tests of code on zefir-redis need without a
//!   Redis server.

const std = @import("std");
const errors = @import("errors.zig");
const types = @import("cmd/types.zig");

/// RESP3, for the client and `testing.FakeServer` only.
const resp = @import("resp.zig");

pub const cmd = @import("cmd.zig");
pub const testing = @import("testing.zig");

pub const Value = resp.Value;

pub const Error = errors.Error;
pub const CommandError = errors.CommandError;
pub const Outcome = errors.Outcome;
pub const outcome = errors.outcome;
pub const Diagnostics = errors.Diagnostics;

pub const Ttl = types.Ttl;
pub const KeyType = types.KeyType;
pub const End = types.End;
pub const Block = types.Block;
pub const ScoreBound = types.ScoreBound;
pub const Only = types.Only;
pub const Compare = types.Compare;
pub const Limit = types.Limit;
pub const Scored = types.Scored;
pub const Popped = types.Popped;
pub const FieldValue = types.FieldValue;
pub const KeyValue = types.KeyValue;
pub const ScanPage = types.ScanPage;
pub const StreamId = types.StreamId;
pub const StreamPosition = types.StreamPosition;
pub const GroupPosition = types.GroupPosition;
pub const Trim = types.Trim;
pub const Entry = types.Entry;
pub const PendingSummary = types.PendingSummary;
pub const ConsumerPending = types.ConsumerPending;
pub const Pending = types.Pending;
pub const Claimed = types.Claimed;

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
    _ = @import("cmd/types_tests.zig");
    _ = @import("cmd/raw_tests.zig");
    _ = @import("resp/fuzz.zig");
    _ = testing;
    _ = @import("url_tests.zig");
    _ = @import("engine/time.zig");
    _ = @import("engine/race.zig");
    _ = @import("engine/DeadlineStream.zig");
    _ = @import("engine/connect.zig");
    _ = @import("engine/Address.zig");
    _ = @import("tests/connection_tests.zig");
}

test "the package version reaches the module" {
    try std.testing.expect(@import("build_options").version.len > 0);
}
