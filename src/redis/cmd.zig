//! `redis.cmd`: the commands, as values. A function of `cmd` sends
//! nothing: it returns a small value whose type knows the command on the
//! wire and the type of its reply, and the client runs it. The value holds
//! the slices it was given, so they must live while it runs; it holds no
//! state, so it may be built once and run many times.
//!
//! The functions are named after the commands of Redis, in lower case; a
//! form of a command with another reply is a function of its own, such as
//! `setNx`. Where the caller picks the type of the reply, it comes first:
//! `get(T, key)`. A duration is a `std.Io.Duration` of 1 ms or more; an
//! empty list where the command takes one or more, a duration under 1 ms
//! and NaN are `error.InvalidArgument` before anything goes out.
//!
//! - Strings and counters: `get`, `set`, `setNx`, `setXx`, `getdel`,
//!   `getex`, `mget`, `mset`, `incr`, `decr`, `incrby`, `decrby`,
//!   `incrbyfloat`.
//! - `raw(T, args)` — a command that the catalog lacks: `args` is a tuple
//!   of strings, numbers, bools and enums, the name of the command first,
//!   or a slice of strings, and the reply reads into `T` by the rules of
//!   the decoder, `redis.Value` for a reply of any shape. `Raw(T, Args)` is
//!   its type.
//! - `watch(keys)`, `unwatch()` — the keys the next transaction of a
//!   `redis.Conn` depends on; only a Conn runs them.
//!
//! The type of each command is named after its function, capitalized:
//! `cmd.Get(T)`, `cmd.Set(V)`, `cmd.Incr`, so that an array of commands
//! of one type can go in a pipeline. What a type is made of is internal.
//!
//! ```zig
//! try client.run(io, op, redis.cmd.set("session:42", token, .{ .ttl = .fromSeconds(3600) }), .{});
//! const rank = try client.run(io, op, redis.cmd.raw(?u64, .{ "ZRANK", "leaders", "ann" }), .{});
//! ```

const std = @import("std");
const raw_command = @import("cmd/raw.zig");
const transactions = @import("cmd/transactions.zig");
const strings = @import("cmd/strings.zig");

pub const get = strings.get;
pub const Get = strings.Get;
pub const set = strings.set;
pub const Set = strings.Set;
pub const SetOptions = strings.SetOptions;
pub const setNx = strings.setNx;
pub const SetNx = strings.SetNx;
pub const SetNxOptions = strings.SetNxOptions;
pub const setXx = strings.setXx;
pub const SetXx = strings.SetXx;
pub const getdel = strings.getdel;
pub const Getdel = strings.Getdel;
pub const getex = strings.getex;
pub const Getex = strings.Getex;
pub const GetexOptions = strings.GetexOptions;
pub const mget = strings.mget;
pub const Mget = strings.Mget;
pub const mset = strings.mset;
pub const Mset = strings.Mset;
pub const incr = strings.incr;
pub const Incr = strings.Incr;
pub const decr = strings.decr;
pub const Decr = strings.Decr;
pub const incrby = strings.incrby;
pub const Incrby = strings.Incrby;
pub const decrby = strings.decrby;
pub const Decrby = strings.Decrby;
pub const incrbyfloat = strings.incrbyfloat;
pub const Incrbyfloat = strings.Incrbyfloat;

pub const raw = raw_command.raw;
pub const Raw = raw_command.Raw;
pub const watch = transactions.watch;
pub const Watch = transactions.Watch;
pub const unwatch = transactions.unwatch;
pub const Unwatch = transactions.Unwatch;

test {
    std.testing.refAllDecls(@This());
}
