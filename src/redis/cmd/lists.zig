//! The list commands of `redis.cmd`: pushes and pops at either end, the
//! length, a range, trimming, removing, an element by its index, LMOVE,
//! and the blocking BLPOP, BRPOP and BLMOVE.
//!
//! The values of LPUSH and RPUSH are a slice of strings, `&.{ "a", "b" }`,
//! or a tuple of values by the rules of arguments, `.{ "a", 42, 1.5 }`.
//! An index counts from 0 at the left end, and from -1 at the right.
//!
//! A blocking command waits on the server until a value comes or its
//! timeout, a `redis.Block`, ends; it holds its connection of the pool all
//! that time. Under a deadline, the server gets what the deadline leaves
//! beyond 150 ms instead, when that is shorter, so that the call ends with
//! null rather than a Timeout; too little left is DeadlineExceeded before
//! anything goes out. A value that the server hands out is gone from the
//! list, so a queue that must not lose one moves it with `blmove` into a
//! list of work in progress, and takes it out of there once done.
//!
//! ```zig
//! const job = try client.run(io, op, redis.cmd.blmove([]const u8, "jobs:new", "jobs:running", .left, .right, .{ .at_most = .fromSeconds(5) }), .{ .allocator = arena });
//! ```

const std = @import("std");
const command = @import("command.zig");
const types = @import("types.zig");

const Command = command.Command;
const End = types.End;
const Block = types.Block;
const Popped = types.Popped;
const Key = struct { key: []const u8 };
const Keys = struct { keys: []const []const u8 };
const Range = struct { key: []const u8, start: i64, stop: i64 };
const Move = struct { source: []const u8, destination: []const u8, from: End, to: End };

/// LPUSH `key` `values`: the values go in at the left end, one after
/// another, so the last ends up first; the length of the list after it.
/// One value at least.
pub fn lpush(key: []const u8, values: anytype) Lpush(command.Values(@TypeOf(values), "redis.cmd.lpush", "values")) {
    return .{ .args = .{ .key = key, .values = command.values(values, "redis.cmd.lpush", "values") } };
}

pub fn Lpush(comptime V: type) type {
    return Command("redis.cmd.lpush", "LPUSH", u64, struct { key: []const u8, values: V });
}

/// RPUSH `key` `values`: the values go in at the right end, in their
/// order; the length of the list after it. One value at least.
pub fn rpush(key: []const u8, values: anytype) Rpush(command.Values(@TypeOf(values), "redis.cmd.rpush", "values")) {
    return .{ .args = .{ .key = key, .values = command.values(values, "redis.cmd.rpush", "values") } };
}

pub fn Rpush(comptime V: type) type {
    return Command("redis.cmd.rpush", "RPUSH", u64, struct { key: []const u8, values: V });
}

/// LPOP `key`: the element at the left end read into `T`, taken out of
/// the list; null when the list is empty.
pub fn lpop(comptime T: type, key: []const u8) Lpop(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Lpop(comptime T: type) type {
    return Command("redis.cmd.lpop", "LPOP", ?T, Key);
}

/// RPOP `key`: the element at the right end, as `lpop` takes it.
pub fn rpop(comptime T: type, key: []const u8) Rpop(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Rpop(comptime T: type) type {
    return Command("redis.cmd.rpop", "RPOP", ?T, Key);
}

/// LLEN `key`: the length of the list, 0 when it is not there.
pub fn llen(key: []const u8) Llen {
    return .{ .args = .{ .key = key } };
}

pub const Llen = Command("redis.cmd.llen", "LLEN", u64, Key);

/// LRANGE `key` `start` `stop`: the elements from index `start` to index
/// `stop`, both included, read into `T`; `0, -1` is the whole list.
pub fn lrange(comptime T: type, key: []const u8, start: i64, stop: i64) Lrange(T) {
    return .{ .args = .{ .key = key, .start = start, .stop = stop } };
}

pub fn Lrange(comptime T: type) type {
    return Command("redis.cmd.lrange", "LRANGE", []const T, Range);
}

/// LTRIM `key` `start` `stop`: the list keeps only the elements from
/// index `start` to index `stop`, both included.
pub fn ltrim(key: []const u8, start: i64, stop: i64) Ltrim {
    return .{ .args = .{ .key = key, .start = start, .stop = stop } };
}

pub const Ltrim = Command("redis.cmd.ltrim", "LTRIM", void, Range);

/// LREM `key` `count` `value`: removes the elements equal to `value`:
/// `count` of them from the left when it is above 0, `-count` from the
/// right when it is below, all for 0; how many it removed.
pub fn lrem(key: []const u8, count: i64, value: anytype) Lrem(command.Arg(@TypeOf(value))) {
    return .{ .args = .{ .key = key, .count = count, .value = command.arg(value) } };
}

pub fn Lrem(comptime V: type) type {
    command.checkArg(V, "redis.cmd.lrem", "value");
    return Command("redis.cmd.lrem", "LREM", u64, struct { key: []const u8, count: i64, value: V });
}

/// LINDEX `key` `index`: the element at `index` read into `T`; null when
/// the list has none there.
pub fn lindex(comptime T: type, key: []const u8, index: i64) Lindex(T) {
    return .{ .args = .{ .key = key, .index = index } };
}

pub fn Lindex(comptime T: type) type {
    return Command("redis.cmd.lindex", "LINDEX", ?T, struct { key: []const u8, index: i64 });
}

/// LMOVE `source` `destination` LEFT|RIGHT LEFT|RIGHT: takes the element
/// at the end `from` of `source` and puts it at the end `to` of
/// `destination`, in one step; the element read into `T`, or null when
/// `source` is empty.
pub fn lmove(comptime T: type, source: []const u8, destination: []const u8, from: End, to: End) Lmove(T) {
    return .{ .args = .{ .source = source, .destination = destination, .from = from, .to = to } };
}

pub fn Lmove(comptime T: type) type {
    return Command("redis.cmd.lmove", "LMOVE", ?T, Move);
}

/// BLPOP `keys` `timeout`: `lpop` of the first of the lists that has an
/// element, waiting up to `timeout` for one; the list's key and its
/// element, or null when none came. One key at least.
pub fn blpop(comptime T: type, keys: []const []const u8, timeout: Block) Blpop(T) {
    return .{ .args = .{ .keys = keys }, .wait = timeout };
}

pub fn Blpop(comptime T: type) type {
    return command.Blocking("redis.cmd.blpop", "BLPOP", ?Popped(T), Keys, "redis.cmd.lpop");
}

/// BRPOP `keys` `timeout`: as `blpop`, from the right end.
pub fn brpop(comptime T: type, keys: []const []const u8, timeout: Block) Brpop(T) {
    return .{ .args = .{ .keys = keys }, .wait = timeout };
}

pub fn Brpop(comptime T: type) type {
    return command.Blocking("redis.cmd.brpop", "BRPOP", ?Popped(T), Keys, "redis.cmd.rpop");
}

/// BLMOVE `source` `destination` LEFT|RIGHT LEFT|RIGHT `timeout`: `lmove`
/// that waits up to `timeout` for an element of `source`; null when none
/// came.
pub fn blmove(comptime T: type, source: []const u8, destination: []const u8, from: End, to: End, timeout: Block) Blmove(T) {
    return .{ .args = .{ .source = source, .destination = destination, .from = from, .to = to }, .wait = timeout };
}

pub fn Blmove(comptime T: type) type {
    return command.Blocking("redis.cmd.blmove", "BLMOVE", ?T, Move, "redis.cmd.lmove");
}
