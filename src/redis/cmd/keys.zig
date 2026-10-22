//! The commands of keys of `redis.cmd`, whatever they hold: DEL, UNLINK,
//! EXISTS, the time to live with PEXPIRE, PERSIST and PTTL, TYPE, RENAME,
//! one page of SCAN, and PING.
//!
//! A time to live is a `std.Io.Duration` of 1 ms or more, which goes out
//! in milliseconds. `cmd.ttl` reads PTTL into a `redis.Ttl`, and
//! `cmd.keyType` reads TYPE into a `redis.KeyType`: `cmd.Ttl` and
//! `cmd.KeyType` are the types of these commands, not of their replies.
//!
//! SCAN walks the keys a page at a time: the cursor of each page starts
//! the next, and 0 ends the walk. A key may come twice, and the server
//! may give an empty page before the end.
//!
//! ```zig
//! _ = try client.run(io, op, redis.cmd.expire("session:42", .fromSeconds(3600)), .{});
//! const page = try client.run(io, op, redis.cmd.scan(.{ .match = "session:*", .count = 500 }), .{ .allocator = arena });
//! ```

const std = @import("std");
const Io = std.Io;
const command = @import("command.zig");
const types = @import("types.zig");

const Command = command.Command;
const Key = struct { key: []const u8 };
const Keys = struct { keys: []const []const u8 };

/// DEL `keys`: how many of them were there and are gone. One key at
/// least.
pub fn del(keys: []const []const u8) Del {
    return .{ .args = .{ .keys = keys } };
}

pub const Del = Command("redis.cmd.del", "DEL", u64, Keys);

/// UNLINK `keys`: as `del`, but the server frees their memory later, in
/// another thread.
pub fn unlink(keys: []const []const u8) Unlink {
    return .{ .args = .{ .keys = keys } };
}

pub const Unlink = Command("redis.cmd.unlink", "UNLINK", u64, Keys);

/// EXISTS `keys`: how many of them are there; a key named twice counts
/// twice.
pub fn exists(keys: []const []const u8) Exists {
    return .{ .args = .{ .keys = keys } };
}

pub const Exists = Command("redis.cmd.exists", "EXISTS", u64, Keys);

/// PEXPIRE `key` `ms`: the key expires after `duration`, 1 ms or more;
/// false when it is not there. A condition, such as `NX`, goes through
/// `cmd.raw`.
pub fn expire(key: []const u8, duration: Io.Duration) Expire {
    return .{ .args = .{ .key = key, .ttl = duration } };
}

pub const Expire = Command("redis.cmd.expire", "PEXPIRE", bool, struct { key: []const u8, ttl: Io.Duration });

/// PERSIST `key`: the key has no time to live after it; false when it had
/// none, or is not there.
pub fn persist(key: []const u8) Persist {
    return .{ .args = .{ .key = key } };
}

pub const Persist = Command("redis.cmd.persist", "PERSIST", bool, Key);

/// PTTL `key`: how long the key lives, as `redis.Ttl`: missing,
/// persistent, or the time left.
pub fn ttl(key: []const u8) Ttl {
    return .{ .args = .{ .key = key } };
}

pub const Ttl = Command("redis.cmd.ttl", "PTTL", types.Ttl, Key);

/// TYPE `key`: what the key holds, as `redis.KeyType`; `.none` when it is
/// not there, `.other` for a type of a module.
pub fn keyType(key: []const u8) KeyType {
    return .{ .args = .{ .key = key } };
}

pub const KeyType = Command("redis.cmd.keyType", "TYPE", types.KeyType, Key);

/// RENAME `key` `new_key`: the key goes by its new name, over a key that
/// had it. A key that is not there is a ServerError.
pub fn rename(key: []const u8, new_key: []const u8) Rename {
    return .{ .args = .{ .key = key, .new_key = new_key } };
}

pub const Rename = Command("redis.cmd.rename", "RENAME", void, struct { key: []const u8, new_key: []const u8 });

pub const ScanOptions = struct {
    /// The cursor of the page: 0 for the first, then the cursor that the
    /// page before returned, until it returns 0.
    cursor: u64 = 0,
    /// MATCH: only the keys that match this pattern, such as "session:*".
    match: ?[]const u8 = null,
    /// COUNT: about how many keys the server looks at for the page, 10 by
    /// default; a hint, not a limit.
    count: ?u32 = null,
    /// TYPE: only the keys of this type; not `.none` or `.other`.
    type: ?types.KeyType = null,
};

/// SCAN `cursor` [MATCH p] [COUNT n] [TYPE t]: one page of the keys, as
/// `redis.ScanPage([]const u8)`, with the cursor of the next.
pub fn scan(options: ScanOptions) Scan {
    return .{ .key = {}, .options = options };
}

pub const Scan = command.Cursor("redis.cmd.scan", "SCAN", []const u8, ScanOptions, false);

/// PING: the server answers, `+PONG`.
pub fn ping() Ping {
    return .{ .args = .{} };
}

pub const Ping = Command("redis.cmd.ping", "PING", void, struct {});
