//! `resp`: RESP3, the protocol of Redis and Valkey, inside zefir-redis.
//! The client and `redis.testing.FakeServer` use it. It holds no network
//! code: it writes to a `std.Io.Writer` and reads from a `std.Io.Reader`.
//!
//! - `Writer` — commands: arrays of bulk strings, written into the buffer
//!   of the connection, a large argument without a copy.

const std = @import("std");

pub const Writer = @import("resp/Writer.zig");

test {
    std.testing.refAllDecls(@This());
}
