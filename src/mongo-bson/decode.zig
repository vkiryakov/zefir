//! Reading BSON documents into Zig values by their types: `bson.decode`.

const std = @import("std");
const bson = @import("root.zig");
const check = @import("check.zig");
const keyed = @import("keyed.zig");

pub const DecodeOptions = struct {
    /// What a key does that no field of its struct takes: `.skip` it, as
    /// servers add fields to their replies, or `.fail` with
    /// `error.UnknownField`.
    unknown_fields: enum { skip, fail } = .skip,
    /// Copy strings, binary data, regular expressions and documents into
    /// the arena, so that the result lives as long as the arena. False
    /// leaves them slices into the document, which must then outlive the
    /// result.
    copy_strings: bool = true,
    /// Where decoding stopped, after an error.
    diagnostics: ?*DecodeDiagnostics = null,
};

pub const DecodeError = error{
    /// The bytes are not valid BSON where decode read them, or a string
    /// is not UTF-8.
    InvalidBson,
    /// A field without a default value, which is not optional, has no key.
    MissingField,
    /// A key that no field takes, with `.unknown_fields = .fail`.
    UnknownField,
    /// The key of a field comes twice in one document.
    DuplicateKey,
    /// The value is of a BSON type that the field does not take.
    WrongType,
    /// A double with a fraction, NaN or an infinity, for an integer field.
    NotAnInteger,
    /// A number beyond the range of the field's type.
    Overflow,
    /// A string that names no tag of the field's enum.
    InvalidEnumTag,
    /// An array with more or fewer items than the `[N]T` of its field.
    LengthMismatch,
    OutOfMemory,
};

/// Where `decode` stopped, for a log line or a test message. Each decode
/// empties it first.
pub const DecodeDiagnostics = struct {
    /// The path, written from the end as decode returns from the field
    /// that failed to the document that holds it.
    buffer: [256]u8 = undefined,
    start: usize = 256,
    truncated: bool = false,

    /// The keys of the field and of the documents that hold it, and the
    /// indexes in arrays, joined by dots as `RawDocument.getPath` takes
    /// them: "cursor.firstBatch.0.name"; "" for the document itself. A
    /// path longer than the buffer keeps its end: "….0.name".
    pub fn path(d: *const DecodeDiagnostics) []const u8 {
        return d.buffer[d.start..];
    }

    fn prepend(d: *DecodeDiagnostics, part: []const u8) void {
        if (d.truncated) return;
        const dot = d.start < d.buffer.len;
        // Room stays for "…." in front of what is written.
        if (d.start < part.len + @intFromBool(dot) + "….".len) {
            if (dot) d.put(".");
            d.put("…");
            d.truncated = true;
            return;
        }
        if (dot) d.put(".");
        d.put(part);
    }

    fn put(d: *DecodeDiagnostics, bytes: []const u8) void {
        d.start -= bytes.len;
        @memcpy(d.buffer[d.start..][0..bytes.len], bytes);
    }
};

/// The struct `T` that the document `raw` holds, by the types of its
/// fields, as `bson.encode` writes them:
///
/// - each key goes to the field of its name, in any order; a field
///   without a key takes its default value, an optional without one null,
///   and any other gives `error.MissingField`;
/// - a key that no field takes is skipped, or refused with
///   `.unknown_fields = .fail`; the key of a field that comes twice is
///   refused;
/// - an integer takes an int32, an int64, or a double that holds an
///   integer, within the range of its type; a float takes a double or an
///   integer, NaN and the infinities as they are;
/// - `[]const u8` takes a string, which must be UTF-8; an enum the name of
///   one of its tags; `?T` BSON null or a value of `T`; a struct a
///   document; `[]const T` and `[N]T` an array, `[N]T` of exactly N items;
/// - `RawDocument` takes a document, `Value` a value of any type, and the
///   special types their own BSON types, the deprecated `DbPointer` and
///   `JavaScriptWithScope` included.
///
/// Memory comes from `arena`, which the caller frees as a whole, after an
/// error too. After any error, `options.diagnostics` names the field. Only
/// what decode reads is checked: a skipped value and the inside of a
/// `RawDocument` or a `Value` are not, so check bytes from the network
/// with `RawDocument.validate` first.
pub fn decode(comptime T: type, arena: std.mem.Allocator, raw: bson.RawDocument, options: DecodeOptions) DecodeError!T {
    if (comptime check.document(T, .decode)) |problem| @compileError("bson.decode: " ++ problem);
    return decodeWithKeys(T, &.{}, arena, raw, options);
}

/// `decode` after its check, with the keys of the top-level fields of `T`
/// from `keys`, as `bson.decodeKeyed` takes them.
pub fn decodeWithKeys(comptime T: type, comptime keys: []const bson.FieldKey, arena: std.mem.Allocator, raw: bson.RawDocument, options: DecodeOptions) DecodeError!T {
    if (options.diagnostics) |diagnostics| diagnostics.* = .{};
    const decoder: Decoder = .{ .arena = arena, .options = options };
    return decoder.document(T, keys, raw);
}

const Decoder = struct {
    arena: std.mem.Allocator,
    options: DecodeOptions,

    /// The struct `T` that `doc` holds; `keys` gives the keys of its
    /// fields, which go by their names where it does not.
    fn document(d: Decoder, comptime T: type, comptime keys: []const bson.FieldKey, doc: bson.RawDocument) DecodeError!T {
        const info = @typeInfo(T).@"struct";
        var result: T = undefined;
        var seen: [info.field_names.len]bool = @splat(false);
        var it = doc.iterator();
        while (try it.next()) |element| {
            if (comptime info.field_names.len > 0) {
                if (keyed.fieldOf(T, keys, element.key)) |field| {
                    const index = @backingInt(field);
                    if (seen[index]) return d.at(element.key, error.DuplicateKey);
                    seen[index] = true;
                    switch (field) {
                        inline else => |known| {
                            const name = @tagName(known);
                            @field(result, name) = d.value(@FieldType(T, name), element.value) catch |err| return d.at(element.key, err);
                        },
                    }
                    continue;
                }
            }
            if (d.options.unknown_fields == .fail) return d.at(element.key, error.UnknownField);
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, i| {
            if (!seen[i]) {
                if (attrs.defaultValue(Field)) |default| {
                    @field(result, name) = default;
                } else if (@typeInfo(Field) == .optional) {
                    @field(result, name) = null;
                } else return d.at(comptime keyed.keyOf(keys, name) orelse name, error.MissingField);
            }
        }
        return result;
    }

    fn value(d: Decoder, comptime T: type, v: bson.Value) DecodeError!T {
        if (T == bson.Value) return d.copyValue(v);
        inline for (.{
            .{ bson.RawDocument, .document },                      .{ bson.ObjectId, .object_id },
            .{ bson.DateTime, .date_time },                        .{ bson.Timestamp, .timestamp },
            .{ bson.Binary, .binary },                             .{ bson.Decimal128, .decimal128 },
            .{ bson.Regex, .regex },                               .{ bson.DbPointer, .db_pointer },
            .{ bson.JavaScriptWithScope, .javascript_with_scope },
        }) |special| {
            if (T == special[0]) {
                if (v != special[1]) return error.WrongType;
                return @field(try d.copyValue(v), @tagName(special[1]));
            }
        }
        inline for (.{ .{ bson.Null, .null }, .{ bson.MinKey, .min_key }, .{ bson.MaxKey, .max_key } }) |special| {
            if (T == special[0]) return if (v == special[1]) .{} else error.WrongType;
        }
        switch (@typeInfo(T)) {
            .bool => return switch (v) {
                .boolean => |b| b,
                else => error.WrongType,
            },
            .int => return std.math.cast(T, try v.asI64()) orelse error.Overflow,
            .float => {
                const x = try v.asF64();
                if (T == f64) return x;
                const narrow: f32 = @floatCast(x);
                // A finite double beyond f32 would round to an infinity.
                if (std.math.isInf(narrow) and !std.math.isInf(x)) return error.Overflow;
                return narrow;
            },
            .@"enum" => return switch (v) {
                .string => |text| tag(T, text),
                else => error.WrongType,
            },
            .optional => |info| return if (v == .null) null else try d.value(info.child, v),
            .pointer => |info| {
                if (info.child == u8) return switch (v) {
                    .string => |text| d.string(text),
                    else => error.WrongType,
                };
                return switch (v) {
                    .array => |items| d.slice(info.child, items),
                    else => error.WrongType,
                };
            },
            .array => |info| return switch (v) {
                .array => |items| d.array(info.child, info.len, items),
                else => error.WrongType,
            },
            .@"struct" => return switch (v) {
                .document => |doc| d.document(T, &.{}, doc),
                else => error.WrongType,
            },
            else => comptime unreachable,
        }
    }

    fn slice(d: Decoder, comptime Item: type, items: bson.RawDocument) DecodeError![]const Item {
        var count: usize = 0;
        var it = items.iterator();
        while (try it.next()) |_| count += 1;
        const result = try d.arena.alloc(Item, count);
        it = items.iterator();
        for (result, 0..) |*item, i| {
            const element = (try it.next()) orelse return error.InvalidBson;
            item.* = d.value(Item, element.value) catch |err| return d.atIndex(i, err);
        }
        return result;
    }

    fn array(d: Decoder, comptime Item: type, comptime len: usize, items: bson.RawDocument) DecodeError![len]Item {
        var result: [len]Item = undefined;
        var it = items.iterator();
        var i: usize = 0;
        while (try it.next()) |element| : (i += 1) {
            if (i == len) return error.LengthMismatch;
            if (len > 0) result[i] = d.value(Item, element.value) catch |err| return d.atIndex(i, err);
        }
        if (i != len) return error.LengthMismatch;
        return result;
    }

    fn string(d: Decoder, text: []const u8) DecodeError![]const u8 {
        try utf8(text);
        return d.copy(text);
    }

    /// A copy of `v` whose strings, documents and bytes live in the arena,
    /// with `copy_strings`.
    fn copyValue(d: Decoder, v: bson.Value) DecodeError!bson.Value {
        if (v == .string) try utf8(v.string);
        if (!d.options.copy_strings) return v;
        return switch (v) {
            .string => |text| .{ .string = try d.copy(text) },
            .document => |doc| .{ .document = .{ .bytes = try d.copy(doc.bytes) } },
            .array => |doc| .{ .array = .{ .bytes = try d.copy(doc.bytes) } },
            .binary => |binary| .{ .binary = .{ .subtype = binary.subtype, .bytes = try d.copy(binary.bytes) } },
            .regex => |regex| .{ .regex = .{ .pattern = try d.copy(regex.pattern), .options = try d.copy(regex.options) } },
            .db_pointer => |pointer| .{ .db_pointer = .{ .namespace = try d.copy(pointer.namespace), .id = pointer.id } },
            .javascript => |code| .{ .javascript = try d.copy(code) },
            .symbol => |symbol| .{ .symbol = try d.copy(symbol) },
            .javascript_with_scope => |code| .{ .javascript_with_scope = .{
                .code = try d.copy(code.code),
                .scope = .{ .bytes = try d.copy(code.scope.bytes) },
            } },
            else => v,
        };
    }

    fn copy(d: Decoder, bytes: []const u8) DecodeError![]const u8 {
        return if (d.options.copy_strings) try d.arena.dupe(u8, bytes) else bytes;
    }

    /// Adds `part` to the front of the path of the diagnostics.
    fn at(d: Decoder, part: []const u8, err: DecodeError) DecodeError {
        if (d.options.diagnostics) |diagnostics| diagnostics.prepend(part);
        return err;
    }

    fn atIndex(d: Decoder, index: usize, err: DecodeError) DecodeError {
        var digits: [20]u8 = undefined;
        return d.at(std.fmt.bufPrint(&digits, "{d}", .{index}) catch unreachable, err);
    }
};

fn tag(comptime T: type, text: []const u8) DecodeError!T {
    try utf8(text);
    return std.meta.stringToEnum(T, text) orelse error.InvalidEnumTag;
}

fn utf8(text: []const u8) DecodeError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidBson;
}
