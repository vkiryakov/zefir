//! A key-value store in memory with the calls of Redis that the examples
//! need: it stands in for a Redis client on `std.Io`, which a service
//! connects in `main` and hands to its middleware. Like such a client, it
//! waits only through `std.Io`, and every call fails with
//! `error.Unavailable` while the store is down.

const std = @import("std");

const Store = @This();

gpa: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
/// False: every call fails, as a client of a Redis that is down does.
up: std.atomic.Value(bool) = .init(true),

const Entry = struct { count: u64, expires: std.Io.Timestamp };

pub const Error = error{ Unavailable, OutOfMemory } || std.Io.Cancelable;

pub fn init(gpa: std.mem.Allocator) Store {
    return .{ .gpa = gpa };
}

pub fn deinit(store: *Store) void {
    for (store.entries.keys()) |key| store.gpa.free(key);
    store.entries.deinit(store.gpa);
}

/// INCR, and EXPIRE for a new key: how many times `key` was counted within
/// `ttl` of its first count.
pub fn incrWithExpire(store: *Store, io: std.Io, key: []const u8, ttl: std.Io.Duration) Error!u64 {
    const entry = try store.live(io, key, ttl);
    defer store.mutex.unlock(io);
    entry.count += 1;
    return entry.count;
}

/// SET NX EX: true when `key` was not there and is set now, for `ttl`.
pub fn setIfAbsent(store: *Store, io: std.Io, key: []const u8, ttl: std.Io.Duration) Error!bool {
    const entry = try store.live(io, key, ttl);
    defer store.mutex.unlock(io);
    entry.count += 1;
    return entry.count == 1;
}

/// The entry of `key`, a new one if it is missing or has expired, with the
/// mutex held.
fn live(store: *Store, io: std.Io, key: []const u8, ttl: std.Io.Duration) Error!*Entry {
    if (!store.up.load(.acquire)) return error.Unavailable;
    try store.mutex.lock(io);
    errdefer store.mutex.unlock(io);
    const now = std.Io.Clock.awake.now(io);
    const fresh: Entry = .{ .count = 0, .expires = now.addDuration(ttl) };
    if (store.entries.getPtr(key)) |entry| {
        if (entry.expires.nanoseconds <= now.nanoseconds) entry.* = fresh;
        return entry;
    }
    const owned = try store.gpa.dupe(u8, key);
    errdefer store.gpa.free(owned);
    try store.entries.put(store.gpa, owned, fresh);
    return store.entries.getPtr(owned).?;
}
