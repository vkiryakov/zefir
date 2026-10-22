//! The filters of models: anonymous literals that the compiler checks
//! against the model, written as the BSON of a MongoDB filter.
//!
//! ```zig
//! .{}                                                       // {}: every document
//! .{ .status = .active, .age = .{ .gte = 18, .lt = 65 } }   // {status: "active", age: {$gte: 18, $lt: 65}}
//! .{ .created_at = .{ .gte = since } }                      // {createdAt: {$gte: …}}: the key of names
//! .{ .profile = null }                                      // {profile: null}: null or no field
//! .{ .@"or" = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }
//! ```
//!
//! - The keys of a filter are the fields of the model and the logical
//!   operators `.@"and"`, `.@"or"` and `.nor`, each a tuple of one filter
//!   or more.
//! - The value of a field is a value, which the field equals, or a literal
//!   of operators: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `nin`,
//!   `exists`, `regex`, `not`. Which of them a field takes depends on its
//!   type (design §4.5). A literal of `eq` alone is the value itself.
//! - A value known at run time must fit the field without narrowing; a
//!   value known at compile time is checked itself: its range, its tag, its
//!   UTF-8 (query/values.zig). Either way it goes into BSON as a value of
//!   the field's type: a number for a `u32` field is an int64.
//! - null matches a field that is null or missing, so only a field that a
//!   document may lack takes it; `.{ .f = .{ .exists = false } }` matches a
//!   missing one only.
//!
//! A filter that breaks a rule stops the build with a message that starts
//! with "odm: " and names the model and the path (design §5.8).

const std = @import("std");
const bson = @import("mongo-bson");
const errors = @import("../errors.zig");
const schema = @import("../model/schema.zig");
const values = @import("values.zig");
const Allocator = std.mem.Allocator;
const Builder = bson.Builder;
const Unwrap = schema.Unwrap;

/// The BSON of `filter`, a filter of the model `T`, in `arena`: a literal
/// of the model's fields, or `.{}` for every document, which needs no
/// memory. `error.EncodeFailed`: a string is not UTF-8, or a regular
/// expression holds a NUL byte.
pub fn encode(comptime T: type, arena: Allocator, filter: anytype) errors.Error!bson.RawDocument {
    comptime schema.check(T);
    const L = @TypeOf(filter);
    comptime requireFilter(T, L);
    if (comptime @typeInfo(L).@"struct".field_names.len == 0) return bson.literal(.{});
    var b: Builder = .init(arena);
    defer b.deinit();
    writeFilter(T, &b, filter) catch |err| return encodeError(err);
    const doc = b.finish() catch |err| return encodeError(err);
    return doc.raw();
}

/// What writing a filter fails with: the builder's errors and a pattern
/// with a NUL byte.
pub const WriteError = Builder.Error || error{EncodeFailed};

fn encodeError(err: WriteError) errors.Error {
    return switch (err) {
        error.InvalidBson, error.EncodeFailed => error.EncodeFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Whether `L` is the type of a filter literal of `T`: a struct with named
/// fields, or `.{}`.
fn isFilter(comptime T: type, comptime L: type) bool {
    return switch (@typeInfo(L)) {
        .@"struct" => |info| (!info.is_tuple or info.field_names.len == 0) and L != T and !bson.codec.check.isSpecial(L),
        else => false,
    };
}

fn requireFilter(comptime T: type, comptime L: type) void {
    if (!isFilter(T, L)) @compileError("odm: a filter of " ++ @typeName(T) ++ " is a literal of its fields, or .{} for every document; got " ++ @typeName(L));
}

/// Where a condition stands: a path of the model's fields.
const At = struct {
    /// The model.
    T: type,
    /// The Zig names of the fields on the way, joined by '.', for the
    /// messages: "profile.city".
    path: []const u8,
    /// The key that the condition goes under in its document: the BSON
    /// path, such as "createdAt".
    key: []const u8,
    /// The type of the field, as declared.
    F: type,
    /// Whether a document may lack the field: it is optional, or a field on
    /// the way is.
    optional: bool,
};

/// "{M}.{path}", the subject of the messages about the field at `at`.
fn subject(comptime at: At) []const u8 {
    return @typeName(at.T) ++ "." ++ at.path;
}

/// Writes the fields of the filter literal `filter` of `T` into the
/// document open in `b`.
fn writeFilter(comptime T: type, b: *Builder, filter: anytype) WriteError!void {
    const L = @TypeOf(filter);
    inline for (@typeInfo(L).@"struct".field_names) |name| {
        if (comptime isLogical(name)) {
            try writeLogical(T, b, name, L, filter);
        } else {
            try writeCondition(b, comptime top(T, name), L, name, filter);
        }
    }
}

fn isLogical(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "and") or std.mem.eql(u8, name, "or") or std.mem.eql(u8, name, "nor");
}

/// The top-level field `name` of the model `T`.
fn top(comptime T: type, comptime name: []const u8) At {
    if (!@hasField(T, name)) @compileError("odm: " ++ @typeName(T) ++ " has no field '" ++ name ++ "'" ++ values.didYouMean(@typeInfo(T).@"struct".field_names, name));
    const F = @FieldType(T, name);
    return .{ .T = T, .path = name, .key = schema.keyOf(T, name), .F = F, .optional = @typeInfo(F) == .optional };
}

/// Writes `$and`, `$or` or `$nor`: the array of the filters in the tuple
/// `@field(parent, op)`.
fn writeLogical(comptime T: type, b: *Builder, comptime op: []const u8, comptime L: type, parent: L) WriteError!void {
    const V = @FieldType(L, op);
    comptime requireFilters(T, op, V);
    const filters = @field(parent, op);
    try b.beginArray("$" ++ op);
    inline for (@typeInfo(V).@"struct".field_names) |i| {
        try b.beginDocument("");
        try writeFilter(T, b, @field(filters, i));
        try b.end();
    }
    try b.end();
}

fn requireFilters(comptime T: type, comptime op: []const u8, comptime V: type) void {
    const M = @typeName(T);
    const takes = "odm: " ++ op ++ " takes a tuple of filters of " ++ M ++ ", such as .{ .{ .a = 1 }, .{ .b = 2 } }, or a []const odm.Filter(" ++ M ++ "); got " ++ @typeName(V);
    const info = switch (@typeInfo(V)) {
        .@"struct" => |info| if (info.is_tuple) info else @compileError(takes),
        else => @compileError(takes),
    };
    if (info.field_names.len == 0) @compileError("odm: " ++ op ++ " needs at least one filter");
    for (info.field_types) |Item| {
        if (!isFilter(T, Item)) @compileError(takes);
    }
}

/// Writes the condition `@field(parent, name)` on the field at `at`: an
/// equality, or the operators of a literal.
fn writeCondition(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const V = @FieldType(L, name);
    if (comptime values.isLiteral(V, Unwrap(at.F))) {
        comptime requireOperators(at, V);
        return writeOperatorsAt(b, at, V, @field(parent, name));
    }
    try writeEqualityAt(b, at, L, name, parent);
}

/// The operators of a filter, by their names in a literal.
const Op = enum { eq, ne, gt, gte, lt, lte, in, nin, exists, regex, not, all, size, elem_match };

fn operator(comptime name: []const u8) ?Op {
    return if (@hasField(Op, name)) @field(Op, name) else null;
}

/// The key of an operator in BSON.
fn keyOfOp(comptime op: Op) []const u8 {
    return switch (op) {
        .elem_match => "$elemMatch",
        else => "$" ++ @tagName(op),
    };
}

/// Stops the build unless every key of the literal `V` on the field at `at`
/// is an operator.
fn requireOperators(comptime at: At, comptime V: type) void {
    const keys = @typeInfo(V).@"struct".field_names;
    if (keys.len == 0) @compileError("odm: " ++ subject(at) ++ ": an empty literal matches nothing here; drop it");
    for (keys) |key| {
        if (operator(key) == null) @compileError("odm: unknown filter operator '" ++ key ++ "' on " ++ subject(at) ++ values.didYouMean(@typeInfo(Op).@"enum".field_names, key));
    }
}

/// Whether the operator `op` applies to a field of type `F`, by the table
/// of design §4.5.
fn applies(comptime op: Op, comptime F: type) bool {
    const S = Unwrap(F);
    return switch (op) {
        .eq, .ne, .exists => true,
        .gt, .gte, .lt, .lte => ordered(S),
        .in, .nin, .not => !equalsOnly(S) and !schema.isDocument(S),
        .regex => S == []const u8,
        .all, .size, .elem_match => false,
    };
}

/// Whether gt, gte, lt and lte compare the values of `S`: numbers, strings,
/// ObjectIds, dates and timestamps.
fn ordered(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .int, .float => true,
        else => S == []const u8 or S == bson.Decimal128 or S == bson.ObjectId or S == bson.DateTime or S == bson.Timestamp,
    };
}

/// Whether a filter takes only the equality of a field of type `S` and its
/// existence: a document or a value of any type as BSON gives it, a
/// regular expression, a min or max key.
fn equalsOnly(comptime S: type) bool {
    if (!bson.codec.check.isSpecial(S)) return false;
    return !(S == bson.Binary or S == bson.Decimal128 or S == bson.ObjectId or S == bson.DateTime or S == bson.Timestamp);
}

fn requireApplies(comptime at: At, comptime op: Op) void {
    if (!applies(op, at.F)) @compileError("odm: " ++ @tagName(op) ++ " does not apply to " ++ subject(at) ++ ", which is " ++ @typeName(at.F));
}

/// `X`, or `?X` when a document may lack the field at `at`: the type of a
/// value that the field equals, which null fits then.
fn nullable(comptime at: At, comptime X: type) type {
    return if (at.optional and @typeInfo(X) != .optional) ?X else X;
}

fn requireNull(comptime at: At) void {
    if (!at.optional) @compileError("odm: " ++ subject(at) ++ " is not optional: null matches no document");
}

/// The type of a value that the field at `at` equals (`eq`), or does not
/// (`ne`): `@field(L, name)`. Stops the build when the value does not fit.
fn equality(comptime at: At, comptime L: type, comptime name: []const u8, comptime op: []const u8) type {
    const X = nullable(at, at.F);
    if (@FieldType(L, name) == @TypeOf(null)) {
        requireNull(at);
        return X;
    }
    values.checkValue(op ++ " on", @typeName(at.T), at.path, X, L, name);
    return X;
}

/// Whether a value of `X` must go under `$eq`, never as `{f: value}`:
/// a document, or a value of any type, whose keys could be operators, and a
/// regular expression, which would match strings instead.
fn needsEq(comptime X: type) bool {
    const S = Unwrap(X);
    return S == bson.RawDocument or S == bson.OwnedDocument or S == bson.Value or S == bson.Regex;
}

/// Writes the equality of the field at `at` with `@field(parent, name)` as
/// `key: value`, or as `key: {$eq: value}` where `needsEq` says so.
fn writeEqualityAt(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const X = comptime equality(at, L, name, "eq");
    const value = @field(parent, name);
    if (comptime needsEq(X)) {
        try b.beginDocument(at.key);
        try values.writeValue(b, "$eq", X, value);
        return b.end();
    }
    try values.writeValue(b, at.key, X, value);
}

/// Writes the literal of operators `value` on the field at `at` under its
/// key: `key: {$gte: 18, $lt: 65}`, or `key: value` for `eq` alone.
fn writeOperatorsAt(b: *Builder, comptime at: At, comptime V: type, value: V) WriteError!void {
    const keys = @typeInfo(V).@"struct".field_names;
    if (keys.len == 1 and comptime std.mem.eql(u8, keys[0], "eq")) return writeEqualityAt(b, at, V, "eq", value);
    try b.beginDocument(at.key);
    try writeOperators(b, at, V, value);
    try b.end();
}

/// Writes the operators of the literal `value` on the field at `at` into
/// the document open in `b`: `$gte: 18`, `$in: [...]`.
fn writeOperators(b: *Builder, comptime at: At, comptime V: type, value: V) WriteError!void {
    const M = @typeName(at.T);
    inline for (@typeInfo(V).@"struct".field_names) |name| {
        const op = comptime operator(name).?;
        comptime requireApplies(at, op);
        const key = comptime keyOfOp(op);
        switch (op) {
            .eq, .ne => try values.writeValue(b, key, comptime equality(at, V, name, name), @field(value, name)),
            .gt, .gte, .lt, .lte => {
                const X = Unwrap(at.F);
                comptime values.checkValue(name ++ " on", M, at.path, X, V, name);
                try values.writeValue(b, key, X, @field(value, name));
            },
            .in, .nin => try writeIn(b, key, at, V, name, value),
            .exists => {
                comptime values.checkValue("exists on", M, at.path, bool, V, name);
                try values.writeValue(b, key, bool, @field(value, name));
            },
            .regex => try writeRegex(b, key, at, V, name, value),
            .not => try writeNot(b, at, V, name, value),
            .all, .size, .elem_match => comptime unreachable,
        }
    }
}

/// Writes `$in` or `$nin`: the array of the values in the tuple or the list
/// `@field(parent, name)`, each a value that the field equals.
fn writeIn(b: *Builder, comptime key: []const u8, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const X = comptime nullable(at, at.F);
    const O = @FieldType(L, name);
    comptime requireList(at, name, X, O, at.path);
    const list = @field(parent, name);
    try b.beginArray(key);
    if (comptime values.TupleOf(O)) |Tuple| {
        const items: Tuple = if (@typeInfo(O) == .pointer) list.* else list;
        inline for (@typeInfo(Tuple).@"struct".field_names) |i| try values.writeValue(b, "", X, @field(items, i));
    } else {
        for (list) |item| try values.writeValue(b, "", X, item);
    }
    try b.end();
}

/// Stops the build unless `O` is a list of values of `X`: a tuple, checked
/// item by item with `path` in the messages, or a slice or an array that
/// fits `[]const X`.
fn requireList(comptime at: At, comptime op: []const u8, comptime X: type, comptime O: type, comptime path: []const u8) void {
    const M = @typeName(at.T);
    if (values.TupleOf(O)) |Tuple| {
        for (@typeInfo(Tuple).@"struct".field_names) |i| {
            if (@FieldType(Tuple, i) == @TypeOf(null)) {
                if (@typeInfo(X) != .optional) @compileError("odm: " ++ M ++ "." ++ path ++ " is not optional: null matches no document");
            } else values.checkValue(op ++ " on", M, path, X, Tuple, i);
        }
    } else if (!values.isList(O) or !values.fits(O, []const X)) values.typeError(op ++ " on", M, at.path, []const X, O);
}

/// Writes `$regex`: a pattern, or a `bson.Regex` with its options.
fn writeRegex(b: *Builder, comptime key: []const u8, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const pattern = @field(parent, name);
    if (@FieldType(L, name) == bson.Regex) return b.putRegex(key, pattern);
    comptime values.checkValue("regex on", @typeName(at.T), at.path, []const u8, L, name);
    const text: []const u8 = pattern;
    // The server takes no NUL byte in a pattern.
    if (std.mem.findScalar(u8, text, 0) != null) return error.EncodeFailed;
    try b.putString(key, text);
}

/// Writes `$not`: a literal of operators on the same field, or a
/// `bson.Regex` that the field must not match.
fn writeNot(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const O = @FieldType(L, name);
    const operand = @field(parent, name);
    if (O == bson.Regex) {
        comptime requireApplies(at, .regex);
        return b.putRegex("$not", operand);
    }
    if (comptime !values.isLiteral(O, Unwrap(at.F))) {
        @compileError("odm: not on " ++ subject(at) ++ " takes a literal of operators, such as .{ .gt = 5 }, or a bson.Regex; got " ++ @typeName(O));
    }
    comptime requireOperators(at, O);
    try b.beginDocument("$not");
    try writeOperators(b, at, O, operand);
    try b.end();
}
