//! `resp`: RESP3, the protocol of Redis and Valkey, inside zefir-redis.
//! The client and `redis.testing.FakeServer` use it. It holds no network
//! code: it writes to a `std.Io.Writer` and reads from a `std.Io.Reader`.
//!
//! - `Writer` — commands: arrays of bulk strings, written into the buffer
//!   of the connection, a large argument without a copy.
//! - `Reader` — a reply as a stream of elements, one at a time and with no
//!   recursion, within a budget of bytes and `Reader.max_depth` levels;
//!   it skips attributes and reports a push at the top level.
//! - `Value`, `readValue` and `readValueFrom` — a whole reply of any shape,
//!   read into an arena; `redis.Value` is this type.

const std = @import("std");
const value = @import("resp/value.zig");

pub const Writer = @import("resp/Writer.zig");
pub const Reader = @import("resp/Reader.zig");
pub const Value = value.Value;
pub const readValue = value.read;
pub const readValueFrom = value.readFrom;

test {
    std.testing.refAllDecls(@This());
}
