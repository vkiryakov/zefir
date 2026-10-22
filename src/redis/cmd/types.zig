//! The types of the results and the arguments of the catalog, which the
//! module exports as `redis.*`. Each result type has its reading rule next
//! to it, `redisDecode`, which the decoder calls: it is internal to the
//! module, as the shape of the reply it reads is.

const std = @import("std");
const decode = @import("../resp/decode.zig");
const hash = @import("../resp/hash.zig");

const Decoder = decode.Decoder;
const Element = @import("../resp/Reader.zig").Element;
const Error = decode.Error;

/// The time to live of a key, from PTTL.
pub const Ttl = union(enum) {
    /// The key is not there: -2.
    missing,
    /// The key has no time to live: -1.
    persistent,
    /// The key expires in this time, in milliseconds on the wire.
    expires_in: std.Io.Duration,

    pub fn redisDecode(d: *Decoder, element: Element) Error!Ttl {
        const ms = try d.readNamed(i64, element, Ttl);
        return switch (ms) {
            -2 => .missing,
            -1 => .persistent,
            else => if (ms >= 0) .{ .expires_in = .fromMilliseconds(ms) } else d.mismatchText(Ttl, .{ .integer = ms }, null),
        };
    }
};

/// The type of a key, from TYPE. `other` is a type of a module, such as
/// `ReJSON-RL`, or one this release does not name, such as `vectorset`.
pub const KeyType = enum {
    none,
    string,
    list,
    set,
    zset,
    hash,
    stream,
    other,

    pub fn redisDecode(d: *Decoder, element: Element) Error!KeyType {
        switch (element) {
            .simple_string, .bulk_string => {
                var buffer: [decode.longest(@typeInfo(KeyType).@"enum".field_names)]u8 = undefined;
                const name = try d.reader.payloadPrefix(&buffer);
                if (name.len <= buffer.len) {
                    inline for (@typeInfo(KeyType).@"enum".field_names) |tag| {
                        if (std.mem.eql(u8, tag, name.bytes)) return @field(KeyType, tag);
                    }
                }
                return .other;
            },
            else => return d.mismatch(KeyType, element),
        }
    }
};

/// The end of a list: `LEFT` or `RIGHT`.
pub const End = enum { left, right };

/// How long a blocking command waits: `.forever` until a value comes, or
/// at most a duration.
pub const Block = union(enum) { forever, at_most: std.Io.Duration };

/// A bound of a range of scores: `min` is -inf and `max` +inf.
pub const ScoreBound = union(enum) { inclusive: f64, exclusive: f64, min, max };

/// `NX` (`absent`) or `XX` (`present`) of ZADD.
pub const Only = enum { absent, present };

/// `GT` (`greater`) or `LT` (`less`) of ZADD.
pub const Compare = enum { greater, less };

/// `LIMIT offset count` of a range.
pub const Limit = struct { offset: u64 = 0, count: u64 };

/// A member of a sorted set and its score.
pub fn Scored(comptime T: type) type {
    return struct {
        member: T,
        score: f64,

        /// `[member, score]`, as ZRANGE … WITHSCORES answers in RESP3.
        pub fn redisDecode(d: *Decoder, element: Element) Error!@This() {
            const pair = try d.readTuple(struct { T, f64 }, element, @This());
            return .{ .member = pair[0], .score = pair[1] };
        }

        /// A member and its score as two elements of a flat array, the
        /// score as a string, as ZSCAN answers.
        pub fn redisDecodePair(d: *Decoder, first: Element) Error!@This() {
            const member = try d.read(T, first);
            const score = try d.read(f64, try d.reader.next());
            return .{ .member = member, .score = score };
        }
    };
}

/// A value popped from a list and the key of that list, from BLPOP.
pub fn Popped(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,

        pub fn redisDecode(d: *Decoder, element: Element) Error!@This() {
            const pair = try d.readTuple(struct { []const u8, T }, element, @This());
            return .{ .key = pair[0], .value = pair[1] };
        }
    };
}

/// A field of a hash and its value: a hash of any fields, in place of a
/// struct, for `cmd.hset`, `cmd.hgetall` and the fields of `cmd.xadd`.
/// Read, the pairs keep the order of the server.
pub const FieldValue = struct {
    field: []const u8,
    value: []const u8,

    /// A field and its value as two elements of a map or a flat array.
    pub fn redisDecodePair(d: *Decoder, first: Element) Error!FieldValue {
        const field = try d.read([]const u8, first);
        const value = try d.read([]const u8, try d.reader.next());
        return .{ .field = field, .value = value };
    }
};

/// A key and its value, for MSET.
pub const KeyValue = struct { key: []const u8, value: []const u8 };

/// A page of SCAN, HSCAN, SSCAN or ZSCAN: the cursor of the next page, 0
/// at the end, and the items of this one.
pub fn ScanPage(comptime T: type) type {
    return struct {
        cursor: u64,
        items: []const T,

        /// `[cursor, items]`, the cursor a string; the items of HSCAN and
        /// ZSCAN are pairs in a flat array.
        pub fn redisDecode(d: *Decoder, element: Element) Error!@This() {
            try d.expectArray(element, 2, @This());
            d.depth += 1;
            defer d.depth -= 1;
            const cursor = try d.read(u64, try d.reader.next());
            const items_element = try d.reader.next();
            const items = if (comptime isPair(T))
                try d.readPairs(T, items_element, []const T)
            else
                try d.read([]const T, items_element);
            return .{ .cursor = cursor, .items = items };
        }
    };
}

/// Whether `T` is read from two elements of a flat array.
fn isPair(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "redisDecodePair");
}

/// The id of an entry of a stream, `<ms>-<seq>`: two numbers, without
/// memory. `{f}` prints it as the server writes it.
pub const StreamId = struct {
    ms: u64,
    seq: u64,

    /// `0-0`, before every entry: where a walk of a group's pending
    /// entries starts, and the id after which XREADGROUP reads them all.
    pub const zero: StreamId = .{ .ms = 0, .seq = 0 };

    /// The id of `text`, `<ms>-<seq>` in decimal without leading zeros, as
    /// the server writes it; InvalidStreamId for anything else.
    pub fn parse(text: []const u8) error{InvalidStreamId}!StreamId {
        const dash = std.mem.findScalar(u8, text, '-') orelse return error.InvalidStreamId;
        return .{ .ms = try number(text[0..dash]), .seq = try number(text[dash + 1 ..]) };
    }

    fn number(text: []const u8) error{InvalidStreamId}!u64 {
        if (text.len == 0 or (text[0] == '0' and text.len > 1)) return error.InvalidStreamId;
        var n: u64 = 0;
        for (text) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidStreamId;
            n = std.math.mul(u64, n, 10) catch return error.InvalidStreamId;
            n = std.math.add(u64, n, c - '0') catch return error.InvalidStreamId;
        }
        return n;
    }

    /// Writes the id as the server does, `<ms>-<seq>`: the `{f}` of
    /// `print`.
    pub fn format(id: StreamId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}-{d}", .{ id.ms, id.seq });
    }

    pub fn redisDecode(d: *Decoder, element: Element) Error!StreamId {
        switch (element) {
            .simple_string, .bulk_string => {
                // Two numbers of 20 digits and the dash.
                var buffer: [41]u8 = undefined;
                const text = try d.reader.payloadPrefix(&buffer);
                if (text.len <= buffer.len) {
                    if (parse(text.bytes)) |id| return id else |_| {}
                }
                return d.mismatchText(StreamId, element, text.len);
            },
            else => return d.mismatch(StreamId, element),
        }
    }
};

/// Where XREAD starts: `$`, after the last entry, or after an id.
pub const StreamPosition = union(enum) { latest, id: StreamId };

/// Where XREADGROUP starts: `>`, the entries new to the group, or the
/// entries of the consumer's own pending list after an id.
pub const GroupPosition = union(enum) { new, id: StreamId };

/// How XTRIM trims: `MAXLEN` or `MINID`.
pub const Trim = union(enum) { max_len: u64, min_id: StreamId };

/// An entry of a stream: its id and its fields, a struct or
/// `[]const redis.FieldValue`. `fields` is null for an entry deleted while
/// it was pending in a group, as XREADGROUP gives a consumer its own
/// pending entries (`.from = .{ .id = ... }`); XAUTOCLAIM does not claim
/// such an entry, and gives its id in `Claimed.deleted`.
pub fn Entry(comptime T: type) type {
    comptime if (!hash.isHash(T)) {
        @compileError("redis.Entry: the fields of an entry are a struct or []const redis.FieldValue; got " ++ @typeName(T));
    };
    return struct {
        id: StreamId,
        fields: ?T,

        pub fn redisDecode(d: *Decoder, element: Element) Error!@This() {
            const entry = try d.readTuple(struct { StreamId, ?T }, element, @This());
            return .{ .id = entry[0], .fields = entry[1] };
        }
    };
}

/// The summary of XPENDING: how many entries are pending, the first and
/// the last of them, and how many each consumer holds.
pub const PendingSummary = struct {
    count: u64,
    first: ?StreamId,
    last: ?StreamId,
    consumers: []const ConsumerPending,

    /// Without pending entries, the ids and the consumers are null.
    pub fn redisDecode(d: *Decoder, element: Element) Error!PendingSummary {
        const summary = try d.readTuple(struct { u64, ?StreamId, ?StreamId, ?[]const ConsumerPending }, element, PendingSummary);
        return .{ .count = summary[0], .first = summary[1], .last = summary[2], .consumers = summary[3] orelse &.{} };
    }
};

/// A consumer of the summary of XPENDING and how many entries it holds.
pub const ConsumerPending = struct {
    name: []const u8,
    count: u64,

    /// The count is a string on the wire.
    pub fn redisDecode(d: *Decoder, element: Element) Error!ConsumerPending {
        const consumer = try d.readTuple(struct { []const u8, u64 }, element, ConsumerPending);
        return .{ .name = consumer[0], .count = consumer[1] };
    }
};

/// A pending entry of XPENDING with a range: its id, the consumer that
/// holds it, the time since it was delivered last, and how many times it
/// was.
pub const Pending = struct {
    id: StreamId,
    consumer: []const u8,
    idle: std.Io.Duration,
    deliveries: u64,

    pub fn redisDecode(d: *Decoder, element: Element) Error!Pending {
        const pending = try d.readTuple(struct { StreamId, []const u8, i64, u64 }, element, Pending);
        if (pending[2] < 0) return d.mismatchText(Pending, .{ .integer = pending[2] }, null);
        return .{ .id = pending[0], .consumer = pending[1], .idle = .fromMilliseconds(pending[2]), .deliveries = pending[3] };
    }
};

/// The reply of XAUTOCLAIM: the id to start the next call from, the
/// entries claimed, and the ids of the pending entries that were deleted
/// from the stream, which XAUTOCLAIM takes off the group's pending list
/// instead of claiming them.
pub fn Claimed(comptime T: type) type {
    return struct {
        next: StreamId,
        entries: []const Entry(T),
        deleted: []const StreamId,

        pub fn redisDecode(d: *Decoder, element: Element) Error!@This() {
            const claimed = try d.readTuple(struct { StreamId, []const Entry(T), []const StreamId }, element, @This());
            return .{ .next = claimed[0], .entries = claimed[1], .deleted = claimed[2] };
        }
    };
}
