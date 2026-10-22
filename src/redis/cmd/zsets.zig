//! The sorted set commands of `redis.cmd`: members with their scores, the
//! counter of a score, ranks, ranges by rank and by score, pops of the
//! lowest and the highest, removing ranges, and one page of ZSCAN.
//!
//! A score is an `f64`, `inf` and `-inf` included; NaN is
//! InvalidArgument. A range of scores takes two `redis.ScoreBound`s, the
//! lower first: `.{ .inclusive = 10 }`, `.{ .exclusive = 10 }`, `.min` for
//! -inf and `.max` for +inf. A range reads its members into `T`; with `T`
//! a `redis.Scored(M)` it asks for WITHSCORES, and each member comes with
//! its score.
//!
//! ```zig
//! _ = try client.run(io, op, redis.cmd.zadd("leaders", &.{.{ .member = "ann", .score = 12.5 }}, .{}), .{});
//! const top = try client.run(io, op, redis.cmd.zrange(redis.Scored([]const u8), "leaders", 0, 9, .{ .rev = true }), .{ .allocator = arena });
//! ```

const std = @import("std");
const resp = @import("../resp.zig");
const command = @import("command.zig");
const types = @import("types.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const Command = command.Command;
const Scored = types.Scored;
const ScoreBound = types.ScoreBound;
const Element = resp.Reader.Element;
const Key = struct { key: []const u8 };
const Member = struct { key: []const u8, member: []const u8 };
const Bounds = struct { key: []const u8, min: ScoreBound, max: ScoreBound };

pub const ZaddOptions = struct {
    /// NX (`.absent`): only add new members; XX (`.present`): only update
    /// the members the set has.
    only: ?types.Only = null,
    /// GT (`.greater`) or LT (`.less`): update a member only to a higher,
    /// or a lower, score; not with `.only = .absent`.
    compare: ?types.Compare = null,
    /// CH: count the members whose score changed, not only the new ones.
    changed: bool = false,
};

/// ZADD `key` [NX|XX] [GT|LT] [CH] `score` `member`…: how many members
/// were added, or with `.changed` added or changed. One member at least.
pub fn zadd(key: []const u8, members: []const Scored([]const u8), options: ZaddOptions) Zadd {
    return .{ .key = key, .members = members, .options = options };
}

pub const Zadd = struct {
    key: []const u8,
    members: []const Scored([]const u8),
    options: ZaddOptions,

    const call = "redis.cmd.zadd";

    pub const Reply = u64;

    pub fn check(c: Zadd, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
        if (c.members.len == 0) return command.invalid(diagnostics, call ++ ": no members: ZADD takes one or more", .{});
        if (c.options.only) |only| if (only == .absent and c.options.compare != null) {
            return command.invalid(diagnostics, call ++ ": .only = .absent (NX) and .compare (GT or LT) together, which a server refuses: NX adds new members only, and GT and LT update those it has", .{});
        };
        for (c.members, 0..) |m, i| if (std.math.isNan(m.score)) {
            return command.invalid(diagnostics, call ++ ": members[{d}].score is NaN, which a server does not take", .{i});
        };
    }

    pub fn write(c: Zadd, w: resp.Writer) resp.Writer.Error!void {
        const o = c.options;
        const flags = @as(usize, @intFromBool(o.only != null)) + @intFromBool(o.compare != null) + @intFromBool(o.changed);
        try w.arrayHeader(2 + flags + 2 * c.members.len);
        try w.bulk("ZADD");
        try w.bulk(c.key);
        if (o.only) |only| try w.bulk(switch (only) {
            .absent => "NX",
            .present => "XX",
        });
        if (o.compare) |compare| try w.bulk(switch (compare) {
            .greater => "GT",
            .less => "LT",
        });
        if (o.changed) try w.bulk("CH");
        for (c.members) |m| {
            try resp.args.write(w, m.score);
            try w.bulk(m.member);
        }
    }

    pub fn read(_: Zadd, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!u64 {
        return resp.decode(u64, r, arena, diagnostics);
    }

    pub fn name(_: Zadd) []const u8 {
        return "ZADD";
    }
};

/// ZINCRBY `key` `by` `member`: the score of the member up by `by`, from 0
/// when the set lacks it; the new score.
pub fn zincrby(key: []const u8, by: f64, member: []const u8) Zincrby {
    return .{ .args = .{ .key = key, .by = by, .member = member } };
}

pub const Zincrby = Command("redis.cmd.zincrby", "ZINCRBY", f64, struct { key: []const u8, by: f64, member: []const u8 });

/// ZSCORE `key` `member`: the score of the member; null when the set, or
/// the member, is not there.
pub fn zscore(key: []const u8, member: []const u8) Zscore {
    return .{ .args = .{ .key = key, .member = member } };
}

pub const Zscore = Command("redis.cmd.zscore", "ZSCORE", ?f64, Member);

/// ZRANK `key` `member`: the rank of the member from the lowest score, 0
/// first; null when the set, or the member, is not there.
pub fn zrank(key: []const u8, member: []const u8) Zrank {
    return .{ .args = .{ .key = key, .member = member } };
}

pub const Zrank = Command("redis.cmd.zrank", "ZRANK", ?u64, Member);

/// ZREVRANK `key` `member`: the rank of the member from the highest score,
/// as `zrank` reads it.
pub fn zrevrank(key: []const u8, member: []const u8) Zrevrank {
    return .{ .args = .{ .key = key, .member = member } };
}

pub const Zrevrank = Command("redis.cmd.zrevrank", "ZREVRANK", ?u64, Member);

/// ZREM `key` `members`: how many of them were in the set and are gone.
/// One member at least.
pub fn zrem(key: []const u8, members: []const []const u8) Zrem {
    return .{ .args = .{ .key = key, .members = members } };
}

pub const Zrem = Command("redis.cmd.zrem", "ZREM", u64, struct { key: []const u8, members: []const []const u8 });

/// ZCARD `key`: how many members the set has, 0 when it is not there.
pub fn zcard(key: []const u8) Zcard {
    return .{ .args = .{ .key = key } };
}

pub const Zcard = Command("redis.cmd.zcard", "ZCARD", u64, Key);

/// ZCOUNT `key` `min` `max`: how many members have a score within the
/// bounds.
pub fn zcount(key: []const u8, min: ScoreBound, max: ScoreBound) Zcount {
    return .{ .args = .{ .key = key, .min = min, .max = max } };
}

pub const Zcount = Command("redis.cmd.zcount", "ZCOUNT", u64, Bounds);

pub const ZrangeOptions = struct {
    /// REV: the ranks count from the highest score.
    rev: bool = false,
};

/// ZRANGE `key` `start` `stop` [REV] [WITHSCORES]: the members from rank
/// `start` to rank `stop`, both included, read into `T`; `0, -1` is the
/// whole set. With `T` a `redis.Scored(M)`, each with its score.
pub fn zrange(comptime T: type, key: []const u8, start: i64, stop: i64, options: ZrangeOptions) Zrange(T) {
    return .{ .key = key, .start = start, .stop = stop, .options = options };
}

pub fn Zrange(comptime T: type) type {
    const R = []const T;
    comptime resp.checkReply(R, "redis.cmd.zrange");
    return struct {
        key: []const u8,
        start: i64,
        stop: i64,
        options: ZrangeOptions,

        const Self = @This();

        pub const Reply = R;

        pub fn check(_: Self, _: ?*Diagnostics) error{InvalidArgument}!void {}

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            try w.arrayHeader(4 + @as(usize, @intFromBool(c.options.rev)) + @intFromBool(comptime isScored(T)));
            try w.bulk("ZRANGE");
            try w.bulk(c.key);
            try resp.args.write(w, c.start);
            try resp.args.write(w, c.stop);
            if (c.options.rev) try w.bulk("REV");
            if (comptime isScored(T)) try w.bulk("WITHSCORES");
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "ZRANGE";
        }
    };
}

pub const ZrangeByScoreOptions = struct {
    /// REV: from the highest score down; the bounds stay the lower first.
    rev: bool = false,
    /// LIMIT `offset` `count`: skip `offset` members, then take `count`.
    limit: ?types.Limit = null,
};

/// ZRANGE `key` `min` `max` BYSCORE [REV] [LIMIT o n] [WITHSCORES]: the
/// members with a score within the bounds, read into `T` as `zrange`
/// reads them. With `.rev`, the client puts the bounds in the order REV
/// takes them, `max` first.
pub fn zrangeByScore(comptime T: type, key: []const u8, min: ScoreBound, max: ScoreBound, options: ZrangeByScoreOptions) ZrangeByScore(T) {
    return .{ .key = key, .min = min, .max = max, .options = options };
}

pub fn ZrangeByScore(comptime T: type) type {
    const call = "redis.cmd.zrangeByScore";
    const R = []const T;
    comptime resp.checkReply(R, call);
    return struct {
        key: []const u8,
        min: ScoreBound,
        max: ScoreBound,
        options: ZrangeByScoreOptions,

        const Self = @This();

        pub const Reply = R;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return command.checkFields(.{ .min = c.min, .max = c.max }, call, "ZRANGE", diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            const o = c.options;
            const limit: usize = if (o.limit == null) 0 else 3;
            try w.arrayHeader(5 + @as(usize, @intFromBool(o.rev)) + limit + @intFromBool(comptime isScored(T)));
            try w.bulk("ZRANGE");
            try w.bulk(c.key);
            try command.writeBound(w, if (o.rev) c.max else c.min);
            try command.writeBound(w, if (o.rev) c.min else c.max);
            try w.bulk("BYSCORE");
            if (o.rev) try w.bulk("REV");
            if (o.limit) |l| {
                try w.bulk("LIMIT");
                try resp.args.write(w, l.offset);
                try resp.args.write(w, l.count);
            }
            if (comptime isScored(T)) try w.bulk("WITHSCORES");
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return "ZRANGE";
        }
    };
}

/// Whether `T` is a `redis.Scored(M)`: a range of it asks for WITHSCORES.
fn isScored(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    return info.field_names.len == 2 and std.mem.eql(u8, info.field_names[0], "member") and T == Scored(info.field_types[0]);
}

/// ZPOPMIN `key`: the member of the lowest score, read into `T` with its
/// score, taken out of the set; null when the set is empty.
pub fn zpopmin(comptime T: type, key: []const u8) Zpopmin(T) {
    return .{ .key = key };
}

pub fn Zpopmin(comptime T: type) type {
    return Pop(T, "redis.cmd.zpopmin", "ZPOPMIN");
}

/// ZPOPMAX `key`: the member of the highest score, as `zpopmin` takes it.
pub fn zpopmax(comptime T: type, key: []const u8) Zpopmax(T) {
    return .{ .key = key };
}

pub fn Zpopmax(comptime T: type) type {
    return Pop(T, "redis.cmd.zpopmax", "ZPOPMAX");
}

fn Pop(comptime T: type, comptime call: []const u8, comptime word: []const u8) type {
    const R = ?Scored(T);
    comptime resp.checkReply(R, call);
    return struct {
        key: []const u8,

        const Self = @This();

        pub const Reply = R;

        pub fn check(_: Self, _: ?*Diagnostics) error{InvalidArgument}!void {}

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            try w.command(&.{ word, c.key });
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return (try resp.decode(Popped(T), r, arena, diagnostics)).scored;
        }

        pub fn name(_: Self) []const u8 {
            return word;
        }
    };
}

/// The reply of ZPOPMIN and ZPOPMAX: `[member, score]`, or an empty array
/// for an empty set.
fn Popped(comptime T: type) type {
    return struct {
        scored: ?Scored(T),

        pub fn redisDecode(d: *resp.Decoder, element: Element) resp.DecodeError!@This() {
            switch (element) {
                .null => return .{ .scored = null },
                .array => |n| if (n == 0) return .{ .scored = null },
                else => {},
            }
            return .{ .scored = try d.read(Scored(T), element) };
        }
    };
}

/// ZREMRANGEBYSCORE `key` `min` `max`: removes the members with a score
/// within the bounds; how many it removed.
pub fn zremrangebyscore(key: []const u8, min: ScoreBound, max: ScoreBound) Zremrangebyscore {
    return .{ .args = .{ .key = key, .min = min, .max = max } };
}

pub const Zremrangebyscore = Command("redis.cmd.zremrangebyscore", "ZREMRANGEBYSCORE", u64, Bounds);

/// ZREMRANGEBYRANK `key` `start` `stop`: removes the members from rank
/// `start` to rank `stop`, both included, from the lowest score; how many
/// it removed. `0, -11` keeps the 10 of the highest scores.
pub fn zremrangebyrank(key: []const u8, start: i64, stop: i64) Zremrangebyrank {
    return .{ .args = .{ .key = key, .start = start, .stop = stop } };
}

pub const Zremrangebyrank = Command("redis.cmd.zremrangebyrank", "ZREMRANGEBYRANK", u64, struct { key: []const u8, start: i64, stop: i64 });

/// ZSCAN `key` `cursor` [MATCH p] [COUNT n]: one page of the members of the
/// set with their scores, as `redis.ScanPage(redis.Scored([]const u8))`,
/// with the cursor of the next.
pub fn zscan(key: []const u8, options: command.CursorOptions) Zscan {
    return .{ .key = key, .options = options };
}

pub const Zscan = command.Cursor("redis.cmd.zscan", "ZSCAN", Scored([]const u8), command.CursorOptions, true);
