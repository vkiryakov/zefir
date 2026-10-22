//! `redis.cmd`: the commands, as values. A function of `cmd` sends
//! nothing: it returns a small value whose type knows the command on the
//! wire and the type of its reply, and the client runs it. The value holds
//! the slices it was given, so they must live while it runs; it holds no
//! state, so it may be built once and run many times.
//!
//! - `raw(T, args)` — a command that the catalog lacks: `args` is a tuple
//!   of strings, numbers, bools and enums, the name of the command first,
//!   or a slice of strings, and the reply reads into `T` by the rules of
//!   the decoder, `redis.Value` for a reply of any shape. `Raw(T, Args)` is
//!   its type.
//!
//! - `watch(keys)`, `unwatch()` — the keys the next transaction of a
//!   `redis.Conn` depends on; only a Conn runs them. `Watch` and
//!   `Unwatch` are their types.
//!
//! ```zig
//! const rank = try client.run(io, op, redis.cmd.raw(?u64, .{ "ZRANK", "leaders", "ann" }), .{});
//! ```

const std = @import("std");
const raw_command = @import("cmd/raw.zig");
const transactions = @import("cmd/transactions.zig");

pub const raw = raw_command.raw;
pub const Raw = raw_command.Raw;
pub const watch = transactions.watch;
pub const Watch = transactions.Watch;
pub const unwatch = transactions.unwatch;
pub const Unwatch = transactions.Unwatch;

test {
    std.testing.refAllDecls(@This());
}
