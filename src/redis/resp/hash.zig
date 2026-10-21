//! A hash and a struct, both ways: the fields of `cmd.hset` and
//! `cmd.xadd` written from a struct, and a struct read from the reply of
//! `HGETALL` or from the fields of an entry of a stream.
//!
//! - The name of a field of the hash is the name of the field of the
//!   struct, as it is: `.@"created-at"` for a name with a dash.
//! - The values are flat strings, by the table of `args`: strings, numbers,
//!   `bool` as `1` or `0`, an enum as the name of its tag. An optional that
//!   is null is not written: HSET cannot delete a field, `cmd.hdel` does.
//!   With no field to write, the call is InvalidArgument.
//! - Read from a map, or from a flat array of pairs as the fields of an
//!   entry of a stream come: a field the hash lacks takes its default
//!   value, an optional without one null, and else the call is
//!   UnexpectedReply, whose text names the field; the fields that the
//!   struct lacks are skipped; an empty hash, which HGETALL answers for a
//!   key that is not there, is null in `?T`.
//! - `[]const redis.FieldValue` in place of a struct is a hash of any
//!   fields, read in the order of the server.
//! - A field that is a struct, a list, a union or a pointer stops the
//!   build with the path of the field: a hash has no nesting.

const std = @import("std");
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const args = @import("args.zig");
const decode = @import("decode.zig");
const FieldValue = @import("../cmd/types.zig").FieldValue;
const Diagnostics = @import("../errors.zig").Diagnostics;

const Decoder = decode.Decoder;
const Element = Reader.Element;

/// Whether a reply of type `T` reads as a hash: a struct with named
/// fields, or `[]const redis.FieldValue`.
pub fn isHash(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and !decode.hasRule(T),
        else => T == []const FieldValue,
    };
}

/// Whether `T` is a list of `redis.FieldValue` to write: a slice of them,
/// or a pointer to an array of them.
fn isFieldValueList(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return switch (info.size) {
        .slice => info.child == FieldValue,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child == FieldValue,
            else => false,
        },
        else => false,
    };
}

const one_value = "a field of a hash holds one string, number, bool or enum";

/// Stops the build unless `T` can be written as the fields of a hash: a
/// struct whose fields are strings, numbers, bools, enums or optionals of
/// them, or a list of `redis.FieldValue`. `call` starts the message.
pub fn checkWrite(comptime T: type, comptime call: []const u8) void {
    comptime {
        if (isFieldValueList(T)) return;
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(call ++ ": the fields are a struct, such as .{ .name = name }, or a slice of redis.FieldValue; got " ++ @typeName(T)),
        };
        if (info.is_tuple) @compileError(call ++ ": a tuple has no field names: give the values names, such as .{ .name = name }");
        for (info.field_names, info.field_types) |name, F| {
            checkField(F, call ++ ": field '" ++ name ++ "' is " ++ @typeName(F), .write);
        }
    }
}

/// Stops the build unless the struct `T`, at `path` of the reply type
/// `Root`, reads as a hash: its fields are strings, numbers, bools, enums
/// or optionals of them.
pub fn checkRead(comptime T: type, comptime call: []const u8, comptime path: []const u8, comptime Root: type) void {
    comptime {
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            const at = if (path.len == 0) name else path ++ "." ++ name;
            const subject = call ++ ": field '" ++ at ++ "' of the reply type " ++ @typeName(Root) ++ " is " ++ @typeName(F);
            if (attrs.@"comptime") @compileError(subject ++ ", a comptime field: a reply fills only fields known at run time");
            checkField(F, subject, .read);
        }
    }
}

/// The check of the type of one field, whose message starts with
/// `subject`. A string read is `[]const u8`; one written, any string.
fn checkField(comptime F: type, comptime subject: []const u8, comptime side: enum { read, write }) void {
    const Plain = switch (@typeInfo(F)) {
        .optional => |info| info.child,
        else => F,
    };
    if (side == .write and args.isString(Plain)) return;
    if (Plain == []const u8) return;
    switch (@typeInfo(Plain)) {
        .int, .float, .bool => return,
        .comptime_int, .comptime_float, .enum_literal => if (side == .write) return,
        .@"enum" => |info| {
            if (info.mode == .exhaustive) return;
            @compileError(subject ++ ", a non-exhaustive enum: a value without a tag has no name; make the enum exhaustive");
        },
        .optional => @compileError(subject ++ ", an optional of an optional: a field that the hash lacks cannot tell the two apart; use " ++ @typeName(Plain)),
        .@"struct" => @compileError(subject ++ ", a struct: " ++ one_value ++ ", and a hash has no nesting; move its fields into the outer struct"),
        .@"union" => @compileError(subject ++ ", a union: " ++ one_value),
        .pointer => |info| {
            if (info.size == .slice and info.child == u8) {
                @compileError(subject ++ ": the strings of a reply are const and have no sentinel; use []const u8");
            }
            if (info.size == .slice) @compileError(subject ++ ": " ++ one_value ++ ", not a list; keep a list in a key of its own");
            @compileError(subject ++ ", a pointer: " ++ one_value ++ "; hold the value itself");
        },
        else => {},
    }
    @compileError(subject ++ ": " ++ one_value);
}

/// How many fields `fields` writes: all of a list, and of a struct all but
/// the optionals that are null.
pub fn fieldCount(fields: anytype) usize {
    const T = @TypeOf(fields);
    if (comptime isFieldValueList(T)) return fields.len;
    var n: usize = 0;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) == .optional) {
            if (@field(fields, name) != null) n += 1;
        } else n += 1;
    }
    return n;
}

/// The check before sending: no field to write, or a field that is NaN, is
/// InvalidArgument, with the reason in `diagnostics`.
pub fn check(fields: anytype, comptime call: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    if (fieldCount(fields) == 0) {
        if (diagnostics) |d| d.set(null, null, call ++ ": no field to write: a hash takes at least one", .{});
        return error.InvalidArgument;
    }
    const T = @TypeOf(fields);
    if (comptime isFieldValueList(T)) return;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) == .optional) {
            if (@field(fields, name)) |present| try checkValue(present, call, name, diagnostics);
        } else {
            try checkValue(@field(fields, name), call, name, diagnostics);
        }
    }
}

fn checkValue(v: anytype, comptime call: []const u8, comptime name: []const u8, diagnostics: ?*Diagnostics) error{InvalidArgument}!void {
    args.check(v) catch |err| {
        if (diagnostics) |d| d.set(null, null, call ++ ": field '" ++ name ++ "' is NaN, which a server does not take", .{});
        return err;
    };
}

/// Writes `fields` as pairs of bulk strings, a name and its value, in the
/// order of the struct or of the list. The caller has checked them.
pub fn write(w: Writer, fields: anytype) Writer.Error!void {
    const T = @TypeOf(fields);
    if (comptime isFieldValueList(T)) {
        for (fields) |pair| {
            try w.bulk(pair.field);
            try w.bulk(pair.value);
        }
        return;
    }
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (@typeInfo(F) == .optional) {
            if (@field(fields, name)) |present| {
                try w.bulk(name);
                try args.write(w, present);
            }
        } else {
            try w.bulk(name);
            try args.write(w, @field(fields, name));
        }
    }
}

/// Reads a hash from a map or a flat array of pairs into the struct `T`.
pub fn readStruct(comptime T: type, d: *Decoder, element: Element, comptime Named: type) decode.Error!T {
    const pairs = try d.pairs(element, Named);
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    var seen: [info.field_names.len]bool = @splat(false);
    d.depth += 1;
    defer d.depth -= 1;
    for (0..pairs) |_| {
        const index = try fieldIndex(T, d, try d.reader.next());
        const field_value = try d.reader.next();
        const found = index orelse {
            try d.reader.skipElement();
            continue;
        };
        inline for (info.field_names, info.field_types, 0..) |name, F, i| {
            if (found == i) {
                d.field = name;
                defer d.field = null;
                @field(result, name) = try d.read(F, field_value);
                seen[i] = true;
            }
        }
    }
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        if (!seen[i]) {
            if (comptime attrs.defaultValue(F)) |default| {
                @field(result, name) = default;
            } else if (@typeInfo(F) == .optional) {
                @field(result, name) = null;
            } else {
                if (d.diagnostics) |diagnostics| {
                    diagnostics.set(.receive, null, "the hash lacks the field '{s}' of {s}, which has no default value", .{ name, @typeName(T) });
                }
                return error.UnexpectedReply;
            }
        }
    }
    return result;
}

/// Reads the name of a field of the hash, `key`, and returns the index of
/// the field of `T` it names; null for a name that `T` lacks, or a key
/// that is not a string.
fn fieldIndex(comptime T: type, d: *Decoder, key: Element) decode.Error!?usize {
    const names = @typeInfo(T).@"struct".field_names;
    switch (key) {
        .simple_string, .bulk_string, .verbatim_string => {
            // A longer name is none of them.
            var buffer: [decode.longest(names)]u8 = undefined;
            const name = try d.reader.payloadPrefix(&buffer);
            if (name.len > buffer.len) return null;
            inline for (names, 0..) |field, i| {
                if (std.mem.eql(u8, field, name.bytes)) return i;
            }
            return null;
        },
        else => {
            try d.reader.skipElement();
            return null;
        },
    }
}

/// Reads a hash from a map or a flat array of pairs into a slice of
/// `redis.FieldValue`, in the order of the server.
pub fn readFieldValues(d: *Decoder, element: Element, comptime Named: type) decode.Error![]const FieldValue {
    return d.readPairs(FieldValue, element, Named);
}
