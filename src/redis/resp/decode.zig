//! Reads a reply into the type a call names: one decoder for every
//! command, by the table of the design's §3.3. It pulls the reply from a
//! `Reader` element by element and never recurses on the data: the depth
//! of its calls follows the type, which the build knows, and what the type
//! does not hold the reader skips.
//!
//! | Type                 | Takes                                                    |
//! |----------------------|----------------------------------------------------------|
//! | `void`               | any reply but an error, read and dropped                 |
//! | `bool`               | `#t`, `#f`; `:1`, `:0`; the strings `1` and `0`          |
//! | an integer           | `:`; `$`, `+` and `(` with a decimal number in its range |
//! | a float              | `,`; `:`; `$` and `+` with a number                      |
//! | `[]const u8`         | `$`, `+`, `=` (without `txt:`), `(`; the text of `:` and `,` |
//! | `?T`                 | null, or what `T` takes                                  |
//! | an exhaustive enum   | `+` or `$` with the name of a tag                        |
//! | `[]const T`          | `*` or `~`, each element as `T`                          |
//! | `[N]T`               | `*` or `~` of exactly N elements                         |
//! | a tuple              | `*` of exactly as many elements, each as its own type    |
//! | a struct             | `%` by the names of its fields, or `*` of pairs: a hash  |
//! | `[]const FieldValue` | `%` or `*` of pairs: a hash of any fields                |
//! | `redis.Value`        | anything                                                 |
//!
//! A struct reads as a hash by the rules of `hash.zig`: defaults for the
//! fields the hash lacks, null for optionals, extra fields skipped, and an
//! empty hash null in `?T`.
//!
//! - `decode(T, reader, arena, diagnostics)` reads one whole reply.
//! - An error of the server at the top of the reply is ServerError for any
//!   type, `redis.Value` included. Inside an aggregate it is ServerError
//!   for a type, and a value `.err` in a `redis.Value`. Its code and text
//!   go to the diagnostics.
//! - A reply that does not fit the type is UnexpectedReply, with a text
//!   that names the kind and the size of what came and the type the call
//!   asked for, never a value: "the reply is a bulk string of 3 bytes, and
//!   the call asked for i64".
//! - After either, the decoder reads the rest of the reply without memory,
//!   so the connection stays in step. The errors of the reader
//!   (ProtocolViolation, ReplyTooLarge and those of the stream) and
//!   OutOfMemory leave it out of step: the connection must be closed.
//! - Memory comes from `arena` only, and nothing is freed: the result lives
//!   as long as the arena. Strings are copies, never slices of the buffer
//!   of the connection. A reply that needs memory gets OutOfMemory without
//!   an arena; the client checks `needsAllocator` before it sends.
//! - `checkReply(T, call)` stops the build for a type that no reply reads
//!   into, with a message that starts with the call and names the path of
//!   the field at fault.
//! - `Decoder` reads the elements of a reply one by one, for the reading
//!   rules of other files.

const std = @import("std");
const Reader = @import("Reader.zig");
const value = @import("value.zig");
const args = @import("args.zig");
const hash = @import("hash.zig");
const FieldValue = @import("../cmd/types.zig").FieldValue;
const Diagnostics = @import("../errors.zig").Diagnostics;

const Element = Reader.Element;
const Value = value.Value;

/// What reading a reply can fail with. After ServerError and
/// UnexpectedReply the reply has been read to its end; after the others
/// the stream is out of step.
pub const Error = Reader.Error || error{ ServerError, UnexpectedReply, OutOfMemory };

/// Reads one whole reply from `reader` into `T`, with its memory from
/// `arena`. What went wrong goes to `diagnostics`, if given.
pub fn decode(comptime T: type, reader: *Reader, arena: ?std.mem.Allocator, diagnostics: ?*Diagnostics) Error!T {
    var d: Decoder = .{ .reader = reader, .arena = arena, .diagnostics = diagnostics };
    return d.reply(T);
}

/// The state of the reading of one reply.
pub const Decoder = struct {
    reader: *Reader,
    arena: ?std.mem.Allocator,
    diagnostics: ?*Diagnostics,
    /// How many aggregates hold the element being read: 0 at the top.
    depth: usize = 0,
    /// The name of the field of a hash whose value is being read.
    field: ?[]const u8 = null,

    /// Reads a whole reply into `T`: its first element, all it holds, and
    /// after ServerError or UnexpectedReply what is left of the reply.
    pub fn reply(d: *Decoder, comptime T: type) Error!T {
        const first = try d.reader.next();
        const result: Error!T = if (isError(first)) d.serverError() else d.read(T, first);
        return result catch |err| switch (err) {
            error.ServerError, error.UnexpectedReply => {
                try d.reader.skipReply();
                return err;
            },
            else => return err,
        };
    }

    /// Reads `element`, which the reader has just returned, and all it
    /// holds into `T`.
    pub fn read(d: *Decoder, comptime T: type, element: Element) Error!T {
        return d.readNamed(T, element, T);
    }

    /// `read`, but a text of UnexpectedReply about `element` itself names
    /// `Named` as the type the call asked for: a reading rule of a type
    /// reads its parts with the name of the whole.
    pub fn readNamed(d: *Decoder, comptime T: type, element: Element, comptime Named: type) Error!T {
        if (T == Value) return value.readFrom(d.reader, element, try d.allocator());
        if (isError(element)) return d.serverError();
        if (comptime hasRule(T)) return T.redisDecode(d, element);
        switch (@typeInfo(T)) {
            .void => return d.reader.skipElement(),
            .bool => return d.readBool(element, Named),
            .int => return d.readInt(T, element, Named),
            .float => return d.readFloat(T, element, Named),
            .@"enum" => |info| {
                if (info.mode == .exhaustive) return d.readEnum(T, element, Named);
            },
            .optional => |info| {
                if (element == .null) return null;
                // HGETALL answers an empty map for a key that is not there.
                if (comptime hash.isHash(info.child)) switch (element) {
                    .map, .array, .push => |n| if (n == 0) return null,
                    else => {},
                };
                return try d.readNamed(info.child, element, Named);
            },
            .pointer => |info| {
                if (T == []const u8) return d.readString(element, Named);
                if (T == []const FieldValue) return hash.readFieldValues(d, element, Named);
                if (info.size == .slice and info.attrs.@"const" and info.sentinel_ptr == null) {
                    return d.readSlice(info.child, element, Named);
                }
            },
            .array => |info| {
                if (info.sentinel_ptr == null) return d.readArray(info.child, info.len, element, Named);
            },
            .@"struct" => |info| {
                if (info.is_tuple) return d.readTuple(T, element, Named);
                return hash.readStruct(T, d, element, Named);
            },
            else => {},
        }
        @compileError("redis: no reply reads into " ++ @typeName(T) ++ "; check the type with checkReply");
    }

    /// Reads the elements of an array of exactly as many elements as the
    /// tuple `Tuple` has fields, each as the type of its field.
    pub fn readTuple(d: *Decoder, comptime Tuple: type, element: Element, comptime Named: type) Error!Tuple {
        const fields = @typeInfo(Tuple).@"struct".field_types;
        try d.expectArray(element, fields.len, Named);
        var items: Tuple = undefined;
        d.depth += 1;
        defer d.depth -= 1;
        inline for (fields, 0..) |F, i| items[i] = try d.read(F, try d.reader.next());
        return items;
    }

    /// UnexpectedReply unless `element` is an array of `len` elements.
    pub fn expectArray(d: *Decoder, element: Element, len: usize, comptime Named: type) Error!void {
        switch (element) {
            .array, .push => |n| if (n == len) return,
            else => {},
        }
        return d.mismatch(Named, element);
    }

    /// How many pairs a map, or a flat array of pairs, holds; UnexpectedReply
    /// for anything else.
    pub fn pairs(d: *Decoder, element: Element, comptime Named: type) Error!usize {
        return switch (element) {
            .map => |n| n,
            .array, .push => |n| if (n % 2 == 0) n / 2 else d.mismatch(Named, element),
            else => d.mismatch(Named, element),
        };
    }

    /// Reads a map, or a flat array of pairs, into a slice of `T`, whose
    /// rule `redisDecodePair` reads one pair: as HSCAN and ZSCAN answer.
    pub fn readPairs(d: *Decoder, comptime T: type, element: Element, comptime Named: type) Error![]const T {
        const items = try (try d.allocator()).alloc(T, try d.pairs(element, Named));
        d.depth += 1;
        defer d.depth -= 1;
        for (items) |*item| item.* = try T.redisDecodePair(d, try d.reader.next());
        return items;
    }

    /// The memory of the result.
    pub fn allocator(d: *Decoder) error{OutOfMemory}!std.mem.Allocator {
        return d.arena orelse error.OutOfMemory;
    }

    /// Reads the text of the error the reader has just returned into the
    /// diagnostics, and returns ServerError.
    pub fn serverError(d: *Decoder) Error {
        if (d.diagnostics) |diagnostics| {
            // As much as Diagnostics keeps of a text.
            var text: [512]u8 = undefined;
            const prefix = d.reader.payloadPrefix(&text) catch |err| return err;
            diagnostics.setServer(.receive, prefix.bytes);
        } else {
            d.reader.skipPayload() catch |err| return err;
        }
        return error.ServerError;
    }

    /// UnexpectedReply about `element`, whose bytes, if it is a string, are
    /// not read yet: the text says what came and that the call asked for
    /// `Named`.
    pub fn mismatch(d: *Decoder, comptime Named: type, element: Element) Error {
        var len: ?usize = null;
        if (element == .simple_string) {
            // Only its end tells the length of a simple string.
            var none: [0]u8 = undefined;
            len = (d.reader.payloadPrefix(&none) catch |err| return err).len;
        }
        return d.mismatchText(Named, element, len);
    }

    /// `mismatch` about a string whose bytes are read: `len` of them.
    pub fn mismatchText(d: *Decoder, comptime Named: type, element: Element, len: ?usize) Error {
        if (d.diagnostics) |diagnostics| {
            const kind: Kind = .{ .element = element, .len = len };
            if (d.field) |name| {
                diagnostics.set(.receive, null, "field '{s}' of the reply is {f}, and the call asked for {s}", .{ name, kind, @typeName(Named) });
            } else if (d.depth == 0) {
                diagnostics.set(.receive, null, "the reply is {f}, and the call asked for {s}", .{ kind, @typeName(Named) });
            } else {
                diagnostics.set(.receive, null, "the reply holds {f} where the call asked for {s}", .{ kind, @typeName(Named) });
            }
        }
        return error.UnexpectedReply;
    }

    fn readBool(d: *Decoder, element: Element, comptime Named: type) Error!bool {
        switch (element) {
            .boolean => |b| return b,
            .integer => |n| if (n == 0 or n == 1) return n == 1,
            .simple_string, .bulk_string => {
                var buffer: [1]u8 = undefined;
                const text = try d.reader.payloadPrefix(&buffer);
                if (text.len == 1 and (buffer[0] == '0' or buffer[0] == '1')) return buffer[0] == '1';
                return d.mismatchText(Named, element, text.len);
            },
            else => {},
        }
        return d.mismatch(Named, element);
    }

    fn readInt(d: *Decoder, comptime T: type, element: Element, comptime Named: type) Error!T {
        switch (element) {
            .integer => |n| if (std.math.cast(T, n)) |v| return v,
            .simple_string, .bulk_string, .big_number => {
                // A longer text is no integer of T.
                var buffer: [args.intTextLen(T)]u8 = undefined;
                const text = try d.reader.payloadPrefix(&buffer);
                if (text.len <= buffer.len) {
                    if (parseInteger(T, text.bytes)) |v| return v;
                }
                return d.mismatchText(Named, element, text.len);
            },
            else => {},
        }
        return d.mismatch(Named, element);
    }

    fn readFloat(d: *Decoder, comptime T: type, element: Element, comptime Named: type) Error!T {
        switch (element) {
            .double => |x| return @floatCast(x),
            .integer => |n| return @floatFromInt(n),
            .simple_string, .bulk_string => {
                // INCRBYFLOAT writes a large result without an exponent: an
                // f64 takes up to about 330 characters so.
                var buffer: [512]u8 = undefined;
                const text = try d.reader.payloadPrefix(&buffer);
                if (text.len <= buffer.len and Reader.isDouble(text.bytes)) {
                    if (std.fmt.parseFloat(T, text.bytes)) |x| return x else |_| {}
                }
                return d.mismatchText(Named, element, text.len);
            },
            else => {},
        }
        return d.mismatch(Named, element);
    }

    fn readEnum(d: *Decoder, comptime T: type, element: Element, comptime Named: type) Error!T {
        const names = @typeInfo(T).@"enum".field_names;
        switch (element) {
            .simple_string, .bulk_string => {
                // A longer text names no tag.
                var buffer: [longest(names)]u8 = undefined;
                const text = try d.reader.payloadPrefix(&buffer);
                if (text.len <= buffer.len) {
                    inline for (names) |name| {
                        if (std.mem.eql(u8, name, text.bytes)) return @field(T, name);
                    }
                }
                return d.mismatchText(Named, element, text.len);
            },
            else => return d.mismatch(Named, element),
        }
    }

    fn readString(d: *Decoder, element: Element, comptime Named: type) Error![]const u8 {
        switch (element) {
            .simple_string, .bulk_string, .verbatim_string, .big_number => return d.reader.payloadAlloc(try d.allocator()),
            .integer => |n| return std.fmt.allocPrint(try d.allocator(), "{d}", .{n}),
            .double => |x| {
                var buffer: [args.float_buffer_len]u8 = undefined;
                return (try d.allocator()).dupe(u8, args.formatFloat(&buffer, x));
            },
            else => return d.mismatch(Named, element),
        }
    }

    fn readSlice(d: *Decoder, comptime Child: type, element: Element, comptime Named: type) Error![]const Child {
        const n = switch (element) {
            .array, .set, .push => |n| n,
            else => return d.mismatch(Named, element),
        };
        // The reader has checked that n elements fit what is left of the
        // reply's budget.
        const items = try (try d.allocator()).alloc(Child, n);
        d.depth += 1;
        defer d.depth -= 1;
        for (items) |*item| item.* = try d.read(Child, try d.reader.next());
        return items;
    }

    fn readArray(d: *Decoder, comptime Child: type, comptime len: usize, element: Element, comptime Named: type) Error![len]Child {
        switch (element) {
            .array, .set, .push => |n| if (n != len) return d.mismatch(Named, element),
            else => return d.mismatch(Named, element),
        }
        var items: [len]Child = undefined;
        d.depth += 1;
        defer d.depth -= 1;
        for (&items) |*item| item.* = try d.read(Child, try d.reader.next());
        return items;
    }
};

/// What came, for the text of UnexpectedReply: its kind and its size,
/// never its value.
pub const Kind = struct {
    element: Element,
    /// The length of a simple string.
    len: ?usize,

    pub fn format(k: Kind, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (k.element) {
            .null => try w.writeAll("a null"),
            .boolean => try w.writeAll("a boolean"),
            .integer => try w.writeAll("an integer"),
            .double => try w.writeAll("a double"),
            .big_number => try w.writeAll("a big number"),
            .simple_error, .bulk_error => try w.writeAll("an error"),
            .simple_string => try sized(w, "a simple string", k.len orelse 0, "byte"),
            .bulk_string => |n| try sized(w, "a bulk string", n, "byte"),
            .verbatim_string => |verbatim| try sized(w, "a verbatim string", verbatim.len, "byte"),
            .array => |n| try sized(w, "an array", n, "element"),
            .set => |n| try sized(w, "a set", n, "element"),
            .push => |n| try sized(w, "a push", n, "element"),
            .map => |n| try sized(w, "a map", n, "pair"),
        }
    }

    fn sized(w: *std.Io.Writer, kind: []const u8, n: usize, unit: []const u8) std.Io.Writer.Error!void {
        try w.print("{s} of {d} {s}{s}", .{ kind, n, unit, if (n == 1) "" else "s" });
    }
};

/// Whether `T` has a reading rule of its own, `redisDecode`, as the result
/// types of the catalog have: `redis.Ttl`, `redis.ScanPage(T)` and the
/// others of `cmd/types.zig`. The rule is internal to the module.
pub fn hasRule(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "redisDecode"),
        else => false,
    };
}

fn isError(element: Element) bool {
    return element == .simple_error or element == .bulk_error;
}

/// The length of the longest of `names`.
pub fn longest(comptime names: []const [:0]const u8) usize {
    var n: usize = 0;
    for (names) |name| n = @max(n, name.len);
    return n;
}

/// The integer of `text` as Redis writes one: an optional '-' and decimal
/// digits, with no leading zero; null when `text` is not such a number or
/// it does not fit `T`.
fn parseInteger(comptime T: type, text: []const u8) ?T {
    const negative = text.len > 0 and text[0] == '-';
    const digits = text[@intFromBool(negative)..];
    if (digits.len == 0) return null;
    if (digits[0] == '0' and (digits.len > 1 or negative)) return null;
    // Wide enough for ten times any value of T and a digit more: the loop
    // stops as soon as the value leaves the range of T.
    const Wide = @Int(.signed, @max(@typeInfo(T).int.bits, 64) + 8);
    var wide: Wide = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        const digit: Wide = c - '0';
        wide = if (negative) wide * 10 - digit else wide * 10 + digit;
        if (std.math.cast(T, wide) == null) return null;
    }
    return @intCast(wide);
}

/// Whether reading a reply into `T` may take memory: true for any type
/// that holds a slice, `redis.Value` among them. Without an allocator,
/// such a reply is InvalidArgument before anything is sent.
pub fn needsAllocator(comptime T: type) bool {
    return comptime takesMemory(T);
}

fn takesMemory(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |info| takesMemory(info.child),
        .array => |info| info.len > 0 and takesMemory(info.child),
        inline .@"struct", .@"union" => |info| for (info.field_types) |F| {
            if (takesMemory(F)) break true;
        } else false,
        else => false,
    };
}

/// Stops the build unless a reply reads into `T`, with a message that
/// starts with `call`, such as "redis.cmd.raw", names the type, and for a
/// part of it the path of the field.
pub fn checkReply(comptime T: type, comptime call: []const u8) void {
    comptime checkPart(T, call, "", T);
}

const readable = "a reply reads into a string, a number, a bool, an enum, an optional, a slice, an array, a tuple, a struct of a hash or a redis.Value";

fn checkPart(comptime T: type, comptime call: []const u8, comptime path: []const u8, comptime Root: type) void {
    const subject = if (path.len == 0)
        call ++ ": the reply type is " ++ @typeName(T)
    else
        call ++ ": field '" ++ path ++ "' of the reply type " ++ @typeName(Root) ++ " is " ++ @typeName(T);
    if (T == Value) return;
    if (hasRule(T)) {
        // A type with a rule of its own is read by it; the types it reads
        // its parts into, such as the T of redis.Entry(T), are checked.
        if (@typeInfo(T) == .@"struct") {
            const info = @typeInfo(T).@"struct";
            for (info.field_names, info.field_types) |name, F| {
                checkPart(F, call, if (path.len == 0) name else path ++ "." ++ name, Root);
            }
        }
        return;
    }
    switch (@typeInfo(T)) {
        .void, .bool, .int, .float => {},
        .@"enum" => |info| if (info.mode != .exhaustive) {
            @compileError(subject ++ ", a non-exhaustive enum: a name that it lacks has no value to read into; make the enum exhaustive");
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .optional) {
                @compileError(subject ++ ", an optional of an optional: a null reply cannot tell the two apart; use " ++ @typeName(info.child));
            }
            checkPart(info.child, call, path, Root);
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError(subject ++ ", a pointer: " ++ readable ++ "; read the value itself");
            if (!info.attrs.@"const" or info.sentinel_ptr != null) {
                @compileError(subject ++ ": the slices of a reply are const and have no sentinel; use []const " ++ @typeName(info.child));
            }
            if (info.child != u8) checkPart(info.child, call, path ++ "[]", Root);
        },
        .array => |info| {
            if (info.sentinel_ptr != null) @compileError(subject ++ ": the arrays of a reply have no sentinel");
            checkPart(info.child, call, path ++ "[]", Root);
        },
        .@"struct" => |info| {
            if (!info.is_tuple) return hash.checkRead(T, call, path, Root);
            for (info.field_types, info.field_attrs, 0..) |F, attrs, i| {
                const at = path ++ std.fmt.comptimePrint("[{d}]", .{i});
                if (attrs.@"comptime") @compileError(call ++ ": field '" ++ at ++ "' of the reply type " ++ @typeName(Root) ++ " is a comptime field: a reply fills only fields known at run time");
                checkPart(F, call, at, Root);
            }
        },
        .@"union" => @compileError(subject ++ ", a union: " ++ readable ++ "; read a reply of any shape as redis.Value"),
        else => @compileError(subject ++ ": " ++ readable),
    }
}
