//! `redis.Value`, a reply of any shape, and its reading from a
//! `resp.Reader`: for replies that fit no Zig type of the caller's, such as
//! those of modules, `XINFO` or `CLIENT INFO`.
//!
//! - `read(reader, arena)` reads a whole reply; `readFrom(reader, first,
//!   arena)` reads the rest of one whose first element `next` returned.
//! - Its strings and slices are in `arena`, copies of what came: nothing
//!   points into the buffer of the connection, and the value lives as long
//!   as the arena.
//! - Building it takes no recursion: aggregates are filled on an explicit
//!   stack as deep as the reader lets a reply nest, `Reader.max_depth`.
//! - An aggregate of `n` elements takes `n` values in the arena as soon as
//!   its header is read; the reader has checked by then that `n` elements
//!   fit what is left of its budget.

const std = @import("std");
const Reader = @import("Reader.zig");

/// A reply of any shape, read whole. Every kind of RESP3 has its place:
/// bulk, simple and verbatim strings are strings (a verbatim string
/// without its `txt:`), and an error inside an aggregate, such as an
/// element of the reply of `EXEC` or of a Lua table, is a value of its
/// own. A push reads as an array.
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    double: f64,
    /// A big number, as its decimal text.
    big_number: []const u8,
    /// A bulk, simple or verbatim string.
    string: []const u8,
    array: []const Value,
    set: []const Value,
    /// The pairs of a map, in the order the server sent them.
    map: []const Pair,
    /// An error inside an aggregate.
    err: struct {
        /// Its first word, such as "ERR" or "WRONGTYPE".
        code: []const u8,
        /// Its whole text, the code first.
        message: []const u8,
    },

    /// A key of a map and its value.
    pub const Pair = struct {
        key: Value,
        value: Value,
    };
};

pub const ReadError = Reader.Error || std.mem.Allocator.Error;

/// Reads a whole reply from `r` into a value whose memory is in `arena`.
pub fn read(r: *Reader, arena: std.mem.Allocator) ReadError!Value {
    return readFrom(r, try r.next(), arena);
}

/// Reads the rest of a reply into a value whose memory is in `arena`:
/// `first` is the element of the reply `r.next()` returned first.
pub fn readFrom(r: *Reader, first: Reader.Element, arena: std.mem.Allocator) ReadError!Value {
    // The aggregates being filled, outermost first.
    var open: [Reader.max_depth]Aggregate = undefined;
    var depth: usize = 0;
    var element = first;
    while (true) {
        var value: Value = switch (element) {
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .double => |d| .{ .double = d },
            .simple_string, .bulk_string, .verbatim_string => .{ .string = try r.payloadAlloc(arena) },
            .big_number => .{ .big_number = try r.payloadAlloc(arena) },
            .simple_error, .bulk_error => error_value: {
                const message = try r.payloadAlloc(arena);
                const code = message[0 .. std.mem.findScalar(u8, message, ' ') orelse message.len];
                break :error_value .{ .err = .{ .code = code, .message = message } };
            },
            .array, .set, .push, .map => |n| aggregate: {
                const started = try Aggregate.start(element, n, arena);
                if (started.len == 0) break :aggregate started.finish();
                // The reader refuses a reply deeper than this before its
                // header comes back; the check keeps it so, whatever comes.
                if (depth == open.len) return error.ReplyTooLarge;
                open[depth] = started;
                depth += 1;
                element = try r.next();
                continue;
            },
        };
        // Put the value in the aggregate that holds it, and close the ones
        // it fills.
        while (depth > 0) {
            const holder = &open[depth - 1];
            holder.put(value);
            if (holder.filled < holder.len) break;
            value = holder.finish();
            depth -= 1;
        } else return value;
        element = try r.next();
    }
}

/// An aggregate of a value being read.
const Aggregate = struct {
    kind: enum { array, set, map },
    /// The elements of an array or a set.
    values: []Value = &.{},
    /// The pairs of a map.
    pairs: []Value.Pair = &.{},
    /// How many elements are in; a map counts its keys and values.
    filled: usize = 0,
    /// How many elements it holds; a map counts its keys and values.
    len: usize,

    fn start(element: Reader.Element, n: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!Aggregate {
        return switch (element) {
            .map => .{ .kind = .map, .pairs = try arena.alloc(Value.Pair, n), .len = 2 * n },
            .set => .{ .kind = .set, .values = try arena.alloc(Value, n), .len = n },
            else => .{ .kind = .array, .values = try arena.alloc(Value, n), .len = n },
        };
    }

    fn put(a: *Aggregate, value: Value) void {
        switch (a.kind) {
            .array, .set => a.values[a.filled] = value,
            .map => if (a.filled % 2 == 0) {
                a.pairs[a.filled / 2].key = value;
            } else {
                a.pairs[a.filled / 2].value = value;
            },
        }
        a.filled += 1;
    }

    fn finish(a: Aggregate) Value {
        return switch (a.kind) {
            .array => .{ .array = a.values },
            .set => .{ .set = a.values },
            .map => .{ .map = a.pairs },
        };
    }
};
