//! The stream commands of `redis.cmd`: XADD of an entry, the length, the
//! ranges, XREAD and XREADGROUP of one stream, the groups and the entries
//! their consumers hold pending, XAUTOCLAIM, XDEL and XTRIM.
//!
//! The fields of an entry are a struct, as those of a hash (`cmd.hset`),
//! or a list of `redis.FieldValue`: `xadd` adds it, making the stream when
//! it is not there, and `xaddNoMkstream` only to a stream that is there,
//! null otherwise. An entry read back is a `redis.Entry(T)`, its id and
//! its fields read into `T`. `fields` is null for an entry deleted while
//! it was pending in a group, when XREADGROUP gives a consumer its own
//! pending entries again; XAUTOCLAIM does not claim such an entry, and
//! gives its id in `deleted`.
//!
//! XREAD and XREADGROUP read one stream, and no entry is an empty slice;
//! several streams at once go through `cmd.raw`. With `.block` they wait
//! on the server, blocking commands whose timeout goes in milliseconds:
//! under a deadline the server gets what it leaves beyond 150 ms, so that
//! a quiet stream ends the call with an empty slice before the deadline.
//!
//! A group remembers what each consumer took until XACK: an entry that its
//! consumer never acknowledged stays pending, for XPENDING to show and for
//! XAUTOCLAIM to hand to another consumer.
//!
//! ```zig
//! _ = try client.run(io, op, redis.cmd.xadd("orders", Order{ .id = 7, .total = 12.5 }, .{}), .{});
//! const orders = try client.run(io, op, redis.cmd.xreadgroup(Order, "orders", .{ .group = "billing", .consumer = "worker-1", .block = .{ .at_most = .fromSeconds(5) } }), .{ .allocator = arena });
//! ```

const std = @import("std");
const Io = std.Io;
const resp = @import("../resp.zig");
const hash = @import("../resp/hash.zig");
const command = @import("command.zig");
const contract = @import("contract.zig");
const types = @import("types.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const Command = command.Command;
const StreamId = types.StreamId;
const Entry = types.Entry;
const Block = types.Block;
const Element = resp.Reader.Element;
const Key = struct { key: []const u8 };
const Group = struct { key: []const u8, group: []const u8 };

/// The options of `xadd` and `xaddNoMkstream`.
pub const XaddOptions = struct {
    /// The id of the entry; null: `*`, the next one the server gives.
    id: ?StreamId = null,
    /// MAXLEN: the stream keeps about this many entries, the oldest go.
    max_len: ?u64 = null,
    /// `~` of MAXLEN: whole nodes only, which is cheaper; the stream may
    /// keep some more entries.
    approximate: bool = true,
};

/// XADD `key` [MAXLEN [~] n] `id`|* `field` `value`…: adds an entry of
/// `fields`, a struct or a list of `redis.FieldValue`, and returns its id.
/// One field at least. A stream that is not there is made for it.
pub fn xadd(key: []const u8, fields: anytype, options: XaddOptions) Xadd(command.FieldsOf(@TypeOf(fields))) {
    return .{ .key = key, .fields = command.fieldsOf(fields), .options = options };
}

pub fn Xadd(comptime F: type) type {
    return Add(F, "redis.cmd.xadd", .make);
}

/// XADD `key` NOMKSTREAM [MAXLEN [~] n] `id`|* `field` `value`…: adds an
/// entry of `fields` as `xadd` does, but only to a stream that is there:
/// its id, or null when there is no such stream and nothing was added.
pub fn xaddNoMkstream(key: []const u8, fields: anytype, options: XaddOptions) XaddNoMkstream(command.FieldsOf(@TypeOf(fields))) {
    return .{ .key = key, .fields = command.fieldsOf(fields), .options = options };
}

pub fn XaddNoMkstream(comptime F: type) type {
    return Add(F, "redis.cmd.xaddNoMkstream", .keep);
}

/// What XADD does with a stream that is not there.
const Missing = enum {
    /// It makes the stream: the reply is the id.
    make,
    /// NOMKSTREAM: it adds nothing, and the reply is null.
    keep,
};

fn Add(comptime F: type, comptime call: []const u8, comptime missing: Missing) type {
    // An array of fields is the command's own: the hash code reads it
    // through a pointer.
    const own = @typeInfo(F) == .array;
    const List = if (own) *const F else F;
    hash.checkWrite(List, call);
    const R = switch (missing) {
        .make => StreamId,
        .keep => ?StreamId,
    };
    return struct {
        key: []const u8,
        fields: F,
        options: XaddOptions,

        const Self = @This();

        pub const Reply = R;

        fn list(c: *const Self) List {
            return if (own) &c.fields else c.fields;
        }

        /// No field to write, or a field that is NaN, is InvalidArgument.
        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return hash.check(c.list(), call, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const o = c.options;
            var n: usize = 3 + 2 * hash.fieldCount(c.list()) + @intFromBool(missing == .keep);
            if (o.max_len != null) n += 2 + @as(usize, @intFromBool(o.approximate));
            try w.arrayHeader(n);
            try w.bulk("XADD");
            try w.bulk(c.key);
            if (missing == .keep) try w.bulk("NOMKSTREAM");
            if (o.max_len) |max| {
                try w.bulk("MAXLEN");
                if (o.approximate) try w.bulk("~");
                try resp.args.write(w, max);
            }
            if (o.id) |id| try command.writeId(w, id) else try w.bulk("*");
            try hash.write(w, c.list());
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "XADD";
        }
    };
}

/// XLEN `key`: how many entries the stream has, 0 when it is not there.
pub fn xlen(key: []const u8) Xlen {
    return .{ .args = .{ .key = key } };
}

pub const Xlen = Command("redis.cmd.xlen", "XLEN", u64, Key);

pub const XrangeOptions = struct {
    /// The first id of the range; null: `-`, the first of the stream.
    start: ?StreamId = null,
    /// The last id of the range, included; null: `+`, the last.
    end: ?StreamId = null,
    /// COUNT: at most this many entries.
    count: ?u64 = null,
};

/// XRANGE `key` `start`|- `end`|+ [COUNT n]: the entries from `start` to
/// `end`, both included, the oldest first, read into `T`.
pub fn xrange(comptime T: type, key: []const u8, options: XrangeOptions) Xrange(T) {
    return .{ .key = key, .options = options };
}

pub fn Xrange(comptime T: type) type {
    return Range(T, "redis.cmd.xrange", false);
}

/// XREVRANGE `key` `end`|+ `start`|- [COUNT n]: the entries of the range,
/// the newest first, as `xrange` reads them.
pub fn xrevrange(comptime T: type, key: []const u8, options: XrangeOptions) Xrevrange(T) {
    return .{ .key = key, .options = options };
}

pub fn Xrevrange(comptime T: type) type {
    return Range(T, "redis.cmd.xrevrange", true);
}

fn Range(comptime T: type, comptime call: []const u8, comptime reverse: bool) type {
    const R = []const Entry(T);
    comptime resp.checkReply(R, call);
    const word = if (reverse) "XREVRANGE" else "XRANGE";
    return struct {
        key: []const u8,
        options: XrangeOptions,

        const Self = @This();

        pub const Reply = R;

        pub fn check(_: Self, _: ?*Diagnostics) error{InvalidArgument}!void {}

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const o = c.options;
            try w.arrayHeader(@as(usize, 4) + if (o.count == null) @as(usize, 0) else 2);
            try w.bulk(word);
            try w.bulk(c.key);
            try writeEdge(w, if (reverse) o.end else o.start, if (reverse) "+" else "-");
            try writeEdge(w, if (reverse) o.start else o.end, if (reverse) "-" else "+");
            try writeCount(w, o.count);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return word;
        }
    };
}

/// An edge of a range: its id, or `open`, `-` or `+`, without one.
fn writeEdge(w: resp.Writer, id: ?StreamId, open: []const u8) resp.Writer.Error!void {
    if (id) |edge| try command.writeId(w, edge) else try w.bulk(open);
}

fn writeCount(w: resp.Writer, count: ?u64) resp.Writer.Error!void {
    if (count) |n| {
        try w.bulk("COUNT");
        try resp.args.write(w, n);
    }
}

fn writeBlock(w: resp.Writer, timeout_ms: ?u64) resp.Writer.Error!void {
    if (timeout_ms) |ms| {
        try w.bulk("BLOCK");
        try contract.writeTimeout(w, .milliseconds, ms);
    }
}

pub const XreadOptions = struct {
    /// Where to read: after an id, the last one read; or `.latest`, `$`,
    /// the entries added from now on, which makes sense with `.block`.
    after: types.StreamPosition,
    /// COUNT: at most this many entries.
    count: ?u64 = null,
    /// BLOCK: how long to wait when no entry is there; null: no wait.
    block: ?Block = null,
};

/// XREAD [COUNT n] [BLOCK ms] STREAMS `key` `id`|$: the entries of the
/// stream after the position, read into `T`; none is an empty slice.
pub fn xread(comptime T: type, key: []const u8, options: XreadOptions) Xread(T) {
    return .{ .key = key, .options = options };
}

pub fn Xread(comptime T: type) type {
    const call = "redis.cmd.xread";
    const R = []const Entry(T);
    comptime resp.checkReply(R, call);
    return struct {
        key: []const u8,
        options: XreadOptions,

        const Self = @This();

        pub const Reply = R;

        pub const blocking: contract.Blocking = .{ .unit = .milliseconds, .instead = "redis.cmd.xread without .block" };

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            if (c.options.block) |block| return contract.checkBlock(block, call, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return c.send(w, if (c.options.block) |block| contract.given(block) else null);
        }

        pub fn writeWith(c: Self, w: resp.Writer, timeout_ms: u64) resp.Writer.Error!void {
            return c.send(w, timeout_ms);
        }

        fn send(c: Self, w: resp.Writer, timeout_ms: ?u64) resp.Writer.Error!void {
            const o = c.options;
            var n: usize = 4;
            if (o.count != null) n += 2;
            if (timeout_ms != null) n += 2;
            try w.arrayHeader(n);
            try w.bulk("XREAD");
            try writeCount(w, o.count);
            try writeBlock(w, timeout_ms);
            try w.bulk("STREAMS");
            try w.bulk(c.key);
            switch (o.after) {
                .latest => try w.bulk("$"),
                .id => |id| try command.writeId(w, id),
            }
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return (try resp.decode(Streams(T), r, arena, diagnostics)).entries;
        }

        pub fn name(_: Self) []const u8 {
            return "XREAD";
        }

        pub fn timeout(c: Self) ?Block {
            return c.options.block;
        }
    };
}

pub const XreadgroupOptions = struct {
    /// The group, which `xgroupCreate` made.
    group: []const u8,
    /// The consumer of the group that reads: the server knows it from its
    /// first read on.
    consumer: []const u8,
    /// `.new`, `>`: the entries that the group has not given out yet;
    /// `.{ .id = … }`: the consumer's own pending entries after that id,
    /// `.zero` for all of them.
    from: types.GroupPosition = .new,
    /// COUNT: at most this many entries.
    count: ?u64 = null,
    /// BLOCK: how long to wait when no entry is there; null: no wait.
    block: ?Block = null,
    /// NOACK: the entries need no XACK and never go pending.
    no_ack: bool = false,
};

/// XREADGROUP GROUP `group` `consumer` [COUNT n] [BLOCK ms] [NOACK]
/// STREAMS `key` >|`id`: the entries of the stream for the consumer, read
/// into `T`; none is an empty slice. They stay pending in the group until
/// `xack`.
pub fn xreadgroup(comptime T: type, key: []const u8, options: XreadgroupOptions) Xreadgroup(T) {
    return .{ .key = key, .options = options };
}

pub fn Xreadgroup(comptime T: type) type {
    const call = "redis.cmd.xreadgroup";
    const R = []const Entry(T);
    comptime resp.checkReply(R, call);
    return struct {
        key: []const u8,
        options: XreadgroupOptions,

        const Self = @This();

        pub const Reply = R;

        pub const blocking: contract.Blocking = .{ .unit = .milliseconds, .instead = "redis.cmd.xreadgroup without .block" };

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            if (c.options.block) |block| return contract.checkBlock(block, call, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return c.send(w, if (c.options.block) |block| contract.given(block) else null);
        }

        pub fn writeWith(c: Self, w: resp.Writer, timeout_ms: u64) resp.Writer.Error!void {
            return c.send(w, timeout_ms);
        }

        fn send(c: Self, w: resp.Writer, timeout_ms: ?u64) resp.Writer.Error!void {
            const o = c.options;
            var n: usize = 7 + @as(usize, @intFromBool(o.no_ack));
            if (o.count != null) n += 2;
            if (timeout_ms != null) n += 2;
            try w.arrayHeader(n);
            try w.bulk("XREADGROUP");
            try w.bulk("GROUP");
            try w.bulk(o.group);
            try w.bulk(o.consumer);
            try writeCount(w, o.count);
            try writeBlock(w, timeout_ms);
            if (o.no_ack) try w.bulk("NOACK");
            try w.bulk("STREAMS");
            try w.bulk(c.key);
            switch (o.from) {
                .new => try w.bulk(">"),
                .id => |id| try command.writeId(w, id),
            }
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return (try resp.decode(Streams(T), r, arena, diagnostics)).entries;
        }

        pub fn name(_: Self) []const u8 {
            return "XREADGROUP";
        }

        pub fn timeout(c: Self) ?Block {
            return c.options.block;
        }
    };
}

/// The reply of XREAD and XREADGROUP of one stream: a map of the name of
/// the stream to its entries, or null when none came.
fn Streams(comptime T: type) type {
    return struct {
        entries: []const Entry(T),

        pub fn redisDecode(d: *resp.Decoder, element: Element) resp.DecodeError!@This() {
            switch (element) {
                .null => return .{ .entries = &.{} },
                .map => |n| if (n == 1) {
                    d.depth += 1;
                    defer d.depth -= 1;
                    // The name of the stream, which the call named.
                    try d.read(void, try d.reader.next());
                    return .{ .entries = try d.read([]const Entry(T), try d.reader.next()) };
                },
                else => {},
            }
            return d.mismatch([]const Entry(T), element);
        }
    };
}

/// XACK `key` `group` `ids`…: the entries are done with, and leave the
/// pending entries of the group; how many of them were pending. One id at
/// least.
pub fn xack(key: []const u8, group: []const u8, ids: []const StreamId) Xack {
    return .{ .args = .{ .key = key, .group = group, .ids = ids } };
}

pub const Xack = Command("redis.cmd.xack", "XACK", u64, struct { key: []const u8, group: []const u8, ids: []const StreamId });

pub const XgroupCreateOptions = struct {
    /// Where the group starts: `.latest`, `$`, the entries added from now
    /// on; `.{ .id = .zero }` for all the stream holds.
    start: types.StreamPosition = .latest,
    /// MKSTREAM: an empty stream is made when it is not there.
    mkstream: bool = false,
};

/// XGROUP CREATE `key` `group` $|`id` [MKSTREAM]: makes the group of the
/// stream. A group of that name that is there already is a ServerError
/// whose code is BUSYGROUP: `diagnostics.isCode("BUSYGROUP")`.
pub fn xgroupCreate(key: []const u8, group: []const u8, options: XgroupCreateOptions) XgroupCreate {
    return .{ .key = key, .group = group, .options = options };
}

pub const XgroupCreate = struct {
    key: []const u8,
    group: []const u8,
    options: XgroupCreateOptions,

    pub const Reply = void;

    pub fn check(_: XgroupCreate, _: ?*Diagnostics) error{InvalidArgument}!void {}

    pub fn write(c: XgroupCreate, w: resp.Writer) resp.Writer.Error!void {
        try w.arrayHeader(5 + @as(usize, @intFromBool(c.options.mkstream)));
        try w.bulk("XGROUP");
        try w.bulk("CREATE");
        try w.bulk(c.key);
        try w.bulk(c.group);
        switch (c.options.start) {
            .latest => try w.bulk("$"),
            .id => |id| try command.writeId(w, id),
        }
        if (c.options.mkstream) try w.bulk("MKSTREAM");
    }

    pub fn read(_: XgroupCreate, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!void {
        return resp.decode(void, r, arena, diagnostics);
    }

    pub fn name(_: XgroupCreate) []const u8 {
        return "XGROUP";
    }
};

/// XPENDING `key` `group`: how many entries of the group are pending, the
/// first and the last of them, and how many each consumer holds.
pub fn xpending(key: []const u8, group: []const u8) Xpending {
    return .{ .args = .{ .key = key, .group = group } };
}

pub const Xpending = Command("redis.cmd.xpending", "XPENDING", types.PendingSummary, Group);

pub const XpendingRangeOptions = struct {
    /// At most this many entries.
    count: u64,
    /// The first id of the range; null: `-`.
    start: ?StreamId = null,
    /// The last id of the range, included; null: `+`.
    end: ?StreamId = null,
    /// Only the entries of this consumer.
    consumer: ?[]const u8 = null,
    /// IDLE: only the entries given out at least this long ago, 1 ms or
    /// more.
    min_idle: ?Io.Duration = null,
};

/// XPENDING `key` `group` [IDLE ms] `start`|- `end`|+ `count` [consumer]:
/// the pending entries of the group, each with its consumer, the time
/// since it was given out and how many times it was.
pub fn xpendingRange(key: []const u8, group: []const u8, options: XpendingRangeOptions) XpendingRange {
    return .{ .key = key, .group = group, .options = options };
}

pub const XpendingRange = struct {
    key: []const u8,
    group: []const u8,
    options: XpendingRangeOptions,

    const call = "redis.cmd.xpendingRange";

    pub const Reply = []const types.Pending;

    pub fn check(c: XpendingRange, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
        if (c.options.min_idle) |idle| _ = try command.millis(idle, call, ".min_idle", diagnostics);
    }

    pub fn write(c: XpendingRange, w: resp.Writer) resp.Writer.Error!void {
        const o = c.options;
        var n: usize = 6 + @as(usize, @intFromBool(o.consumer != null));
        if (o.min_idle != null) n += 2;
        try w.arrayHeader(n);
        try w.bulk("XPENDING");
        try w.bulk(c.key);
        try w.bulk(c.group);
        if (o.min_idle) |idle| {
            try w.bulk("IDLE");
            try command.writeMillis(w, idle);
        }
        try writeEdge(w, o.start, "-");
        try writeEdge(w, o.end, "+");
        try resp.args.write(w, o.count);
        if (o.consumer) |consumer| try w.bulk(consumer);
    }

    pub fn read(_: XpendingRange, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!Reply {
        return resp.decode(Reply, r, arena, diagnostics);
    }

    pub fn name(_: XpendingRange) []const u8 {
        return "XPENDING";
    }
};

pub const XautoclaimOptions = struct {
    /// The group.
    group: []const u8,
    /// The consumer that takes the entries.
    consumer: []const u8,
    /// Only the entries pending at least this long, 1 ms or more.
    min_idle: Io.Duration,
    /// Where the walk of the pending entries starts: `.zero`, then the
    /// `next` of the reply before, until it is `.zero` again.
    start: StreamId = .zero,
    /// COUNT: at most this many entries, 100 when null.
    count: ?u64 = null,
};

/// XAUTOCLAIM `key` `group` `consumer` `ms` `start` [COUNT n]: hands the
/// entries pending longer than `.min_idle` to `.consumer`, read into `T`;
/// the id to go on from, and the ids of the pending entries that were
/// deleted, which leave the group.
pub fn xautoclaim(comptime T: type, key: []const u8, options: XautoclaimOptions) Xautoclaim(T) {
    return .{ .key = key, .options = options };
}

pub fn Xautoclaim(comptime T: type) type {
    const call = "redis.cmd.xautoclaim";
    const R = types.Claimed(T);
    comptime resp.checkReply(R, call);
    return struct {
        key: []const u8,
        options: XautoclaimOptions,

        const Self = @This();

        pub const Reply = R;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            _ = try command.millis(c.options.min_idle, call, ".min_idle", diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const o = c.options;
            try w.arrayHeader(@as(usize, 6) + if (o.count == null) @as(usize, 0) else 2);
            try w.bulk("XAUTOCLAIM");
            try w.bulk(c.key);
            try w.bulk(o.group);
            try w.bulk(o.consumer);
            try command.writeMillis(w, o.min_idle);
            try command.writeId(w, o.start);
            try writeCount(w, o.count);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "XAUTOCLAIM";
        }
    };
}

/// XDEL `key` `ids`…: removes the entries; how many of them were there.
/// One id at least.
pub fn xdel(key: []const u8, ids: []const StreamId) Xdel {
    return .{ .args = .{ .key = key, .ids = ids } };
}

pub const Xdel = Command("redis.cmd.xdel", "XDEL", u64, struct { key: []const u8, ids: []const StreamId });

pub const XtrimOptions = struct {
    /// `~`: whole nodes only, which is cheaper; the stream may keep some
    /// more entries.
    approximate: bool = true,
};

/// XTRIM `key` MAXLEN|MINID [~] `n`|`id`: removes the oldest entries,
/// those beyond the count of `.max_len` or before the id of `.min_id`;
/// how many it removed.
pub fn xtrim(key: []const u8, by: types.Trim, options: XtrimOptions) Xtrim {
    return .{ .key = key, .by = by, .options = options };
}

pub const Xtrim = struct {
    key: []const u8,
    by: types.Trim,
    options: XtrimOptions,

    pub const Reply = u64;

    pub fn check(_: Xtrim, _: ?*Diagnostics) error{InvalidArgument}!void {}

    pub fn write(c: Xtrim, w: resp.Writer) resp.Writer.Error!void {
        try w.arrayHeader(4 + @as(usize, @intFromBool(c.options.approximate)));
        try w.bulk("XTRIM");
        try w.bulk(c.key);
        try w.bulk(switch (c.by) {
            .max_len => "MAXLEN",
            .min_id => "MINID",
        });
        if (c.options.approximate) try w.bulk("~");
        switch (c.by) {
            .max_len => |n| try resp.args.write(w, n),
            .min_id => |id| try command.writeId(w, id),
        }
    }

    pub fn read(_: Xtrim, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!u64 {
        return resp.decode(u64, r, arena, diagnostics);
    }

    pub fn name(_: Xtrim) []const u8 {
        return "XTRIM";
    }
};
