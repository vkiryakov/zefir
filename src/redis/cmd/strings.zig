//! The string and counter commands of `redis.cmd`: GET, SET with its NX
//! and XX forms, GETDEL, GETEX, MGET, MSET, and the counters INCR, DECR,
//! INCRBY, DECRBY and INCRBYFLOAT.
//!
//! A value is a string, a number, a bool or an enum, by the rules of
//! arguments: `cmd.set("views", 0, .{})`. A reply reads into the type the
//! call names, so GET reads a counter back as a number:
//! `cmd.get(i64, "views")`. A time to live is a `std.Io.Duration` of 1 ms
//! or more, which goes out in milliseconds.
//!
//! ```zig
//! try client.run(io, op, redis.cmd.set("session:42", token, .{ .ttl = .fromSeconds(3600) }), .{});
//! const session = try client.run(io, op, redis.cmd.get([]const u8, "session:42"), .{ .allocator = arena });
//! ```

const std = @import("std");
const Io = std.Io;
const resp = @import("../resp.zig");
const hash = @import("../resp/hash.zig");
const command = @import("command.zig");
const KeyValue = @import("types.zig").KeyValue;
const Diagnostics = @import("../errors.zig").Diagnostics;

const Command = command.Command;
const Key = struct { key: []const u8 };
const Keys = struct { keys: []const []const u8 };
const By = struct { key: []const u8, by: i64 };

/// GET `key`: its value read into `T`, a string or a number; null when
/// the key is not there. A hash is `hgetall`.
pub fn get(comptime T: type, key: []const u8) Get(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Get(comptime T: type) type {
    if (hash.isHash(T)) @compileError("redis.cmd.get: GET returns a string; a hash is hgetall");
    return Command("redis.cmd.get", "GET", ?T, Key);
}

/// The options of `set` and `setXx`: the time to live of the key.
pub const SetOptions = struct {
    /// PX: the key expires after this time, 1 ms or more. Null: the key
    /// has no time to live, or with `keep_ttl` the one it had.
    ttl: ?Io.Duration = null,
    /// KEEPTTL: the key keeps the time to live it had; not with `ttl`.
    keep_ttl: bool = false,
};

/// The options of `setNx`: the time to live of a new key.
pub const SetNxOptions = struct {
    /// PX: the key expires after this time, 1 ms or more.
    ttl: ?Io.Duration = null,
};

/// SET `key` `value` [PX ms] [KEEPTTL]: the key holds `value`, whatever
/// it held before.
pub fn set(key: []const u8, value: anytype, options: SetOptions) Set(command.Arg(@TypeOf(value))) {
    return .{ .key = key, .value = command.arg(value), .options = options };
}

pub fn Set(comptime V: type) type {
    return Store(V, .always);
}

/// SET `key` `value` NX [PX ms]: true when the key was not there and now
/// holds `value`; false when it was there, and it keeps its own. A lock
/// with a time to live is one: `cmd.setNx("lock:order:7", owner, .{ .ttl = .fromSeconds(30) })`.
pub fn setNx(key: []const u8, value: anytype, options: SetNxOptions) SetNx(command.Arg(@TypeOf(value))) {
    return .{ .key = key, .value = command.arg(value), .options = options };
}

pub fn SetNx(comptime V: type) type {
    return Store(V, .absent);
}

/// SET `key` `value` XX [PX ms] [KEEPTTL]: true when the key was there and
/// now holds `value`; false when it was not there, and it still is not.
pub fn setXx(key: []const u8, value: anytype, options: SetOptions) SetXx(command.Arg(@TypeOf(value))) {
    return .{ .key = key, .value = command.arg(value), .options = options };
}

pub fn SetXx(comptime V: type) type {
    return Store(V, .present);
}

/// Which SET: always, only when the key is absent (NX), or only when it is
/// present (XX).
const When = enum { always, absent, present };

fn Store(comptime V: type, comptime when: When) type {
    const call = switch (when) {
        .always => "redis.cmd.set",
        .absent => "redis.cmd.setNx",
        .present => "redis.cmd.setXx",
    };
    command.checkArg(V, call, "value");
    return struct {
        key: []const u8,
        value: V,
        options: if (when == .absent) SetNxOptions else SetOptions,

        const Self = @This();

        /// Whether it wrote, for NX and XX.
        pub const Reply = if (when == .always) void else bool;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            try command.checkFields(.{ .value = c.value }, call, "SET", diagnostics);
            if (c.options.ttl) |ttl| _ = try command.millis(ttl, call, ".ttl", diagnostics);
            if (c.keepTtl() and c.options.ttl != null) {
                return command.invalid(diagnostics, call ++ ": .ttl and .keep_ttl together: give the key a new time to live, or keep the one it has", .{});
            }
        }

        fn keepTtl(c: Self) bool {
            return if (when == .absent) false else c.options.keep_ttl;
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const ttl: usize = if (c.options.ttl == null) 0 else 2;
            try w.arrayHeader(@as(usize, 3) + @intFromBool(when != .always) + ttl + @intFromBool(c.keepTtl()));
            try w.bulk("SET");
            try w.bulk(c.key);
            try resp.args.write(w, c.value);
            switch (when) {
                .always => {},
                .absent => try w.bulk("NX"),
                .present => try w.bulk("XX"),
            }
            if (c.options.ttl) |duration| {
                try w.bulk("PX");
                try command.writeMillis(w, duration);
            }
            if (c.keepTtl()) try w.bulk("KEEPTTL");
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!Reply {
            if (when == .always) return resp.decode(void, r, arena, diagnostics);
            // +OK when it wrote, null when it did not.
            const wrote = try resp.decode(?void, r, arena, diagnostics);
            return wrote != null;
        }

        pub fn name(_: Self) []const u8 {
            return "SET";
        }
    };
}

/// GETDEL `key`: its value, as `get` reads it, and the key is gone; null
/// when it was not there.
pub fn getdel(comptime T: type, key: []const u8) Getdel(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Getdel(comptime T: type) type {
    return Command("redis.cmd.getdel", "GETDEL", ?T, Key);
}

/// The options of `getex`: a new time to live, or none.
pub const GetexOptions = struct {
    /// PX: a new time to live, 1 ms or more; not with `persist`.
    ttl: ?Io.Duration = null,
    /// PERSIST: the key has no time to live after it; not with `ttl`.
    persist: bool = false,
};

/// GETEX `key` [PX ms | PERSIST]: its value, as `get` reads it, and a new
/// time to live for the key, or none; null when it is not there.
pub fn getex(comptime T: type, key: []const u8, options: GetexOptions) Getex(T) {
    return .{ .key = key, .options = options };
}

pub fn Getex(comptime T: type) type {
    const call = "redis.cmd.getex";
    resp.checkReply(?T, call);
    return struct {
        key: []const u8,
        options: GetexOptions,

        const Self = @This();

        pub const Reply = ?T;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            if (c.options.ttl) |ttl| _ = try command.millis(ttl, call, ".ttl", diagnostics);
            if (c.options.persist and c.options.ttl != null) {
                return command.invalid(diagnostics, call ++ ": .ttl and .persist together: give the key a new time to live, or take the one it has away", .{});
            }
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const ttl: usize = if (c.options.ttl == null) 0 else 2;
            try w.arrayHeader(2 + ttl + @intFromBool(c.options.persist));
            try w.bulk("GETEX");
            try w.bulk(c.key);
            if (c.options.ttl) |duration| {
                try w.bulk("PX");
                try command.writeMillis(w, duration);
            }
            if (c.options.persist) try w.bulk("PERSIST");
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!Reply {
            return resp.decode(?T, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "GETEX";
        }
    };
}

/// MGET `keys`: the value of each key, as `get` reads it, in their order,
/// null for one that is not there. One key at least.
pub fn mget(comptime T: type, keys: []const []const u8) Mget(T) {
    return .{ .args = .{ .keys = keys } };
}

pub fn Mget(comptime T: type) type {
    return Command("redis.cmd.mget", "MGET", []const ?T, Keys);
}

/// MSET: each key of `pairs` holds its value, all at once. One pair at
/// least.
pub fn mset(pairs: []const KeyValue) Mset {
    return .{ .args = .{ .pairs = pairs } };
}

pub const Mset = Command("redis.cmd.mset", "MSET", void, struct { pairs: []const KeyValue });

/// INCR `key`: the counter one up, from 0 when the key is not there.
pub fn incr(key: []const u8) Incr {
    return .{ .args = .{ .key = key } };
}

pub const Incr = Command("redis.cmd.incr", "INCR", i64, Key);

/// DECR `key`: the counter one down, from 0 when the key is not there.
pub fn decr(key: []const u8) Decr {
    return .{ .args = .{ .key = key } };
}

pub const Decr = Command("redis.cmd.decr", "DECR", i64, Key);

/// INCRBY `key` `by`: the counter up by `by`.
pub fn incrby(key: []const u8, by: i64) Incrby {
    return .{ .args = .{ .key = key, .by = by } };
}

pub const Incrby = Command("redis.cmd.incrby", "INCRBY", i64, By);

/// DECRBY `key` `by`: the counter down by `by`.
pub fn decrby(key: []const u8, by: i64) Decrby {
    return .{ .args = .{ .key = key, .by = by } };
}

pub const Decrby = Command("redis.cmd.decrby", "DECRBY", i64, By);

/// INCRBYFLOAT `key` `by`: the number of the key up by `by`, which the
/// server answers as a string.
pub fn incrbyfloat(key: []const u8, by: f64) Incrbyfloat {
    return .{ .args = .{ .key = key, .by = by } };
}

pub const Incrbyfloat = Command("redis.cmd.incrbyfloat", "INCRBYFLOAT", f64, struct { key: []const u8, by: f64 });
