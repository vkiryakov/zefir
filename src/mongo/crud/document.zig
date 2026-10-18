//! The documents of the collection API's operations — a filter, an update,
//! a replacement, a document to insert — in their three forms:
//!
//! 1. a `bson.RawDocument`, bytes ready, from a file or another reply;
//! 2. a `bson.OwnedDocument`, such as `Builder.finish` gives;
//! 3. a struct, or an anonymous literal, that `bson.encode` writes:
//!    `.{ .age = .{ .@"$gte" = 18 } }`; `.{}` is the empty document.
//!
//! The first two are borrowed until the operation returns; a struct is
//! written into the operation's scratch memory. Nulls are written as BSON
//! null, never left out: in a filter, a field left out would match every
//! document.
//!
//! A list — the documents of `insertMany`, a pipeline — is a slice, an
//! array or a tuple of documents in any of the three forms, or a pointer
//! to an array or a tuple. A tuple, an array and a slice are always a
//! list: that is how an update tells a pipeline from a document of update
//! operators.
//!
//! A type that fits none of the forms stops the build with the name of the
//! operation, of the argument and of the field: the operations check their
//! arguments with `expectDocument` and `expectList`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const check = @import("../bson/check.zig");

/// How the collection API takes an argument of a type.
pub const Kind = enum {
    /// One document: a `RawDocument`, an `OwnedDocument`, or a struct,
    /// `.{}` among them.
    document,
    /// A list of documents: a tuple with items, an array, a slice, or a
    /// pointer to a tuple or an array.
    list,
    /// Neither; the checks say why.
    other,
};

pub fn kind(comptime T: type) Kind {
    if (T == bson.RawDocument or T == bson.OwnedDocument) return .document;
    if (check.isSpecial(T)) return .other;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple and info.field_names.len > 0) .list else .document,
        .array => .list,
        .pointer => |info| switch (info.size) {
            // []const u8 is a string.
            .slice => if (info.child == u8) .other else .list,
            .one => switch (@typeInfo(info.child)) {
                .array => |array| if (array.child == u8) .other else .list,
                .@"struct" => |child| if (child.is_tuple) .list else .other,
                else => .other,
            },
            else => .other,
        },
        else => .other,
    };
}

/// Whether `T` is the type of `.{}`, which is the empty document, and the
/// empty list where a list goes.
pub fn isEmptyTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple and info.field_names.len == 0,
        else => false,
    };
}

/// Stops the build unless `T` is a document of the three forms, with a
/// message that starts "mongo.Collection.<operation>: <argument>: " and
/// names the field that does not fit.
pub fn expectDocument(comptime operation: []const u8, comptime argument: []const u8, comptime T: type) void {
    if (comptime check.document(T, .encode)) |problem| @compileError(prefix(operation, argument) ++ problem);
}

/// As `expectDocument`, for an operation of `mongo.Database`: the message
/// starts "mongo.Database.<operation>: <argument>: ".
pub fn expectDatabaseDocument(comptime operation: []const u8, comptime argument: []const u8, comptime T: type) void {
    if (comptime check.document(T, .encode)) |problem| @compileError("mongo.Database." ++ operation ++ ": " ++ argument ++ ": " ++ problem);
}

/// Stops the build unless `T` is a list of documents of the three forms,
/// or `.{}`, the empty list.
pub fn expectList(comptime operation: []const u8, comptime argument: []const u8, comptime T: type) void {
    if (kind(T) != .list) {
        if (isEmptyTuple(T)) return;
        @compileError(prefix(operation, argument) ++ "a list of documents is a slice, an array or a tuple of them; got " ++ @typeName(T));
    }
    if (Tuple(T)) |Items| {
        for (@typeInfo(Items).@"struct".field_types, 0..) |Field, i| {
            expectDocument(operation, std.fmt.comptimePrint("{s}[{d}]", .{ argument, i }), Field);
        }
    } else expectDocument(operation, argument ++ "[]", Item(T));
}

fn prefix(comptime operation: []const u8, comptime argument: []const u8) []const u8 {
    return "mongo.Collection." ++ operation ++ ": " ++ argument ++ ": ";
}

/// The tuple of a list that is one, or a pointer to one.
fn Tuple(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |info| if (info.size == .one and @typeInfo(info.child) == .@"struct") info.child else null,
        else => null,
    };
}

/// The type of the items of a list that is not a tuple.
fn Item(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            else => @typeInfo(info.child).array.child,
        },
        else => @compileError("not a list: " ++ @typeName(T)),
    };
}

/// The document `value`, of one of the three forms: a `RawDocument` or an
/// `OwnedDocument` as it is, borrowed; a struct as `bson.encode` writes it
/// into `arena`, nulls included. `error.InvalidBson`: the codec cannot
/// write it, such as for a string that is not UTF-8.
pub fn encode(arena: Allocator, value: anytype) bson.Builder.Error!bson.RawDocument {
    const T = @TypeOf(value);
    if (T == bson.RawDocument) return value;
    if (T == bson.OwnedDocument) return value.raw();
    return (try bson.encode(arena, value, .{})).raw();
}

/// The items of the list `value` as documents in `arena`: a slice of
/// `RawDocument`s as it is, any other list item by item as `encode` takes
/// them.
pub fn encodeList(arena: Allocator, value: anytype) bson.Builder.Error![]const bson.RawDocument {
    const T = @TypeOf(value);
    if (T == []const bson.RawDocument or T == []bson.RawDocument) return value;
    return mapItems(arena, value, arena, encodeItem);
}

fn encodeItem(arena: Allocator, _: usize, value: anytype) bson.Builder.Error!bson.RawDocument {
    return encode(arena, value);
}

/// The items of the list `value` (`.{}` is the empty one), each made a
/// document by `prepare(context, index, item)`, in a slice in `arena`.
/// Items of a tuple may be of different types: `prepare` takes any.
pub fn mapItems(arena: Allocator, value: anytype, context: anytype, comptime prepare: anytype) ![]const bson.RawDocument {
    const T = @TypeOf(value);
    if (comptime isEmptyTuple(T)) return &.{};
    if (comptime Tuple(T)) |Items| {
        const items: Items = if (@typeInfo(T) == .pointer) value.* else value;
        const names = @typeInfo(Items).@"struct".field_names;
        const docs = try arena.alloc(bson.RawDocument, names.len);
        inline for (names, 0..) |name, i| docs[i] = try prepare(context, i, @field(items, name));
        return docs;
    }
    const docs = try arena.alloc(bson.RawDocument, value.len);
    for (value, docs, 0..) |item, *doc, i| doc.* = try prepare(context, i, item);
    return docs;
}
