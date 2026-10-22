//! What the commands of the catalog share, internal to the module. Most
//! of them are a word and then arguments of a few kinds in a fixed order,
//! with a reply read into a fixed type: `Command` makes such a type from
//! the struct of its arguments, `Blocking` one whose timeout in seconds
//! goes last, `Cursor` a page of a scan, and `Paged` a page of one as the
//! iterator of `client.iterate` sends it. The commands that write
//! themselves follow the same rules for their arguments, through the
//! functions below.
//!
//! The fields of the struct of arguments go out in their order:
//!
//! | Type of the field         | On the wire                              | Refused before sending           |
//! |---------------------------|------------------------------------------|----------------------------------|
//! | `[]const u8`              | as it is, any byte included              |                                  |
//! | `[]const []const u8`      | one argument per string                  | an empty list                    |
//! | `[]const redis.KeyValue`  | each key, then its value                 | an empty list                    |
//! | a tuple of values         | its values, by the rules of `resp.args`  | no value at all; NaN             |
//! | `std.Io.Duration`         | its milliseconds, rounded down           | under 1 ms; over maxInt(i64) ms  |
//! | `redis.End`               | `LEFT` or `RIGHT`                        |                                  |
//! | `redis.ScoreBound`        | the score, `(` and the score, `-inf`, `+inf` | NaN                          |
//! | `redis.StreamId`          | `<ms>-<seq>`                             |                                  |
//! | `[]const redis.StreamId`  | one argument per id                      | an empty list                    |
//! | any other value           | by the rules of `resp.args`              | NaN                              |
//!
//! A refusal names the function of `cmd` and the field, never a value:
//! "redis.cmd.del: no keys: DEL takes one or more".
//!
//! - `Arg(V)` and `arg(v)` — a value of the caller's as a command keeps
//!   it: a string as `[]const u8`, a number literal as `i64` or `f64`, an
//!   enum literal as the name of its tag. `checkArg` stops the build for
//!   a type that no argument is.
//! - `Values(V, call, what)` and `values(v, call, what)` — the values of
//!   LPUSH and RPUSH and the arguments of scripts: a slice of strings, or
//!   a tuple of values.
//! - `millis` and `writeMillis` — a duration as milliseconds.
//! - `writeBound` — a bound of a range of scores; `writeId` — the id of
//!   an entry of a stream.
//! - `FieldsOf(F)` and `fieldsOf(f)` — the fields of HSET and XADD: a
//!   struct, or a list of `redis.FieldValue`.

const std = @import("std");
const Io = std.Io;
const resp = @import("../resp.zig");
const types = @import("types.zig");
const contract = @import("contract.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const args = resp.args;
const Block = types.Block;
const End = types.End;
const KeyValue = types.KeyValue;
const ScoreBound = types.ScoreBound;
const StreamId = types.StreamId;
const FieldValue = types.FieldValue;

/// The type of a command that is `word` and then the fields of `Args` in
/// their order, by the table above, and whose reply reads into `R`.
/// `call` names its function, such as "redis.cmd.del", in the messages.
pub fn Command(comptime call: []const u8, comptime word: []const u8, comptime R: type, comptime Args: type) type {
    comptime resp.checkReply(R, call);
    return struct {
        args: Args,

        pub const Reply = R;

        pub fn check(c: @This(), diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return checkFields(c.args, call, word, diagnostics);
        }

        pub fn write(c: @This(), w: resp.Writer) resp.Writer.Error!void {
            try w.arrayHeader(1 + countFields(c.args));
            try w.bulk(word);
            try writeFields(w, c.args);
        }

        pub fn read(_: @This(), r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: @This()) []const u8 {
            return word;
        }
    };
}

/// The type of a blocking command whose timeout goes last, in seconds:
/// `word`, the fields of `Args`, then the timeout, as BLPOP, BRPOP and
/// BLMOVE. It carries the mark of the contract, so under a deadline the
/// client takes the timeout from what is left of it; `instead` names what
/// waits less, for the text of DeadlineExceeded when too little is left.
pub fn Blocking(comptime call: []const u8, comptime word: []const u8, comptime R: type, comptime Args: type, comptime instead: []const u8) type {
    comptime resp.checkReply(R, call);
    return struct {
        args: Args,
        wait: Block,

        const Self = @This();

        pub const Reply = R;

        pub const blocking: contract.Blocking = .{ .unit = .seconds, .instead = instead };

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            try checkFields(c.args, call, word, diagnostics);
            return contract.checkBlock(c.wait, call, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return c.writeWith(w, contract.given(c.wait));
        }

        pub fn writeWith(c: Self, w: resp.Writer, timeout_ms: u64) resp.Writer.Error!void {
            try w.arrayHeader(2 + countFields(c.args));
            try w.bulk(word);
            try writeFields(w, c.args);
            try contract.writeTimeout(w, .seconds, timeout_ms);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return word;
        }

        pub fn timeout(c: Self) Block {
            return c.wait;
        }
    };
}

/// What HSCAN, SSCAN and ZSCAN take besides the key: where the page
/// starts, and which items it returns.
pub const CursorOptions = struct {
    /// The cursor of the page: 0 for the first, then the cursor that the
    /// page before returned, until it returns 0.
    cursor: u64 = 0,
    /// MATCH: only the items whose field or member matches this pattern,
    /// such as "a*".
    match: ?[]const u8 = null,
    /// COUNT: about how many items the server looks at for the page, 10
    /// by default; a hint, not a limit.
    count: ?u32 = null,
};

/// The type of a page of `word`, SCAN or a scan of the items of one key
/// (`keyed`): `word [key] cursor [MATCH p] [COUNT n] [TYPE t]`, the TYPE
/// for `Options` that has a field `type`, and its items read into `I`. It
/// carries the mark of a scan, so `client.iterate` walks its pages.
pub fn Cursor(comptime call: []const u8, comptime word: []const u8, comptime I: type, comptime Options: type, comptime keyed: bool) type {
    const R = types.ScanPage(I);
    comptime resp.checkReply(R, call);
    const typed = @hasField(Options, "type");
    return struct {
        key: if (keyed) []const u8 else void,
        options: Options,

        const Self = @This();

        pub const Reply = R;

        pub const Item = I;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return checkPage(c.page(), diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return writePage(w, c.page());
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(_: Self) []const u8 {
            return word;
        }

        pub fn page(c: Self) contract.Page {
            const o = c.options;
            return .{
                .call = call,
                .word = word,
                .key = if (keyed) c.key else null,
                .cursor = o.cursor,
                .match = o.match,
                .count = o.count,
                .type = if (typed) o.type else null,
            };
        }
    };
}

/// The type of a page of a scan whose items read into `T`, as
/// `client.iterate` sends it: the page that a scan of `Cursor` describes,
/// with the cursor of the page before.
pub fn Paged(comptime T: type) type {
    const R = types.ScanPage(T);
    return struct {
        page: contract.Page,

        const Self = @This();

        pub const Reply = R;

        pub fn check(c: Self, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
            return checkPage(c.page, diagnostics);
        }

        pub fn write(c: Self, w: resp.Writer) resp.Writer.Error!void {
            return writePage(w, c.page);
        }

        pub fn read(_: Self, r: *resp.Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) resp.DecodeError!R {
            return resp.decode(R, r, arena, diagnostics);
        }

        pub fn name(c: Self) []const u8 {
            return c.page.word;
        }
    };
}

/// A TYPE that names no type of a key, `.none` or `.other`, is
/// InvalidArgument.
fn checkPage(p: contract.Page, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    if (p.type) |of| switch (of) {
        .none, .other => return invalid(diagnostics, "{s}: .type = .{t} names no type of a key: give string, list, set, zset, hash or stream", .{ p.call, of }),
        else => {},
    };
}

fn writePage(w: resp.Writer, p: contract.Page) resp.Writer.Error!void {
    var n: usize = 2 + @as(usize, @intFromBool(p.key != null));
    if (p.match != null) n += 2;
    if (p.count != null) n += 2;
    if (p.type != null) n += 2;
    try w.arrayHeader(n);
    try w.bulk(p.word);
    if (p.key) |key| try w.bulk(key);
    try args.write(w, p.cursor);
    if (p.match) |pattern| {
        try w.bulk("MATCH");
        try w.bulk(pattern);
    }
    if (p.count) |count| {
        try w.bulk("COUNT");
        try args.write(w, count);
    }
    if (p.type) |of| {
        try w.bulk("TYPE");
        try w.bulk(@tagName(of));
    }
}

/// How a field of the arguments goes out, by its type.
const Kind = enum { string, list, pairs, values, duration, end, bound, id, ids, value };

fn kindOf(comptime F: type) Kind {
    if (F == []const u8) return .string;
    if (F == []const []const u8) return .list;
    if (F == []const KeyValue) return .pairs;
    if (F == Io.Duration) return .duration;
    if (F == End) return .end;
    if (F == ScoreBound) return .bound;
    if (F == StreamId) return .id;
    if (F == []const StreamId) return .ids;
    if (isTuple(F)) return .values;
    return .value;
}

fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

/// The checks before sending of the fields of `fields`, by the table
/// above. `word` is the command, for the text of an empty list.
pub fn checkFields(fields: anytype, comptime call: []const u8, comptime word: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names, info.field_types) |field, F| {
        const v = @field(fields, field);
        const none = call ++ ": no " ++ field ++ ": " ++ word ++ " takes one or more";
        switch (comptime kindOf(F)) {
            .string, .end, .id => {},
            .list, .pairs, .ids => if (v.len == 0) return invalid(diagnostics, none, .{}),
            .values => {
                var n: usize = 0;
                inline for (0..@typeInfo(F).@"struct".field_types.len) |i| {
                    args.check(v[i]) catch return invalid(diagnostics, call ++ ": " ++ field ++ "[{d}] is NaN, which a server does not take", .{i});
                    n += args.count(v[i]);
                }
                if (n == 0) return invalid(diagnostics, none, .{});
            },
            .duration => _ = try millis(v, call, field, diagnostics),
            .bound => switch (v) {
                .inclusive, .exclusive => |score| if (std.math.isNan(score)) return invalid(diagnostics, call ++ ": " ++ field ++ " is NaN, which a server does not take", .{}),
                .min, .max => {},
            },
            .value => args.check(v) catch return invalid(diagnostics, call ++ ": " ++ field ++ " is NaN, which a server does not take", .{}),
        }
    }
}

/// How many arguments the fields of `fields` write.
pub fn countFields(fields: anytype) usize {
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    var n: usize = 0;
    inline for (info.field_names, info.field_types) |field, F| {
        const v = @field(fields, field);
        switch (comptime kindOf(F)) {
            .list, .ids => n += v.len,
            .pairs => n += 2 * v.len,
            .values => inline for (0..@typeInfo(F).@"struct".field_types.len) |i| {
                n += args.count(v[i]);
            },
            else => n += 1,
        }
    }
    return n;
}

/// Writes the fields of `fields`, which `checkFields` has checked.
pub fn writeFields(w: resp.Writer, fields: anytype) resp.Writer.Error!void {
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names, info.field_types) |field, F| {
        const v = @field(fields, field);
        switch (comptime kindOf(F)) {
            .string => try w.bulk(v),
            .list => for (v) |string| try w.bulk(string),
            .pairs => for (v) |pair| {
                try w.bulk(pair.key);
                try w.bulk(pair.value);
            },
            .values => inline for (0..@typeInfo(F).@"struct".field_types.len) |i| {
                try args.write(w, v[i]);
            },
            .duration => try writeMillis(w, v),
            .end => try w.bulk(switch (v) {
                .left => "LEFT",
                .right => "RIGHT",
            }),
            .bound => try writeBound(w, v),
            .id => try writeId(w, v),
            .ids => for (v) |id| try writeId(w, id),
            .value => try args.write(w, v),
        }
    }
}

/// Writes `id` as the server writes it, `<ms>-<seq>`.
pub fn writeId(w: resp.Writer, id: StreamId) resp.Writer.Error!void {
    // Two numbers of 20 digits and the dash.
    var buffer: [41]u8 = undefined;
    try w.bulk(std.fmt.bufPrint(&buffer, "{f}", .{id}) catch unreachable);
}

/// The type in which HSET and XADD keep their fields, `F` the type the
/// caller gave: a slice of `redis.FieldValue`, or a pointer to an array of
/// them, as `[]const redis.FieldValue`; a pointer to a tuple of literals
/// with a `.field` and a `.value` as an array of `redis.FieldValue` of its
/// own; anything else as it is, for the command to check.
pub fn FieldsOf(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == FieldValue) []const FieldValue else F,
            .one => switch (@typeInfo(info.child)) {
                .array => |array| if (array.child == FieldValue) []const FieldValue else F,
                .@"struct" => |child| if (child.is_tuple) [child.field_types.len]FieldValue else F,
                else => F,
            },
            else => F,
        },
        else => F,
    };
}

/// `fields` as HSET and XADD keep it: the literals behind a pointer to a
/// tuple copied into an array of `redis.FieldValue`.
pub fn fieldsOf(fields: anytype) FieldsOf(@TypeOf(fields)) {
    const F = FieldsOf(@TypeOf(fields));
    if (@typeInfo(F) == .array) {
        var list: F = undefined;
        inline for (&list, 0..) |*pair, i| pair.* = .{ .field = fields[i].field, .value = fields[i].value };
        return list;
    } else return fields;
}

/// Writes `bound`, which `checkFields` has checked: the score of an
/// inclusive bound, `(` and the score of an exclusive one, `-inf` for
/// `.min` and `+inf` for `.max`.
pub fn writeBound(w: resp.Writer, bound: ScoreBound) resp.Writer.Error!void {
    var buffer: [1 + args.float_buffer_len]u8 = undefined;
    switch (bound) {
        .min => try w.bulk("-inf"),
        .max => try w.bulk("+inf"),
        .inclusive => |score| try w.bulk(args.formatFloat(buffer[1..], score)),
        .exclusive => |score| {
            buffer[0] = '(';
            try w.bulk(buffer[0 .. 1 + args.formatFloat(buffer[1..], score).len]);
        },
    }
}

/// The type in which a command keeps a value of the caller's, `V` its
/// type: a string as `[]const u8`, an integer literal as `i64`, a float
/// literal as `f64`, an enum literal as the name of its tag, and any
/// other type as it is.
pub fn Arg(comptime V: type) type {
    if (args.isString(V)) return []const u8;
    return switch (@typeInfo(V)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .enum_literal => []const u8,
        else => V,
    };
}

/// `v` as a command keeps it.
pub fn arg(v: anytype) Arg(@TypeOf(v)) {
    return switch (@typeInfo(@TypeOf(v))) {
        .enum_literal => @tagName(v),
        else => v,
    };
}

/// Stops the build unless `V` is one value by the rules of arguments: a
/// string, a number, a bool or an enum. `what` names it in the message.
pub fn checkArg(comptime V: type, comptime call: []const u8, comptime what: []const u8) void {
    comptime args.checkType(V, call, what, false);
}

/// The type in which LPUSH and RPUSH keep their values, and a script its
/// arguments, `V` the type the caller gave: a list of strings, or a
/// pointer to a tuple of strings, as `[]const []const u8`; a tuple of
/// values, or a pointer to one, as the tuple. Anything else stops the
/// build; `what` names them in the message, "values" or "args".
pub fn Values(comptime V: type, comptime call: []const u8, comptime what: []const u8) type {
    comptime {
        if (args.isStringList(V)) return []const []const u8;
        if (isTuple(V)) return checkedValues(V, call, what);
        switch (@typeInfo(V)) {
            .pointer => |info| if (info.size == .one and isTuple(info.child)) {
                return if (allStrings(info.child)) []const []const u8 else checkedValues(info.child, call, what);
            },
            else => {},
        }
        @compileError(call ++ ": the " ++ what ++ " are a slice of strings, such as &.{ \"a\", \"b\" }, or a tuple of values, such as .{ \"a\", 42 }; got " ++ @typeName(V));
    }
}

/// `v` as LPUSH and RPUSH, and a script, keep it: a tuple behind a pointer
/// is copied, so that the command does not hold the pointer.
pub fn values(v: anytype, comptime call: []const u8, comptime what: []const u8) Values(@TypeOf(v), call, what) {
    const V = @TypeOf(v);
    const copied = comptime switch (@typeInfo(V)) {
        .pointer => |info| info.size == .one and isTuple(info.child) and !allStrings(info.child),
        else => false,
    };
    return if (copied) v.* else v;
}

fn checkedValues(comptime Tuple: type, comptime call: []const u8, comptime what: []const u8) type {
    for (@typeInfo(Tuple).@"struct".field_types, 0..) |F, i| {
        args.checkType(F, call, std.fmt.comptimePrint("{s}[{d}]", .{ what, i }), true);
    }
    return Tuple;
}

fn allStrings(comptime Tuple: type) bool {
    for (@typeInfo(Tuple).@"struct".field_types) |F| {
        if (!args.isString(F)) return false;
    }
    return true;
}

/// The milliseconds of `duration`, rounded down. A duration under 1 ms,
/// which a server takes as none or refuses, and one over `maxInt(i64)`
/// ms, the most the client counts, are InvalidArgument; `what` names the
/// argument in the text.
pub fn millis(duration: Io.Duration, comptime call: []const u8, comptime what: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!u64 {
    if (duration.nanoseconds < std.time.ns_per_ms) {
        return invalid(diagnostics, call ++ ": " ++ what ++ " is under 1 ms: give 1 ms or more", .{});
    }
    const ms = @divFloor(duration.nanoseconds, std.time.ns_per_ms);
    if (ms > std.math.maxInt(i64)) {
        return invalid(diagnostics, call ++ ": " ++ what ++ " is longer than {d} ms, the most the client counts", .{std.math.maxInt(i64)});
    }
    return @intCast(ms);
}

/// Writes `duration` as its milliseconds, which `millis` has checked.
pub fn writeMillis(w: resp.Writer, duration: Io.Duration) resp.Writer.Error!void {
    const ms: u64 = @intCast(std.math.clamp(@divFloor(duration.nanoseconds, std.time.ns_per_ms), 1, std.math.maxInt(i64)));
    try args.write(w, ms);
}

/// InvalidArgument, with the text of `fmt` in `diagnostics`.
pub fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, fmt_args: anytype) error{InvalidArgument} {
    if (diagnostics) |d| d.set(null, null, fmt, fmt_args);
    return error.InvalidArgument;
}
