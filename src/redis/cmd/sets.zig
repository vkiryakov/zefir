//! The set commands of `redis.cmd`: adding and removing members, a test
//! of one, all of them, the count, a member taken at random, the
//! intersection, union and difference of sets, and one page of SSCAN.
//!
//! The members of a set have no order: a server answers them as a set,
//! read into a slice of `T` in the order it sent them.
//!
//! ```zig
//! _ = try client.run(io, op, redis.cmd.sadd("tags:post:7", &.{ "zig", "redis" }), .{});
//! const tags = try client.run(io, op, redis.cmd.smembers([]const u8, "tags:post:7"), .{ .allocator = arena });
//! ```

const std = @import("std");
const command = @import("command.zig");

const Command = command.Command;
const Key = struct { key: []const u8 };
const Keys = struct { keys: []const []const u8 };
const Members = struct { key: []const u8, members: []const []const u8 };

/// SADD `key` `members`: how many of them were new to the set. One member
/// at least.
pub fn sadd(key: []const u8, members: []const []const u8) Sadd {
    return .{ .args = .{ .key = key, .members = members } };
}

pub const Sadd = Command("redis.cmd.sadd", "SADD", u64, Members);

/// SREM `key` `members`: how many of them were in the set and are gone.
/// One member at least.
pub fn srem(key: []const u8, members: []const []const u8) Srem {
    return .{ .args = .{ .key = key, .members = members } };
}

pub const Srem = Command("redis.cmd.srem", "SREM", u64, Members);

/// SISMEMBER `key` `member`: whether the set has the member.
pub fn sismember(key: []const u8, member: []const u8) Sismember {
    return .{ .args = .{ .key = key, .member = member } };
}

pub const Sismember = Command("redis.cmd.sismember", "SISMEMBER", bool, struct { key: []const u8, member: []const u8 });

/// SMEMBERS `key`: the members of the set read into `T`; none when it is
/// not there.
pub fn smembers(comptime T: type, key: []const u8) Smembers(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Smembers(comptime T: type) type {
    return Command("redis.cmd.smembers", "SMEMBERS", []const T, Key);
}

/// SCARD `key`: how many members the set has, 0 when it is not there.
pub fn scard(key: []const u8) Scard {
    return .{ .args = .{ .key = key } };
}

pub const Scard = Command("redis.cmd.scard", "SCARD", u64, Key);

/// SPOP `key`: a member taken out of the set at random, read into `T`;
/// null when the set is empty.
pub fn spop(comptime T: type, key: []const u8) Spop(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Spop(comptime T: type) type {
    return Command("redis.cmd.spop", "SPOP", ?T, Key);
}

/// SINTER `keys`: the members that every one of the sets has. One key at
/// least.
pub fn sinter(comptime T: type, keys: []const []const u8) Sinter(T) {
    return .{ .args = .{ .keys = keys } };
}

pub fn Sinter(comptime T: type) type {
    return Command("redis.cmd.sinter", "SINTER", []const T, Keys);
}

/// SUNION `keys`: the members that any of the sets has. One key at least.
pub fn sunion(comptime T: type, keys: []const []const u8) Sunion(T) {
    return .{ .args = .{ .keys = keys } };
}

pub fn Sunion(comptime T: type) type {
    return Command("redis.cmd.sunion", "SUNION", []const T, Keys);
}

/// SDIFF `keys`: the members of the first set that none of the others
/// has. One key at least.
pub fn sdiff(comptime T: type, keys: []const []const u8) Sdiff(T) {
    return .{ .args = .{ .keys = keys } };
}

pub fn Sdiff(comptime T: type) type {
    return Command("redis.cmd.sdiff", "SDIFF", []const T, Keys);
}

/// SSCAN `key` `cursor` [MATCH p] [COUNT n]: one page of the members of
/// the set, as `redis.ScanPage([]const u8)`, with the cursor of the next.
pub fn sscan(key: []const u8, options: command.CursorOptions) Sscan {
    return .{ .key = key, .options = options };
}

pub const Sscan = command.Cursor("redis.cmd.sscan", "SSCAN", []const u8, command.CursorOptions, true);
