//! The hash commands of `redis.cmd`: HSET and HGETALL of a struct, the
//! fields one by one, the counters of a hash, and one page of HSCAN.
//!
//! A hash and a struct go both ways by the names of their fields:
//! `cmd.hset(key, profile)` writes each field of `profile`, and
//! `cmd.hgetall(Profile, key)` reads them back, the fields the hash lacks
//! taking their default values, an optional null, and the fields the
//! struct lacks skipped. A field is a string, a number, a bool, an enum,
//! or an optional of one, which HSET leaves out when it is null; a hash
//! has no nesting. A hash of any fields is `[]const redis.FieldValue`.
//!
//! ```zig
//! try client.run(io, op, redis.cmd.hset("user:42", Profile{ .name = "Ann", .age = 30, .plan = .pro }), .{});
//! const profile = try client.run(io, op, redis.cmd.hgetall(Profile, "user:42"), .{ .allocator = arena }) orelse return error.NoSuchUser;
//! ```

const std = @import("std");
const resp = @import("../resp.zig");
const hash = @import("../resp/hash.zig");
const command = @import("command.zig");
const FieldValue = @import("types.zig").FieldValue;
const Diagnostics = @import("../errors.zig").Diagnostics;

const Command = command.Command;
const Key = struct { key: []const u8 };
const Field = struct { key: []const u8, field: []const u8 };
const Fields = struct { key: []const u8, fields: []const []const u8 };
const By = struct { key: []const u8, field: []const u8, by: i64 };

/// HSET `key` `field` `value`…: the fields of `fields`, a struct, or a
/// list of `redis.FieldValue` such as `&.{.{ .field = "plan", .value = "pro" }}`.
/// One field to write at least. The count of new fields that HSET
/// answers is dropped; `cmd.raw(u64, .{ "HSET", … })` keeps it.
pub fn hset(key: []const u8, fields: anytype) Hset(command.FieldsOf(@TypeOf(fields))) {
    return .{ .key = key, .fields = command.fieldsOf(fields) };
}

pub fn Hset(comptime F: type) type {
    // An array of fields is the command's own: the hash code reads it
    // through a pointer.
    const own = @typeInfo(F) == .array;
    const List = if (own) *const F else F;
    hash.checkWrite(List, "redis.cmd.hset");
    return struct {
        key: []const u8,
        fields: F,

        const Self = @This();

        pub const Reply = void;

        fn list(c: *const Self) List {
            return if (own) &c.fields else c.fields;
        }

        /// No field to write, a struct whose fields are all null among
        /// them, or a field that is NaN, is InvalidArgument.
        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return hash.check(c.list(), "redis.cmd.hset", diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            try w.arrayHeader(2 + 2 * hash.fieldCount(c.list()));
            try w.bulk("HSET");
            try w.bulk(c.key);
            try hash.write(w, c.list());
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!void {
            return resp.decode(void, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "HSET";
        }
    };
}

/// HSETNX `key` `field` `value`: true when the hash had no such field and
/// now holds `value` in it; false when it had, and keeps its own.
pub fn hsetnx(key: []const u8, field: []const u8, value: anytype) Hsetnx(command.Arg(@TypeOf(value))) {
    return .{ .args = .{ .key = key, .field = field, .value = command.arg(value) } };
}

pub fn Hsetnx(comptime V: type) type {
    command.checkArg(V, "redis.cmd.hsetnx", "value");
    return Command("redis.cmd.hsetnx", "HSETNX", bool, struct { key: []const u8, field: []const u8, value: V });
}

/// HGET `key` `field`: the value of the field read into `T`, a string or
/// a number; null when the hash, or the field, is not there.
pub fn hget(comptime T: type, key: []const u8, field: []const u8) Hget(T) {
    return .{ .args = .{ .key = key, .field = field } };
}

pub fn Hget(comptime T: type) type {
    return Command("redis.cmd.hget", "HGET", ?T, Field);
}

/// HMGET `key` `fields`: the value of each field, as `hget` reads it, in
/// their order. One field at least.
pub fn hmget(comptime T: type, key: []const u8, fields: []const []const u8) Hmget(T) {
    return .{ .args = .{ .key = key, .fields = fields } };
}

pub fn Hmget(comptime T: type) type {
    return Command("redis.cmd.hmget", "HMGET", []const ?T, Fields);
}

/// HGETALL `key`: the hash read into `T`, a struct or
/// `[]const redis.FieldValue`; null when it is not there.
pub fn hgetall(comptime T: type, key: []const u8) Hgetall(T) {
    return .{ .args = .{ .key = key } };
}

pub fn Hgetall(comptime T: type) type {
    return Command("redis.cmd.hgetall", "HGETALL", ?T, Key);
}

/// HDEL `key` `fields`: how many of the fields were there and are gone.
/// One field at least.
pub fn hdel(key: []const u8, fields: []const []const u8) Hdel {
    return .{ .args = .{ .key = key, .fields = fields } };
}

pub const Hdel = Command("redis.cmd.hdel", "HDEL", u64, Fields);

/// HEXISTS `key` `field`: whether the hash has the field.
pub fn hexists(key: []const u8, field: []const u8) Hexists {
    return .{ .args = .{ .key = key, .field = field } };
}

pub const Hexists = Command("redis.cmd.hexists", "HEXISTS", bool, Field);

/// HLEN `key`: how many fields the hash has, 0 when it is not there.
pub fn hlen(key: []const u8) Hlen {
    return .{ .args = .{ .key = key } };
}

pub const Hlen = Command("redis.cmd.hlen", "HLEN", u64, Key);

/// HINCRBY `key` `field` `by`: the counter in the field up by `by`, from
/// 0 when it is not there.
pub fn hincrby(key: []const u8, field: []const u8, by: i64) Hincrby {
    return .{ .args = .{ .key = key, .field = field, .by = by } };
}

pub const Hincrby = Command("redis.cmd.hincrby", "HINCRBY", i64, By);

/// HINCRBYFLOAT `key` `field` `by`: the number in the field up by `by`,
/// which the server answers as a string.
pub fn hincrbyfloat(key: []const u8, field: []const u8, by: f64) Hincrbyfloat {
    return .{ .args = .{ .key = key, .field = field, .by = by } };
}

pub const Hincrbyfloat = Command("redis.cmd.hincrbyfloat", "HINCRBYFLOAT", f64, struct { key: []const u8, field: []const u8, by: f64 });

/// HKEYS `key`: the names of the fields of the hash.
pub fn hkeys(key: []const u8) Hkeys {
    return .{ .args = .{ .key = key } };
}

pub const Hkeys = Command("redis.cmd.hkeys", "HKEYS", []const []const u8, Key);

/// HSCAN `key` `cursor` [MATCH p] [COUNT n]: one page of the fields of the
/// hash with their values, as `redis.ScanPage(redis.FieldValue)`, with the
/// cursor of the next.
pub fn hscan(key: []const u8, options: command.CursorOptions) Hscan {
    return .{ .key = key, .options = options };
}

pub const Hscan = command.Cursor("redis.cmd.hscan", "HSCAN", FieldValue, command.CursorOptions, true);
