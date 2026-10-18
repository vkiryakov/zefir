//! `bson.literal`: a document written at compile time, by the rules of
//! `bson.encode`.

const std = @import("std");
const bson = @import("../bson.zig");
const check = @import("check.zig");
const codec = @import("encode.zig");
const read = @import("read.zig");

/// The document that `value` spells, written at compile time into static
/// bytes: no allocator, no `try`, and the bytes live forever. It is for
/// the constant documents of a call, such as sorts, projections and the
/// keys of indexes:
///
/// ```zig
/// const by_age = bson.literal(.{ .age = -1 });
/// ```
///
/// The bytes are those that `bson.encode` writes with the default options,
/// nulls included. `value` must be known at compile time; what `encode`
/// would refuse at run time, such as a string that is not UTF-8, stops the
/// build.
pub fn literal(comptime value: anytype) bson.RawDocument {
    const T = @TypeOf(value);
    if (comptime check.document(T, .encode)) |problem| @compileError("bson.literal: " ++ problem);
    const bytes = comptime bytes: {
        const doc = if (T == bson.RawDocument) embedded(value, 0) else document(value, 1);
        const final: [doc.len]u8 = doc[0..doc.len].*;
        break :bytes &final;
    };
    return .{ .bytes = bytes };
}

/// The document of the fields of `value`, which is `depth` levels deep.
fn document(comptime value: anytype, comptime depth: usize) []const u8 {
    @setEvalBranchQuota(1_000_000);
    if (depth > bson.max_depth) fail("more than 100 documents and arrays nest inside one another");
    var body: []const u8 = "";
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        body = body ++ element(name, @field(value, name), depth);
    }
    return frame(body);
}

/// The array of `items`, a tuple, an array or a slice, which is `depth`
/// levels deep.
fn array(comptime items: anytype, comptime depth: usize) []const u8 {
    if (depth > bson.max_depth) fail("more than 100 documents and arrays nest inside one another");
    var body: []const u8 = "";
    inline for (items, 0..) |item, i| {
        body = body ++ element(std.fmt.comptimePrint("{d}", .{i}), item, depth);
    }
    return frame(body);
}

/// The element `key` of a document `depth` levels deep.
fn element(comptime key: []const u8, comptime value: anytype, comptime depth: usize) []const u8 {
    const T = @TypeOf(value);
    return switch (codec.shape(T)) {
        .scalar => scalar(key, codec.scalar(value) catch fail("the string of '" ++ key ++ "' is not UTF-8"), depth),
        .document => header(.document, key) ++ document(value, depth + 1),
        .tuple => header(.array, key) ++ array(if (@typeInfo(T) == .pointer) value.* else value, depth + 1),
        .list => header(.array, key) ++ array(value, depth + 1),
        .optional => if (value) |inner| element(key, inner, depth) else header(.null, key),
    };
}

/// An element of one value, as `Builder.putValue` writes it.
fn scalar(comptime key: []const u8, comptime value: bson.Value, comptime depth: usize) []const u8 {
    const payload: []const u8 = switch (value) {
        .double => |d| &little(u64, @bitCast(d)),
        .string, .javascript => |text| string(text),
        .document, .array => |doc| embedded(doc, depth),
        .binary => |binary| if (binary.subtype == .binary_old)
            // The old subtype repeats the length inside its data.
            &little(i32, length(binary.bytes.len + 4)) ++ &[_]u8{@backingInt(binary.subtype)} ++ &little(i32, length(binary.bytes.len)) ++ binary.bytes
        else
            &little(i32, length(binary.bytes.len)) ++ &[_]u8{@backingInt(binary.subtype)} ++ binary.bytes,
        .object_id => |id| &id.bytes,
        .boolean => |b| &[_]u8{@intFromBool(b)},
        .date_time => |t| &little(i64, t.milliseconds),
        .null, .min_key, .max_key => "",
        .regex => |regex| cstring(regex.pattern) ++ cstring(sorted(regex.options)),
        .int32 => |n| &little(i32, n),
        // The uint64 is little-endian: the increment comes first.
        .timestamp => |t| &little(u32, t.increment) ++ &little(u32, t.seconds),
        .int64 => |n| &little(i64, n),
        .decimal128 => |d| &d.bytes,
        .undefined, .db_pointer, .symbol, .javascript_with_scope => fail("'" ++ key ++ "' is of a deprecated type: deprecated types are read, never written"),
    };
    return header(std.meta.activeTag(value), key) ++ payload;
}

/// A document given as it is, inside a document `depth` levels deep.
fn embedded(comptime doc: bson.RawDocument, comptime depth: usize) []const u8 {
    @setEvalBranchQuota(1_000_000);
    read.validate(doc.bytes, bson.max_depth - depth) catch fail("a document in it is not valid BSON, or nests too deep");
    return doc.bytes;
}

fn header(comptime kind: bson.Type, comptime key: []const u8) []const u8 {
    return &[_]u8{@backingInt(kind)} ++ cstring(key);
}

fn frame(comptime body: []const u8) []const u8 {
    return &little(i32, length(body.len + 5)) ++ body ++ "\x00";
}

fn string(comptime text: []const u8) []const u8 {
    return &little(i32, length(text.len + 1)) ++ text ++ "\x00";
}

fn cstring(comptime text: []const u8) []const u8 {
    if (std.mem.findScalar(u8, text, 0) != null) fail("a key or a regular expression holds a 0 byte");
    return text ++ "\x00";
}

/// The options of a regular expression, sorted as the spec asks.
fn sorted(comptime text: []const u8) []const u8 {
    var letters: [text.len]u8 = text[0..text.len].*;
    std.sort.insertion(u8, &letters, {}, std.sort.asc(u8));
    const final = letters;
    return &final;
}

fn little(comptime T: type, comptime n: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, n, .little);
    return out;
}

fn length(comptime n: usize) i32 {
    return std.math.cast(i32, n) orelse fail("the document is longer than BSON allows");
}

fn fail(comptime message: []const u8) noreturn {
    @compileError("bson.literal: " ++ message);
}
