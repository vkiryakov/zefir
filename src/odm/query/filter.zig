//! The filters of models: anonymous literals that the compiler checks
//! against the model, written as the BSON of a MongoDB filter.
//!
//! ```zig
//! .{}                                                       // {}: every document
//! .{ .status = .active, .age = .{ .gte = 18, .lt = 65 } }   // {status: "active", age: {$gte: 18, $lt: 65}}
//! .{ .created_at = .{ .gte = since } }                      // {createdAt: {$gte: …}}: the key of names
//! .{ .profile = null }                                      // {profile: null}: null or no field
//! .{ .profile = .{ .city = "Paris" } }                      // {"profile.city": "Paris"}: a path
//! .{ .profile = .{ .eq = p } }                              // {profile: {city: …, country: …}}: whole
//! .{ .tags = "admin" }                                      // {tags: "admin"}: an item of the list
//! .{ .items = .{ .elem_match = .{ .sku = "x", .qty = .{ .gt = 5 } } } }
//! .{ .@"or" = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }
//! ```
//!
//! - The keys of a filter are the fields of the model and the logical
//!   operators `.@"and"`, `.@"or"` and `.nor`, each a tuple of one filter
//!   or more.
//! - The value of a field is a value, which the field equals, or a literal
//!   of operators: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `nin`,
//!   `exists`, `regex`, `not`, and for lists `all`, `size`, `elem_match`.
//!   Which of them a field takes depends on its type (design §4.5). A
//!   literal of `eq` alone is the value itself.
//! - A literal on a struct, or on a list of structs, whose keys are fields
//!   of the struct is conditions on their paths, never the match of a whole
//!   document: that takes `.eq`, and a value of the struct without it does
//!   not compile (design §5.9). A whole document is written in the order of
//!   its fields, without its null optionals, as the documents of odm are.
//! - A value of a list field is an item that the list holds; the whole list
//!   takes `.eq`, all its items `.all`.
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
const schema = @import("../model/schema.zig");
const values = @import("values.zig");
const Allocator = std.mem.Allocator;
const Builder = bson.Builder;
const Unwrap = schema.Unwrap;
const At = values.At;
const subject = values.subject;
const top = values.top;
const inner = values.inner;
const Fields = values.Fields;
const ItemOf = values.ItemOf;

/// The BSON of `filter`, a filter of the model `T`, in `arena`: a literal
/// of the model's fields, or `.{}` for every document, which needs no
/// memory. `error.EncodeFailed`: a string is not UTF-8, or a regular
/// expression holds a NUL byte.
pub fn encode(comptime T: type, arena: Allocator, filter: anytype) EncodeError!bson.RawDocument {
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

/// What encoding a filter or an update fails with, all of it before
/// anything is sent: a value that BSON cannot hold, a request that breaks a
/// rule of odm, no memory.
pub const EncodeError = error{ EncodeFailed, InvalidArgument, OutOfMemory };

/// The error of an encoder, from the error of its writing.
pub fn encodeError(err: WriteError) EncodeError {
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

/// Stops the build unless `L` is the type of a filter literal of `T`.
pub fn requireFilter(comptime T: type, comptime L: type) void {
    if (!isFilter(T, L)) @compileError("odm: a filter of " ++ @typeName(T) ++ " is a literal of its fields, or .{} for every document; got " ++ @typeName(L));
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

/// Whether `name` is a logical operator of a filter: and, or, nor.
pub fn isLogical(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "and") or std.mem.eql(u8, name, "or") or std.mem.eql(u8, name, "nor");
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
/// equality, the conditions on the paths of a literal of fields, or the
/// operators of a literal of operators.
fn writeCondition(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const V = @FieldType(L, name);
    if (comptime isConditions(at, V)) {
        return switch (comptime classify(at, V)) {
            .paths => writePaths(b, at, V, @field(parent, name)),
            .operators => writeOperatorsAt(b, at, V, @field(parent, name)),
        };
    }
    try writeEqualityAt(b, at, L, name, parent, true);
}

/// Whether a value of `V` on the field at `at` is a literal of conditions,
/// which `classify` tells apart, and not a value that the field equals. A
/// value of the items of a list is an item to match, not a literal.
pub fn isConditions(comptime at: At, comptime V: type) bool {
    return values.isLiteral(V, Unwrap(at.F)) and if (ItemOf(at)) |Item| values.isLiteral(V, Unwrap(Item)) else true;
}

/// What a literal on the field at `at` is (design §5.9).
pub const Kind = enum {
    /// All its keys are fields of the struct of the field, or of its items:
    /// conditions on their paths.
    paths,
    /// None is: operators of the field itself.
    operators,
};

/// What the literal of conditions `V` on the field at `at` is. Stops the
/// build at an empty literal, at a key that is neither a field nor an
/// operator, and at a literal of both.
pub fn classify(comptime at: At, comptime V: type) Kind {
    const keys = @typeInfo(V).@"struct".field_names;
    if (keys.len == 0) @compileError("odm: " ++ subject(at) ++ ": an empty literal matches nothing here; drop it");
    const S = Fields(at.F);
    var paths = false;
    var operators = false;
    for (keys) |key| {
        const is_field = if (S) |Struct| @hasField(Struct, key) else false;
        const is_operator = operator(key) != null;
        if (is_field and is_operator) @compileError("odm: " ++ subject(at) ++ ": '" ++ key ++ "' is both a field of " ++ @typeName(S.?) ++ " and an operator: rename the field");
        if (!is_field and !is_operator) unknownKey(at, S, key);
        if (is_field) paths = true else operators = true;
    }
    if (paths and operators) @compileError("odm: " ++ subject(at) ++ ": write either fields of " ++ @typeName(S.?) ++ " or operators in one literal, not both");
    return if (paths) .paths else .operators;
}

/// Stops the build at a key that is neither a field of `S` nor an
/// operator, naming the field or the operator it is nearest to.
fn unknownKey(comptime at: At, comptime S: ?type, comptime key: []const u8) noreturn {
    const operators = @typeInfo(Op).@"enum".field_names;
    if (S) |Struct| {
        const field = values.didYouMean(@typeInfo(Struct).@"struct".field_names, key);
        if (field.len > 0 or values.didYouMean(operators, key).len == 0) @compileError("odm: " ++ subject(at) ++ " has no field '" ++ key ++ "'" ++ field);
    }
    @compileError("odm: unknown filter operator '" ++ key ++ "' on " ++ subject(at) ++ values.didYouMean(operators, key));
}

/// Writes the conditions of the literal `value` on the paths of the fields
/// of the struct of the field at `at`: `"profile.city": "Paris"`.
fn writePaths(b: *Builder, comptime at: At, comptime V: type, value: V) WriteError!void {
    const S = comptime Fields(at.F).?;
    inline for (@typeInfo(V).@"struct".field_names) |name| {
        try writeCondition(b, comptime inner(at, S, name), V, name, value);
    }
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
/// of design §4.5. On a list, gt, gte, lt, lte and regex compare its items,
/// so they apply when they apply to the items.
fn applies(comptime op: Op, comptime F: type) bool {
    const S = Unwrap(F);
    if (schema.ListItem(S)) |Item| return switch (op) {
        .gt, .gte, .lt, .lte, .regex => applies(op, Item),
        else => true,
    };
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

/// Stops the build at a null that the field at `at` never equals: a
/// document always has the field, and it is not a list that holds nulls.
fn requireNull(comptime at: At) void {
    if (at.optional) return;
    if (ItemOf(at)) |Item| if (@typeInfo(Item) == .optional) return;
    @compileError("odm: " ++ subject(at) ++ " is not optional: null matches no document");
}

/// The type of the value `@field(L, name)` that the field at `at` equals
/// (`eq`), or does not (`ne`), which `implicit` says stands without `.eq`:
/// a value of the field; for a list an item, or the whole list with `.eq`;
/// for a struct the whole document with `.eq`. Stops the build when the
/// value does not fit.
fn equality(comptime at: At, comptime L: type, comptime name: []const u8, comptime op: []const u8, comptime implicit: bool) type {
    const M = @typeName(at.T);
    const V = @FieldType(L, name);
    const what = op ++ " on";
    if (V == @TypeOf(null)) {
        requireNull(at);
        return nullable(at, at.F);
    }
    const S = Unwrap(at.F);
    if (schema.isDocument(S) and implicit) {
        const first = @typeInfo(S).@"struct".field_names[0];
        const last = if (std.mem.findScalarLast(u8, at.path, '.')) |dot| at.path[dot + 1 ..] else at.path;
        @compileError("odm: " ++ subject(at) ++ " is a document: match its fields, .{ ." ++ last ++ " = .{ ." ++ first ++ " = ... } }, or the whole document with .{ .eq = value }");
    }
    if (ItemOf(at)) |Item| {
        const E = nullable(at, Item);
        const item = if (values.isComptime(L, name)) values.comptimeFits(V, E) else values.fits(V, E);
        if (item or !values.isList(V)) {
            values.checkValue(what, M, at.path ++ "[]", E, L, name);
            return E;
        }
        if (implicit) @compileError("odm: " ++ subject(at) ++ " is a list: match an item with an item, all items with .all, the whole list with .eq");
    }
    const X = nullable(at, at.F);
    values.checkValue(what, M, at.path, X, L, name);
    return X;
}

/// Whether a value of `X` must go under `$eq`, never as `{f: value}`:
/// a document, or a value of any type, whose keys could be operators, and a
/// regular expression, which would match strings instead.
pub fn needsEq(comptime X: type) bool {
    const S = Unwrap(X);
    return S == bson.RawDocument or S == bson.OwnedDocument or S == bson.Value or S == bson.Regex;
}

/// Writes the equality of the field at `at` with `@field(parent, name)` as
/// `key: value`, or as `key: {$eq: value}` where `needsEq` says so;
/// `implicit` when the value stands without `.eq`.
fn writeEqualityAt(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L, comptime implicit: bool) WriteError!void {
    const X = comptime equality(at, L, name, "eq", implicit);
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
    if (keys.len == 1 and comptime std.mem.eql(u8, keys[0], "eq")) return writeEqualityAt(b, at, V, "eq", value, false);
    try b.beginDocument(at.key);
    try writeOperators(b, at, V, value);
    try b.end();
}

/// The type of the values that gt, gte, lt, lte, in and nin compare the
/// field at `at` with — the field's own, or its items' for a list — and the
/// path that names them in the messages.
fn compared(comptime at: At) struct { type, []const u8 } {
    if (ItemOf(at)) |Item| return .{ Item, at.path ++ "[]" };
    return .{ at.F, at.path };
}

/// Writes the operators of the literal `value` on the field at `at` into
/// the document open in `b`: `$gte: 18`, `$in: [...]`.
fn writeOperators(b: *Builder, comptime at: At, comptime V: type, value: V) WriteError!void {
    const M = @typeName(at.T);
    const X, const path = comptime compared(at);
    inline for (@typeInfo(V).@"struct".field_names) |name| {
        const op = comptime operator(name).?;
        comptime requireApplies(at, op);
        const key = comptime keyOfOp(op);
        switch (op) {
            .eq, .ne => try values.writeValue(b, key, comptime equality(at, V, name, name, false), @field(value, name)),
            .gt, .gte, .lt, .lte => {
                comptime values.checkValue(name ++ " on", M, path, Unwrap(X), V, name);
                try values.writeValue(b, key, Unwrap(X), @field(value, name));
            },
            .in, .nin => try writeList(b, key, at, comptime nullable(at, X), path, V, name, value),
            .all => try writeList(b, key, at, X, path, V, name, value),
            .exists => {
                comptime values.checkValue("exists on", M, at.path, bool, V, name);
                try values.writeValue(b, key, bool, @field(value, name));
            },
            .size => {
                comptime values.checkValue("size on", M, at.path, u32, V, name);
                try values.writeValue(b, key, i64, @field(value, name));
            },
            .regex => try writeRegex(b, key, at, V, name, value),
            .not => try writeNot(b, at, V, name, value),
            .elem_match => try writeElemMatch(b, at, V, name, value),
        }
    }
}

/// Writes `$in`, `$nin` or `$all`: the array of the values of `X` in the
/// tuple or the list `@field(parent, name)`.
fn writeList(b: *Builder, comptime key: []const u8, comptime at: At, comptime X: type, comptime path: []const u8, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const O = @FieldType(L, name);
    comptime requireList(at, name, X, path, O);
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
fn requireList(comptime at: At, comptime op: []const u8, comptime X: type, comptime path: []const u8, comptime O: type) void {
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

/// Writes `$elemMatch`: conditions that one item of the list at `at` meets
/// together (`writeItemConditions`).
fn writeElemMatch(b: *Builder, comptime at: At, comptime L: type, comptime name: []const u8, parent: L) WriteError!void {
    const O = @FieldType(L, name);
    if (comptime !values.isLiteral(O, Unwrap(ItemOf(at).?))) {
        @compileError("odm: elem_match on " ++ subject(at) ++ " takes a literal of conditions on the items of the list; got " ++ @typeName(O));
    }
    try b.beginDocument("$elemMatch");
    try writeItemConditions(b, at, O, @field(parent, name));
    try b.end();
}

/// Writes the literal `conditions` on one item of the list at `at` into the
/// document open in `b`: the fields of a struct item, or operators on an
/// item of values. Their keys are those of the item, and the messages name
/// it with "[]": "items[].sku". They are the operand of `$elemMatch`, and of
/// `$pull` in an update.
pub fn writeItemConditions(b: *Builder, comptime at: At, comptime O: type, conditions: O) WriteError!void {
    const Item = comptime ItemOf(at).?;
    const item: At = .{ .T = at.T, .path = at.path ++ "[]", .key = "", .F = Item, .optional = @typeInfo(Item) == .optional };
    switch (comptime classify(item, O)) {
        .paths => try writePaths(b, item, O, conditions),
        .operators => try writeOperators(b, item, O, conditions),
    }
}
