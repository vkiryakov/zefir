//! The options of reads. `find` and `findOne` take a literal of options;
//! its sort is a literal of paths in the order of its keys, as a typed
//! struct could not keep them; a projection comes from the type of the
//! result, never from a list of names.
//!
//! ```zig
//! .{ .sort = .{ .status = .asc, .created_at = .desc }, .skip = 20, .limit = 10 }
//! .{ .sort = .{ .profile = .{ .city = .asc } } }  // {"profile.city": 1}
//! const UserPreview = struct { name: []const u8, email: []const u8 }; // {name: 1, email: 1, _id: 0}
//! ```

const std = @import("std");
const bson = @import("mongo-bson");
const errors = @import("../errors.zig");
const schema = @import("../model/schema.zig");
const values = @import("values.zig");
const Allocator = std.mem.Allocator;
const Builder = bson.Builder;
const Unwrap = schema.Unwrap;
const At = values.At;

/// The order of a key of a sort.
pub const Direction = enum { asc, desc };

/// The options of a find as the driver contract takes them; the defaults
/// are no sort, no skip, no limit (0) and the driver's batch size.
pub const Find = struct {
    sort: ?bson.RawDocument = null,
    skip: u32 = 0,
    limit: u32 = 0,
    batch_size: ?u32 = null,
};

/// The options of `op` from the literal `options`: `sort`, `skip`, `limit`
/// and `batch_size` for find, `sort` and `skip` for findOne. A count is a
/// `u32`, known at compile time or at run time, and a `?u32` that is null
/// leaves it unset; the sort is that of `sort`, in `arena`, and `.{}` is no
/// sort.
pub fn find(comptime T: type, comptime op: enum { find, findOne }, arena: Allocator, options: anytype) errors.Error!Find {
    comptime schema.check(T);
    const L = @TypeOf(options);
    comptime requireOptions(@tagName(op), L);
    var out: Find = .{};
    inline for (@typeInfo(L).@"struct".field_names) |name| {
        const value = @field(options, name);
        if (comptime std.mem.eql(u8, name, "sort")) {
            if (comptime !isEmpty(@TypeOf(value))) out.sort = try sort(T, arena, value);
        } else if (comptime std.mem.eql(u8, name, "batch_size")) {
            out.batch_size = count(value);
        } else {
            @field(out, name) = count(value) orelse 0;
        }
    }
    return out;
}

/// Whether `V` is the type of `.{}`.
fn isEmpty(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .@"struct" => |info| info.field_names.len == 0,
        else => false,
    };
}

fn requireOptions(comptime op: []const u8, comptime L: type) void {
    const names: []const [:0]const u8 = if (std.mem.eql(u8, op, "find")) &.{ "sort", "skip", "limit", "batch_size" } else &.{ "sort", "skip" };
    const literal = switch (@typeInfo(L)) {
        .@"struct" => |info| !info.is_tuple or info.field_names.len == 0,
        else => false,
    };
    if (!literal) @compileError("odm: the options of " ++ op ++ " are a literal, such as .{ .skip = 10 }; got " ++ @typeName(L));
    for (@typeInfo(L).@"struct".field_names) |name| {
        for (names) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else @compileError("odm: " ++ op ++ " has no option '" ++ name ++ "'" ++ values.didYouMean(names, name));
        if (!std.mem.eql(u8, name, "sort")) requireCount(L, name);
    }
}

/// Stops the build unless the option `name` of `L` is a count: a `u32`,
/// or a `?u32` whose null leaves it unset.
fn requireCount(comptime L: type, comptime name: []const u8) void {
    const V = @FieldType(L, name);
    const is_a = "odm: " ++ name ++ " is a u32; got " ++ @typeName(V);
    if (values.isComptime(L, name)) {
        if (!values.comptimeFits(V, ?u32)) @compileError(is_a);
        if (values.comptimeProblem(?u32, values.comptimeValue(L, name))) |problem| @compileError("odm: " ++ name ++ " " ++ problem);
    } else if (!values.fits(V, ?u32)) @compileError(is_a);
}

/// A count that `requireCount` took, or null when it is unset.
fn count(value: anytype) ?u32 {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return null;
    if (@typeInfo(V) == .optional) return if (value) |n| count(n) else null;
    // A typed integer known at compile time may be wider than u32; its
    // value fits, as the check saw.
    return if (@typeInfo(V) == .int) @intCast(value) else value;
}

/// The sort document of `keys`, a literal of the paths of `T` whose values
/// are `.asc` or `.desc`, or a `Direction` known at run time, in the order
/// of its keys: `.{ .status = .asc, .created_at = .desc }` is `{status: 1,
/// createdAt: -1}`. A struct, or a list of structs, takes a literal of the
/// paths of its fields: `.{ .profile = .{ .city = .asc } }`. `.{}` is the
/// empty document, which needs no memory.
pub fn sort(comptime T: type, arena: Allocator, keys: anytype) errors.Error!bson.RawDocument {
    comptime schema.check(T);
    const L = @TypeOf(keys);
    comptime requireSort(T, L);
    if (comptime isEmpty(L)) return bson.literal(.{});
    var b: Builder = .init(arena);
    defer b.deinit();
    writeSort(&b, T, null, L, keys) catch |err| return encodeError(err);
    const doc = b.finish() catch |err| return encodeError(err);
    return doc.raw();
}

fn requireSort(comptime T: type, comptime L: type) void {
    const literal = switch (@typeInfo(L)) {
        .@"struct" => |info| !info.is_tuple or info.field_names.len == 0,
        else => false,
    };
    if (!literal) @compileError("odm: a sort of " ++ @typeName(T) ++ " is a literal of its fields with .asc or .desc; got " ++ @typeName(L));
}

fn encodeError(err: Builder.Error) errors.Error {
    return switch (err) {
        error.InvalidBson => error.EncodeFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Writes the keys of the sort literal `keys`, on the top-level fields of
/// `T` when `at` is null, else on the fields of the struct of the field at
/// `at`.
fn writeSort(b: *Builder, comptime T: type, comptime at: ?At, comptime L: type, keys: L) Builder.Error!void {
    inline for (@typeInfo(L).@"struct".field_names) |name| {
        const where = comptime if (at) |outer| values.field(outer, name) else values.top(T, name);
        const V = @FieldType(L, name);
        const value = @field(keys, name);
        if (comptime nested(where, V)) {
            try writeSort(b, T, where, V, value);
        } else {
            comptime requireDirection(where, L, name);
            const direction: Direction = value;
            try b.putInt32(where.key, if (direction == .asc) 1 else -1);
        }
    }
}

/// Whether the value of a key of a sort is a literal of the paths of the
/// struct at `at`, not a direction.
fn nested(comptime at: At, comptime V: type) bool {
    const S = values.Fields(at.F) orelse return false;
    return values.isLiteral(V, S) and @typeInfo(V).@"struct".field_names.len > 0;
}

fn requireDirection(comptime at: At, comptime L: type, comptime name: []const u8) void {
    const V = @FieldType(L, name);
    if (V == Direction) return;
    const got = if (@typeInfo(V) == .enum_literal and values.isComptime(L, name)) got: {
        const tag = @tagName(values.comptimeValue(L, name));
        if (std.mem.eql(u8, tag, "asc") or std.mem.eql(u8, tag, "desc")) return;
        break :got "." ++ tag;
    } else @typeName(V);
    @compileError("odm: sort of " ++ values.subject(at) ++ " takes .asc or .desc; got " ++ got);
}

/// The projection of `P`, the type of the result of a read of `T`: each
/// field of `P` is a field of `T` of the same type or its optional, and a
/// struct of another type, or a list of them, a projection of the struct of
/// `T` there, by the same rules: `struct { name: []const u8, profile:
/// ?struct { city: []const u8 } }` is `{name: 1, "profile.city": 1, _id:
/// 0}`. Without the id in `P`, `_id: 0` keeps it out. The id is never
/// missing, so `P` may take it as required.
pub fn projection(comptime T: type, comptime P: type, arena: Allocator) errors.Error!bson.RawDocument {
    comptime schema.check(T);
    const keys = comptime projected(T, P);
    var b: Builder = .init(arena);
    defer b.deinit();
    inline for (keys) |key| b.putInt32(key, 1) catch |err| return encodeError(err);
    if (comptime !@hasField(P, schema.idName(T))) b.putInt32("_id", 0) catch |err| return encodeError(err);
    const doc = b.finish() catch |err| return encodeError(err);
    return doc.raw();
}

/// The BSON keys of the fields of `P`, a projection of `T`, after its
/// checks.
fn projected(comptime T: type, comptime P: type) []const []const u8 {
    comptime {
        @setEvalBranchQuota(schema.eval_quota);
        if (!schema.isDocument(P)) @compileError("odm: a projection of " ++ @typeName(T) ++ " is a struct of fields of " ++ @typeName(T) ++ "; got " ++ @typeName(P));
        return projectFields(T, @typeName(P), P, T, "", "");
    }
}

/// The keys of `Q`, the struct at `path` (`""` for the whole) of the
/// projection named `P`, on `S`, the struct of the model `T` at the same
/// path, whose key is `key`.
fn projectFields(comptime T: type, comptime P: []const u8, comptime Q: type, comptime S: type, comptime path: []const u8, comptime key: []const u8) []const []const u8 {
    const M = @typeName(T);
    var out: []const []const u8 = &.{};
    for (@typeInfo(Q).@"struct".field_names, @typeInfo(Q).@"struct".field_types) |name, QF| {
        const where = if (path.len == 0) name else path ++ "." ++ name;
        const of = if (path.len == 0) M else M ++ "." ++ path;
        if (!@hasField(S, name)) @compileError("odm: " ++ P ++ "." ++ where ++ " is not a field of " ++ of ++ values.didYouMean(@typeInfo(S).@"struct".field_names, name));
        const MF = @FieldType(S, name);
        const sub = if (path.len == 0) schema.keyOf(T, name) else key ++ "." ++ name;
        const is_id = path.len == 0 and std.mem.eql(u8, name, schema.idName(T));
        const optional = @typeInfo(MF) == .optional and !is_id;
        if (optional and @typeInfo(QF) != .optional) {
            if (QF == Unwrap(MF) or itemsOf(QF, MF) != null) {
                @compileError("odm: " ++ P ++ "." ++ where ++ " is required, but " ++ M ++ "." ++ where ++ " is optional: make it ?" ++ @typeName(QF));
            }
        }
        if (Unwrap(QF) == Unwrap(MF)) {
            out = out ++ &[_][]const u8{sub};
        } else if (itemsOf(QF, MF)) |pair| {
            out = out ++ projectFields(T, P, pair[0], pair[1], where, sub);
        } else {
            @compileError("odm: " ++ P ++ "." ++ where ++ " is " ++ @typeName(QF) ++ ", but " ++ M ++ "." ++ where ++ " is " ++ @typeName(MF) ++ ": a projection field has the type of the model's field or its optional");
        }
    }
    return out;
}

/// The structs of a nested projection: `QF` and `MF`, without their
/// optionals, are structs of two types, or slices of them.
fn itemsOf(comptime QF: type, comptime MF: type) ?struct { type, type } {
    const Q = Unwrap(QF);
    const S = Unwrap(MF);
    if (schema.isDocument(Q) and schema.isDocument(S)) return .{ Q, S };
    const QI = sliceItem(Q) orelse return null;
    const SI = sliceItem(S) orelse return null;
    if (schema.isDocument(QI) and schema.isDocument(SI) and QI != SI) return .{ QI, SI };
    return null;
}

fn sliceItem(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .slice) info.child else null,
        else => null,
    };
}
