//! The updates of models: anonymous literals of operators that the
//! compiler checks against the model, written as the BSON of a MongoDB
//! update.
//!
//! ```zig
//! .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } }  // {$set: {status: "blocked"}, $inc: {age: 1}}
//! .{ .set = .{ .address = .{ .city = "Lyon" } } }            // {$set: {"address.city": "Lyon"}}: a path
//! .{ .set = .{ .profile = profile } }                        // {$set: {profile: {…}}}: the whole struct
//! .{ .unset = .{ .profile, .@"address.zip" } }               // {$unset: {profile: "", "address.zip": ""}}
//! .{ .push = .{ .tags = "new" } }                            // {$push: {tags: "new"}}
//! .{ .add_to_set = .{ .tags = .{ .each = &.{ "a", "b" } } } }
//! .{ .pull = .{ .items = .{ .qty = .{ .lt = 1 } } } }        // the items that meet the conditions
//! .{ .pop = .{ .tags = .last } }                             // {$pop: {tags: 1}}
//! .{ .set_on_insert = .{ .status = .active } }               // only in upsertOne
//! ```
//!
//! - `set` and `set_on_insert` take a value of the field. odm stores no
//!   null: an optional takes a value of its child, and `unset` clears it.
//!   A literal on a struct is paths into it. A path into an optional struct
//!   does not compile: in a document without the struct it would make an
//!   incomplete one, so set the whole struct, or unset it.
//! - `unset` takes a tuple of paths: optionals, and fields with a default
//!   value, which a document without them reads back.
//! - `inc` and `mul` take a number; for an integer field an integer that
//!   fits its BSON integer, negative too. `min` and `max` take a value of a
//!   field of numbers, strings, `bson.DateTime` or `bson.ObjectId`.
//! - `push` and `add_to_set` take an item of a list, or `.{ .each = items }`;
//!   `pull` an item, or conditions on the items as `elem_match` takes them;
//!   `pop` `.first` or `.last`. These and the operators of numbers take
//!   optional fields too: on a document without the field the server makes
//!   it, or does nothing for `pull` and `pop`. An array of a fixed length,
//!   `[N]E`, takes none of the four: they would change its length, and
//!   `set` changes it whole.
//! - An update never changes the id; `set_on_insert` gives it when an
//!   upsert inserts. A path changes once in an update, and no path changed
//!   holds another one changed (`address` and `address.zip`).
//! - A value known at run time must fit the field without narrowing; a
//!   value known at compile time is checked itself (query/values.zig).
//!   Documents in values are written without their null optionals.
//!
//! An update that breaks a rule stops the build with a message that starts
//! with "odm: " and names the model and the path (design §5.8).
//! `odm.Update(T)` builds an update at run time from such literals.

const std = @import("std");
const bson = @import("mongo-bson");
const schema = @import("../model/schema.zig");
const values = @import("values.zig");
const filter = @import("filter.zig");
const Allocator = std.mem.Allocator;
const Builder = bson.Builder;
const Unwrap = schema.Unwrap;
const At = values.At;
const subject = values.subject;

/// What an update is for: `set_on_insert` works only in an upsert.
pub const Use = enum { update, upsert };

/// The BSON of `update`, an update literal of the model `T` or an
/// `odm.Update(T)`, in `arena`. `error.EncodeFailed`: a string is not
/// UTF-8, or a regular expression of `pull` holds a NUL byte. An
/// `odm.Update(T)` gives the first error of its `with` calls, and
/// `error.InvalidArgument` when it has none, or when two of them change one
/// path or two paths of which one holds the other.
pub fn encode(comptime T: type, arena: Allocator, update: anytype, comptime use: Use) filter.EncodeError!bson.RawDocument {
    comptime schema.check(T);
    const U = @TypeOf(update);
    if (comptime isBuilt(U)) {
        if (comptime U.odm_update_model != T) @compileError("odm: this update is an odm.Update(" ++ @typeName(U.odm_update_model) ++ "), not of " ++ @typeName(T));
        return encodeBuilt(arena, update);
    }
    const changes = comptime analyze(T, U, use);
    var b: Builder = .init(arena);
    defer b.deinit();
    writeUpdate(&b, U, changes, update) catch |err| return filter.encodeError(err);
    const doc = b.finish() catch |err| return filter.encodeError(err);
    return doc.raw();
}

/// The operators of an update, by their names in a literal.
const Op = enum { set, set_on_insert, unset, inc, mul, min, max, push, add_to_set, pull, pop };

fn operator(comptime name: []const u8) ?Op {
    return if (@hasField(Op, name)) @field(Op, name) else null;
}

/// The key of an operator in BSON.
fn keyOfOp(comptime op: Op) []const u8 {
    return switch (op) {
        .set_on_insert => "$setOnInsert",
        .add_to_set => "$addToSet",
        else => "$" ++ @tagName(op),
    };
}

/// Whether `op` makes the field it changes in a document that lacks it:
/// all but `unset`, `pull` and `pop`.
fn creates(comptime op: Op) bool {
    return switch (op) {
        .unset, .pull, .pop => false,
        else => true,
    };
}

/// One change of an update literal: an operator on the field at a path.
const Change = struct {
    op: Op,
    /// The field.
    at: At,
    /// The names of the fields of the operator's literal on the way to the
    /// value: `.{ "address", "city" }`.
    names: []const []const u8,
    /// How the value goes into BSON.
    write: Write,
};

const Write = union(enum) {
    /// The value, as a value of this type: `set`, `set_on_insert`, `min`,
    /// `max`, `inc` and `mul`.
    value: type,
    /// `""`: `unset`.
    unset,
    /// One item of the list, of this type: `push` and `add_to_set`.
    item: type,
    /// `{$each: [...]}` of the items of this type: `push` and `add_to_set`.
    each: type,
    /// An item of this type that `pull` takes out. A document goes under
    /// `$eq`, so that the items equal to it go, and not the items that only
    /// hold its fields; so do the values that a filter writes under `$eq`.
    pull_item: type,
    /// The conditions on the items that `pull` takes out.
    pull_conditions,
    /// `pop`: -1 for `.first`, 1 for `.last`.
    pop: i32,
};

/// The changes of the update literal `U` of `T`, after every check of
/// design §5.8 "Updates": the operators and their fields, the values, the
/// id, and the paths, none changed twice and none inside another one.
fn analyze(comptime T: type, comptime U: type, comptime use: Use) []const Change {
    comptime {
        @setEvalBranchQuota(schema.eval_quota);
        const M = @typeName(T);
        if (!isStructLiteral(U) or U == T or isBuilt(U)) @compileError("odm: an update of " ++ M ++ " is a literal of operators, such as .{ .set = .{ .name = value } }; got " ++ @typeName(U));
        const ops = @typeInfo(U).@"struct".field_names;
        if (ops.len == 0) @compileError("odm: the update of " ++ M ++ " changes nothing");
        var out: []const Change = &.{};
        for (ops) |name| {
            const op = operator(name) orelse @compileError("odm: unknown update operator '" ++ name ++ "'" ++ values.didYouMean(@typeInfo(Op).@"enum".field_names, name));
            if (op == .set_on_insert and use != .upsert) @compileError("odm: set_on_insert works only in upsertOne");
            const L = @FieldType(U, name);
            out = out ++ if (op == .unset) unsets(T, L) else fields(T, op, L);
        }
        requireDistinct(out);
        return out;
    }
}

/// Whether `V` is a struct literal: one with named fields, or `.{}`.
fn isStructLiteral(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .@"struct" => |info| (!info.is_tuple or info.field_names.len == 0) and !bson.codec.check.isSpecial(V),
        else => false,
    };
}

/// The changes of `op`, whose literal of the fields of `T` is `L`.
fn fields(comptime T: type, comptime op: Op, comptime L: type) []const Change {
    const M = @typeName(T);
    if (!isStructLiteral(L)) @compileError("odm: " ++ @tagName(op) ++ " takes a literal of the fields of " ++ M ++ "; got " ++ @typeName(L));
    const names = @typeInfo(L).@"struct".field_names;
    if (names.len == 0) @compileError("odm: " ++ @tagName(op) ++ " in the update of " ++ M ++ " is empty");
    var out: []const Change = &.{};
    for (names) |name| {
        const at = values.top(T, name);
        if (op != .set_on_insert) requireNotId(at);
        out = out ++ changesAt(op, at, null, L, name, &.{name});
    }
    return out;
}

/// Stops the build at the id of the model: an update cannot change the
/// `_id` of a document.
fn requireNotId(comptime at: At) void {
    if (std.mem.eql(u8, at.key, "_id")) @compileError("odm: " ++ subject(at) ++ " is the _id of the document, which an update cannot change");
}

/// The changes of `op` at the field `at`, whose value is `@field(L, name)`:
/// a literal of paths into the struct of the field, or the value of the
/// operator. `names` lead from the operator's literal to the value; `into`
/// is the first optional struct on the way.
fn changesAt(comptime op: Op, comptime at: At, comptime into: ?At, comptime L: type, comptime name: []const u8, comptime names: []const []const u8) []const Change {
    const V = @FieldType(L, name);
    const S = Unwrap(at.F);
    if (schema.isDocument(S) and values.isLiteral(V, S)) {
        const keys = @typeInfo(V).@"struct".field_names;
        if (keys.len == 0) @compileError("odm: " ++ @tagName(op) ++ " of " ++ subject(at) ++ ": an empty literal changes nothing here; drop it");
        const outer = into orelse if (@typeInfo(at.F) == .optional) at else null;
        var out: []const Change = &.{};
        for (keys) |key| out = out ++ changesAt(op, values.field(at, key), outer, V, key, names ++ &[_][]const u8{key});
        return out;
    }
    // A literal of the fields of the items of a list would be paths
    // through it; push, add_to_set and pull take literals of their own.
    if (values.ItemOf(at)) |Item| if (schema.isDocument(Unwrap(Item)) and op != .push and op != .add_to_set and op != .pull) {
        if (values.isLiteral(V, Unwrap(Item)) and @typeInfo(V).@"struct".field_names.len > 0) throughList(@tagName(op), at, @typeInfo(V).@"struct".field_names[0]);
    };
    if (creates(op)) if (into) |s| intoOptional(op, at, s);
    return &.{.{ .op = op, .at = at, .names = names, .write = writeOf(op, at, L, name) }};
}

/// Stops the build at a path into the struct of the optional field `s`, in
/// an operator that makes the fields it changes (design §5.9).
fn intoOptional(comptime op: Op, comptime at: At, comptime s: At) noreturn {
    const S = @typeName(Unwrap(s.F));
    @compileError("odm: " ++ @tagName(op) ++ " of " ++ subject(at) ++ " goes into " ++ subject(s) ++ ", which is optional: in a document without " ++ s.path ++
        " it would create an incomplete " ++ S ++ "; set the whole " ++ S ++ ", .{ .set = .{ " ++ fieldLiteral(s.path, "value") ++ " } }, or unset " ++ s.path);
}

/// Stops the build at a path through the list at `at`, to the field `key`
/// of its items.
fn throughList(comptime op: []const u8, comptime at: At, comptime key: []const u8) noreturn {
    @compileError("odm: " ++ op ++ " of " ++ subject(at) ++ "." ++ key ++ " goes through the list " ++ subject(at) ++ ": an update sets a whole list, or changes its items with push, add_to_set, pull or pop");
}

/// The field at the dotted `path` with `value`, as a literal writes it:
/// `.city = value` for "city", `.profile = .{ .city = value }` for
/// "profile.city".
fn fieldLiteral(comptime path: []const u8, comptime value: []const u8) []const u8 {
    const dot = std.mem.findScalar(u8, path, '.') orelse return "." ++ path ++ " = " ++ value;
    return "." ++ path[0..dot] ++ " = .{ " ++ fieldLiteral(path[dot + 1 ..], value) ++ " }";
}

/// The enum literal of a path, as `unset` takes it: `.profile`,
/// `.@"address.zip"`.
fn pathLiteral(comptime path: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, path, '.') != null) ".@\"" ++ path ++ "\"" else "." ++ path;
}

/// How the value `@field(L, name)` of `op` on the field at `at` goes into
/// BSON, after its checks.
fn writeOf(comptime op: Op, comptime at: At, comptime L: type, comptime name: []const u8) Write {
    const F = Unwrap(at.F);
    return switch (op) {
        .set, .set_on_insert => set: {
            requireSet(op, at, L, name);
            break :set .{ .value = F };
        },
        .inc, .mul => .{ .value = numberOf(op, at, L, name) },
        .min, .max => order: {
            if (!ordered(F)) @compileError("odm: " ++ @tagName(op) ++ " needs a number, a string, a bson.DateTime or a bson.ObjectId; " ++ subject(at) ++ " is " ++ @typeName(at.F));
            values.checkValue(@tagName(op) ++ " of", @typeName(at.T), at.path, F, L, name);
            break :order .{ .value = F };
        },
        .push, .add_to_set => pushOf(op, at, L, name),
        .pull => pullOf(at, L, name),
        .pop => .{ .pop = popOf(at, L, name) },
        .unset => unreachable,
    };
}

/// Stops the build unless `@field(L, name)` is a value for `set` or
/// `set_on_insert` of the field at `at`. odm stores no null, so an optional
/// field takes a value of its child, never null or another optional.
fn requireSet(comptime op: Op, comptime at: At, comptime L: type, comptime name: []const u8) void {
    const V = @FieldType(L, name);
    const F = Unwrap(at.F);
    const of = "odm: " ++ @tagName(op) ++ " of " ++ subject(at);
    if (@typeInfo(at.F) == .optional) {
        if (V == @TypeOf(null)) {
            @compileError(of ++ " to null: odm does not store null; " ++ if (op == .set) "clear the field with .unset = .{" ++ pathLiteral(at.path) ++ "}" else "leave the field out");
        }
        if (@typeInfo(V) == .optional and values.fits(@typeInfo(V).optional.child, F)) {
            @compileError(of ++ " needs a " ++ @typeName(F) ++ "; got " ++ @typeName(V) ++ ": odm does not store null, so set the field when the value is there, and " ++
                (if (op == .set) "unset it" else "leave it out") ++ " when it is not");
        }
    }
    values.checkValue(@tagName(op) ++ " of", @typeName(at.T), at.path, F, L, name);
}

/// The type that `inc` or `mul` of the field at `at` writes its value as,
/// after its checks: the BSON integer of an integer field, int32 or int64
/// as the codec writes the field, so that a step below zero fits too; f64
/// for a double.
fn numberOf(comptime op: Op, comptime at: At, comptime L: type, comptime name: []const u8) type {
    const F = Unwrap(at.F);
    const V = @FieldType(L, name);
    const of = "odm: " ++ @tagName(op) ++ " of " ++ subject(at);
    switch (@typeInfo(F)) {
        .int => |info| {
            const I = if (info.bits <= @as(u16, if (info.signedness == .signed) 32 else 31)) i32 else i64;
            if (V != comptime_int and @typeInfo(V) != .int) @compileError(of ++ " needs an integer: " ++ subject(at) ++ " is " ++ @typeName(at.F));
            const known = values.isComptime(L, name);
            if (if (known) values.comptimeProblem(I, values.comptimeValue(L, name)) != null else !values.fits(V, I)) {
                const got = if (known) std.fmt.comptimePrint("{d}", .{values.comptimeValue(L, name)}) else @typeName(V);
                @compileError(of ++ " needs an integer that fits " ++ @typeName(I) ++ ", the BSON integer of " ++ @typeName(F) ++ "; got " ++ got);
            }
            return I;
        },
        .float => {
            values.checkValue(@tagName(op) ++ " of", @typeName(at.T), at.path, f64, L, name);
            return f64;
        },
        else => @compileError("odm: " ++ @tagName(op) ++ " needs a number; " ++ subject(at) ++ " is " ++ @typeName(at.F)),
    }
}

/// Whether `min` and `max` compare the values of `S`: numbers, strings,
/// dates and ObjectIds.
fn ordered(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .int, .float => true,
        else => S == []const u8 or S == bson.Decimal128 or S == bson.DateTime or S == bson.ObjectId,
    };
}

/// The type of the items of the list at `at`, which `op` changes. An array
/// of a fixed length does not take `op`: the document would get another
/// length, which the model does not read.
fn listOf(comptime op: Op, comptime at: At) type {
    const Item = values.ItemOf(at) orelse @compileError("odm: " ++ @tagName(op) ++ " needs a list; " ++ subject(at) ++ " is " ++ @typeName(at.F));
    if (@typeInfo(Unwrap(at.F)) == .array) {
        @compileError("odm: " ++ @tagName(op) ++ " of " ++ subject(at) ++ ": " ++ @typeName(Unwrap(at.F)) ++ " has a fixed length, and " ++ @tagName(op) ++ " changes it; set the whole array with .set");
    }
    return Item;
}

/// How `push` or `add_to_set` writes `@field(L, name)` on the list at `at`:
/// one item, or the items of `.{ .each = items }`.
fn pushOf(comptime op: Op, comptime at: At, comptime L: type, comptime name: []const u8) Write {
    const E = listOf(op, at);
    const V = @FieldType(L, name);
    const what = @tagName(op) ++ " of";
    if (values.isLiteral(V, Unwrap(E))) {
        const keys = @typeInfo(V).@"struct".field_names;
        if (keys.len != 1 or !std.mem.eql(u8, keys[0], "each")) {
            @compileError("odm: " ++ what ++ " " ++ subject(at) ++ " takes an item of the list, or .{ .each = items } for several");
        }
        values.checkValue(what, @typeName(at.T), at.path, []const E, V, "each");
        return .{ .each = E };
    }
    values.checkValue(what, @typeName(at.T), at.path ++ "[]", E, L, name);
    return .{ .item = E };
}

/// How `pull` writes `@field(L, name)` on the list at `at`: an item of the
/// list, or a literal of conditions on its items, as `elem_match` takes.
fn pullOf(comptime at: At, comptime L: type, comptime name: []const u8) Write {
    const E = listOf(.pull, at);
    if (values.isLiteral(@FieldType(L, name), Unwrap(E))) return .pull_conditions;
    values.checkValue("pull of", @typeName(at.T), at.path ++ "[]", E, L, name);
    return .{ .pull_item = E };
}

/// -1 for `.first`, 1 for `.last`: the end of the list at `at` that `pop`
/// takes an item from.
fn popOf(comptime at: At, comptime L: type, comptime name: []const u8) i32 {
    _ = listOf(.pop, at);
    const V = @FieldType(L, name);
    const got = if (@typeInfo(V) == .enum_literal) got: {
        const tag = @tagName(values.comptimeValue(L, name));
        if (std.mem.eql(u8, tag, "first")) return -1;
        if (std.mem.eql(u8, tag, "last")) return 1;
        break :got "." ++ tag;
    } else @typeName(V);
    @compileError("odm: pop takes .first or .last; got " ++ got);
}

/// The changes of `unset`, whose tuple of paths of `T` is `L`.
fn unsets(comptime T: type, comptime L: type) []const Change {
    const M = @typeName(T);
    const shape = "odm: unset takes a tuple of paths of " ++ M ++ ", such as .{ .a, .@\"b.c\" }; got " ++ @typeName(L);
    const Tuple = values.TupleOf(L) orelse @compileError(shape);
    const items = @typeInfo(Tuple).@"struct".field_names;
    if (items.len == 0) @compileError("odm: unset in the update of " ++ M ++ " is empty");
    var out: []const Change = &.{};
    for (items) |i| {
        if (@typeInfo(@FieldType(Tuple, i)) != .enum_literal) @compileError(shape);
        const at = unsetAt(T, @tagName(values.comptimeValue(Tuple, i)));
        out = out ++ &[_]Change{.{ .op = .unset, .at = at, .names = &.{}, .write = .unset }};
    }
    return out;
}

/// The field at the dotted `path` of `T` that `unset` clears, after its
/// checks: not the id, not through a list, and optional or with a default
/// value, so that a document without it still reads.
fn unsetAt(comptime T: type, comptime path: []const u8) At {
    var parts = std.mem.splitScalar(u8, path, '.');
    var at = values.top(T, parts.first());
    requireNotId(at);
    var S: type = T;
    var name: []const u8 = at.path;
    while (parts.next()) |part| {
        if (values.ItemOf(at) != null and values.Fields(at.F) != null) throughList("unset", at, part);
        S = values.Fields(at.F) orelse @compileError("odm: " ++ subject(at) ++ " has no field '" ++ part ++ "'");
        at = values.field(at, part);
        name = part;
    }
    const default = @typeInfo(S).@"struct".field_attrs[std.meta.fieldIndex(S, name).?].default_value_ptr != null;
    if (@typeInfo(at.F) != .optional and !default) @compileError("odm: unset would leave " ++ subject(at) ++ " without a value: it is not optional and has no default");
    return at;
}

/// Stops the build at a path that the changes change twice, and at two
/// paths of which one holds the other: MongoDB refuses both.
fn requireDistinct(comptime changes: []const Change) void {
    for (changes, 0..) |a, i| {
        for (changes[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.at.path, b.at.path)) @compileError("odm: the update changes " ++ subject(a.at) ++ " twice: in " ++ @tagName(a.op) ++ " and in " ++ @tagName(b.op));
            if (overlap(a.at.path, b.at.path)) @compileError("odm: the update changes " ++ subject(a.at) ++ " and " ++ subject(b.at) ++ ", which overlap");
        }
    }
}

/// Whether one of two paths holds the other: "address" and "address.zip".
fn overlap(a: []const u8, b: []const u8) bool {
    return within(a, b) or within(b, a);
}

/// Whether `path` is a path inside the field at `outer`.
fn within(outer: []const u8, path: []const u8) bool {
    return path.len > outer.len and std.mem.startsWith(u8, path, outer) and path[outer.len] == '.';
}

/// Writes the operators of the literal `update` with their `changes`.
fn writeUpdate(b: *Builder, comptime U: type, comptime changes: []const Change, update: U) filter.WriteError!void {
    inline for (@typeInfo(U).@"struct".field_names) |name| {
        const op = comptime operator(name).?;
        try b.beginDocument(keyOfOp(op));
        inline for (changes) |c| {
            if (comptime c.op == op) try writeChange(b, c, @field(update, name));
        }
        try b.end();
    }
}

/// Writes the change `c` into the document of its operator, whose literal
/// is `literal`.
fn writeChange(b: *Builder, comptime c: Change, literal: anytype) filter.WriteError!void {
    const key = c.at.key;
    switch (c.write) {
        .unset => try b.putString(key, ""),
        .pop => |n| try b.putInt32(key, n),
        .value, .item => |X| try values.writeValue(b, key, X, @field(parentOf(literal, c.names), fieldName(c.names))),
        .each => |E| {
            try b.beginDocument(key);
            try values.writeValue(b, "$each", []const E, @field(parentOf(literal, c.names), fieldName(c.names)).each);
            try b.end();
        },
        .pull_item => |E| if (comptime filter.needsEq(E) or schema.isDocument(Unwrap(E))) {
            try b.beginDocument(key);
            try values.writeValue(b, "$eq", E, @field(parentOf(literal, c.names), fieldName(c.names)));
            try b.end();
        } else {
            try values.writeValue(b, key, E, @field(parentOf(literal, c.names), fieldName(c.names)));
        },
        .pull_conditions => {
            const conditions = @field(parentOf(literal, c.names), fieldName(c.names));
            try b.beginDocument(key);
            try filter.writeItemConditions(b, c.at, @TypeOf(conditions), conditions);
            try b.end();
        },
    }
}

/// The struct of the literal `value` that holds the last of the fields
/// `names`, one inside the other. The value itself is read with `@field`
/// where it is written: a field known at compile time keeps its value then,
/// even in a literal known only at run time.
fn parentOf(value: anytype, comptime names: []const []const u8) Parent(@TypeOf(value), names) {
    if (names.len == 1) return value;
    return parentOf(@field(value, names[0]), names[1..]);
}

fn Parent(comptime V: type, comptime names: []const []const u8) type {
    return if (names.len == 1) V else Parent(@FieldType(V, names[0]), names[1..]);
}

fn fieldName(comptime names: []const []const u8) []const u8 {
    return names[names.len - 1];
}

/// Stops the build unless an upsertOne of `T` with a filter of type `F` and
/// an update of type `U` inserts, when no document matches, one that the
/// model reads (design §5.10). The server builds that document from the
/// equalities of the filter and the operators of the update, so:
///
/// - both are literals, and the values in them may be known at run time;
/// - every required field of the model (not optional, without a default)
///   comes from an equality of the filter (`.f = value`,
///   `.f = .{ .eq = value }`), `set`, `set_on_insert`, or an operator that
///   makes the field: `inc`, `mul`, `min`, `max`, `push`, `add_to_set`;
///   each struct that the insert builds from paths gets its required
///   fields so too;
/// - an id that the application gives comes from an equality of the filter
///   or `set_on_insert`, while an ObjectId the server makes when they give
///   none;
/// - the equalities of the filter are values that odm would write: not
///   null, not an optional, not an item where a list goes; and no path of
///   the filter goes through a list, and no logical operator is in it;
/// - no field of the filter has `in`, `nin` or `all`: mongod copies one
///   item of `in` or `all` into the document as an equality, a list field
///   then gets the item, and an empty one leaves the filter's equalities
///   out of the document. `nin` copies nothing, and goes with them so that
///   the rule stays one: no list conditions in an upsert.
///
/// The rules of zefir-validator do not run for upsertOne.
pub fn checkUpsert(comptime T: type, comptime F: type, comptime U: type) void {
    comptime {
        @setEvalBranchQuota(schema.eval_quota);
        schema.check(T);
        const M = @typeName(T);
        const why = ": it checks at compile time that the document it may insert gets every required field";
        if (filter.isBuilt(F)) @compileError("odm: upsertOne of " ++ M ++ " takes a filter literal, not an odm.Filter(" ++ M ++ ")" ++ why);
        if (isBuilt(U)) @compileError("odm: upsertOne of " ++ M ++ " takes an update literal, not an odm.Update(" ++ M ++ ")" ++ why);
        filter.requireFilter(T, F);
        const given = filterGives(T, F) ++ updateGives(analyze(T, U, .upsert));
        requireId(T, given);
        requireFields(T, given);
    }
}

/// The id that the document of an upsert of `T` gets from an equality of
/// `conditions` or from `set_on_insert` of `changes`, the literals that
/// `checkUpsert` took; null when they give none, and the server makes an
/// ObjectId. The id is the caller's value: a string id borrows its bytes.
pub fn upsertId(comptime T: type, conditions: anytype, changes: anytype) ?schema.Id(T) {
    const id = comptime schema.idName(T);
    const F = @TypeOf(conditions);
    if (comptime @hasField(F, id)) {
        const V = @FieldType(F, id);
        const condition = @field(conditions, id);
        if (comptime !filter.isConditions(values.top(T, id), V)) return condition;
        if (comptime @hasField(V, "eq")) return condition.eq;
    }
    const U = @TypeOf(changes);
    if (comptime @hasField(U, "set_on_insert") and @hasField(@FieldType(U, "set_on_insert"), id)) return @field(changes.set_on_insert, id);
    return null;
}

/// The start of the messages about the filter of an upsert.
fn upsertOf(comptime at: At) []const u8 {
    return "odm: upsertOne of " ++ @typeName(at.T) ++ ": ";
}

/// The paths that the equalities of the filter literal `F` copy into the
/// document of an upsert, after the rules of upsertOne on them.
fn filterGives(comptime T: type, comptime F: type) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (@typeInfo(F).@"struct".field_names) |name| {
        if (filter.isLogical(name)) {
            @compileError("odm: upsertOne of " ++ @typeName(T) ++ ": " ++ name ++ " in the filter: the server takes equalities from it into the document it may insert, and odm checks only the fields of the filter itself; put the conditions in the fields of the filter");
        }
        out = out ++ conditionGives(values.top(T, name), F, name);
    }
    return out;
}

/// The paths that the condition `@field(L, name)` on the field at `at`
/// copies into the document of an upsert: its own for an equality, those
/// of the fields of a literal of paths, none for other operators.
fn conditionGives(comptime at: At, comptime L: type, comptime name: []const u8) []const []const u8 {
    const V = @FieldType(L, name);
    if (!filter.isConditions(at, V)) {
        requireCopy(at, L, name);
        return &.{at.path};
    }
    switch (filter.classify(at, V)) {
        .paths => {
            const keys = @typeInfo(V).@"struct".field_names;
            if (values.ItemOf(at) != null) {
                @compileError(upsertOf(at) ++ "the filter's path " ++ at.path ++ "." ++ keys[0] ++ " goes through the list " ++ subject(at) ++ ", and the document it may insert would get a document there, not a list; use .elem_match");
            }
            var out: []const []const u8 = &.{};
            for (keys) |key| out = out ++ conditionGives(values.field(at, key), V, key);
            return out;
        },
        .operators => {
            for ([_][]const u8{ "in", "nin", "all" }) |op| {
                if (@hasField(V, op)) {
                    @compileError(upsertOf(at) ++ "the filter's " ++ op ++ " on " ++ subject(at) ++ ": in, nin and all stay out of the filter of an upsert, since the server copies one item of in or all into the document it may insert, an item where a list goes too, and with no item it inserts none of the filter's equalities; match by equality, or use updateOne, then insertOne when it matched nothing");
                }
            }
            if (!@hasField(V, "eq")) return &.{};
            requireCopy(at, V, "eq");
            return &.{at.path};
        },
    }
}

/// Stops the build unless the equality `@field(L, name)` on the field at
/// `at` is a value that odm would write, as the server copies it into the
/// document of an upsert: not null, not an optional, and not an item of a
/// list where the list goes.
fn requireCopy(comptime at: At, comptime L: type, comptime name: []const u8) void {
    const V = @FieldType(L, name);
    const of = upsertOf(at) ++ "the filter's ";
    if (V == @TypeOf(null)) {
        @compileError(of ++ subject(at) ++ " = null would go into the document it may insert, and odm does not store null; match a missing field with .{ " ++ fieldLiteral(at.path, ".{ .exists = false }") ++ " }");
    }
    if (values.ItemOf(at)) |Item| {
        const item = if (values.isComptime(L, name)) values.comptimeFits(V, Item) else values.fits(V, Item);
        // An optional list is a whole list, which the check below refuses.
        if (item or !values.isList(Unwrap(V))) {
            @compileError(of ++ subject(at) ++ " = item would put the item where the list goes in the document it may insert; match the whole list with .eq, or the item with .elem_match");
        }
    }
    if (@typeInfo(V) == .optional) {
        @compileError(of ++ "equality on " ++ subject(at) ++ " needs a " ++ @typeName(Unwrap(at.F)) ++ "; got " ++ @typeName(V) ++ ": it goes into the document the upsert may insert, and odm does not store null");
    }
}

/// The paths that the operators of an upsert give its document: those of
/// all but `unset`, `pull` and `pop`.
fn updateGives(comptime changes: []const Change) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (changes) |c| {
        if (creates(c.op)) out = out ++ &[_][]const u8{c.at.path};
    }
    return out;
}

/// Stops the build when the id of `T` is one that the application gives,
/// and `given` lacks it.
fn requireId(comptime T: type, comptime given: []const []const u8) void {
    if (schema.idKind(T) != .given) return;
    const id = schema.idName(T);
    if (holds(given, id) or below(given, id)) return;
    @compileError("odm: upsertOne of " ++ @typeName(T) ++ " may insert a document without its id '" ++ id ++ "', which is " ++ @typeName(@FieldType(T, id)) ++ ": give it by equality in the filter or in set_on_insert");
}

/// Stops the build when a required field of `T`, or of a struct built from
/// paths, is not among the paths that the upsert gives, naming them all.
fn requireFields(comptime T: type, comptime given: []const []const u8) void {
    const lacking = missing(T, "", given, schema.idName(T));
    if (lacking.len == 0) return;
    var list: []const u8 = "";
    for (lacking, 0..) |path, i| list = list ++ (if (i == 0) "'" else ", '") ++ path ++ "'";
    @compileError("odm: upsertOne of " ++ @typeName(T) ++ " may insert a document without its required fields " ++ list ++ ": give each by equality in the filter, in set, in set_on_insert, or with an operator that creates it, such as inc or push");
}

/// The required fields of the struct `S`, whose fields have the paths
/// `prefix` and their names, that `given` lacks: a field neither given,
/// optional nor with a default, and those of each struct that the
/// insert builds from paths. `skip` is a field that is not looked at.
fn missing(comptime S: type, comptime prefix: []const u8, comptime given: []const []const u8, comptime skip: []const u8) []const []const u8 {
    const info = @typeInfo(S).@"struct";
    var out: []const []const u8 = &.{};
    for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        const path = prefix ++ name;
        if (std.mem.eql(u8, name, skip) or holds(given, path)) continue;
        if (below(given, path)) {
            out = out ++ missing(Unwrap(F), path ++ ".", given, "");
        } else if (@typeInfo(F) != .optional and attrs.default_value_ptr == null) {
            out = out ++ &[_][]const u8{path};
        }
    }
    return out;
}

fn holds(comptime paths: []const []const u8, comptime path: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

/// Whether one of `paths` is inside the field at `path`.
fn below(comptime paths: []const []const u8, comptime path: []const u8) bool {
    for (paths) |p| {
        if (within(path, p)) return true;
    }
    return false;
}

/// Changes of the model `T` built at run time (design §4.9): an immutable
/// list of the literals of `with`, each checked by the compiler and encoded
/// into the arena at once. The operators of several `with` merge: two
/// `with` of `set` make one `$set`, with the fields in the order of the
/// calls. The compiler sees one literal at a time, so what spans several
/// `with` is `error.InvalidArgument` from the operation: an `Update`
/// without a `with`, a path that two of them change, two paths of theirs
/// of which one holds the other. The first error of a `with` stays in the
/// value, later ones change nothing, and the operation returns it. An
/// operation takes an `Update(T)` where it takes an update literal;
/// upsertOne takes literals only.
///
/// ```zig
/// var u = odm.Update(User).init(arena);
/// if (new_name) |name| u = u.with(.{ .set = .{ .name = name } });
/// if (birthday) u = u.with(.{ .inc = .{ .age = 1 } });
/// ```
pub fn Update(comptime T: type) type {
    return struct {
        /// Where the changes live: an arena, or any allocator that is freed
        /// whole.
        arena: Allocator,
        /// The changes of the last `with`, which lead to those before.
        last: ?*const Node = null,
        /// The first error of a `with`.
        failure: ?filter.EncodeError = null,

        const Self = @This();

        /// The model of the update, for the checks of odm.
        pub const odm_update_model = T;

        /// No change yet: an operation refuses it.
        pub fn init(arena: Allocator) Self {
            return .{ .arena = arena };
        }

        /// These changes and those of `change`, an update literal of `T`.
        pub fn with(u: Self, change: anytype) Self {
            const paths = comptime pathsOf(analyze(T, @TypeOf(change), .update));
            if (u.failure != null) return u;
            const doc = encode(T, u.arena, change, .update) catch |err| return .{ .arena = u.arena, .last = u.last, .failure = err };
            const node = u.arena.create(Node) catch return .{ .arena = u.arena, .last = u.last, .failure = error.OutOfMemory };
            node.* = .{ .doc = doc, .paths = paths, .prev = u.last };
            return .{ .arena = u.arena, .last = node };
        }

        /// Whether no `with` added a change, and none failed.
        pub fn isEmpty(u: Self) bool {
            return u.last == null and u.failure == null;
        }
    };
}

/// One `with` of an `Update`: its literal, the paths that it changes, and
/// the `with` before it.
const Node = struct { doc: bson.RawDocument, paths: []const []const u8, prev: ?*const Node };

/// Whether `V` is the type of an `odm.Update` of some model.
fn isBuilt(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .@"struct" => @hasDecl(V, "odm_update_model"),
        else => false,
    };
}

/// The paths of `changes`, for the checks across the `with` of an `Update`.
fn pathsOf(comptime changes: []const Change) []const []const u8 {
    comptime {
        var out: [changes.len][]const u8 = undefined;
        for (changes, &out) |c, *path| path.* = c.at.path;
        const final = out;
        return &final;
    }
}

/// The BSON of the `Update` `u`: its one literal, or the operators of all
/// of them merged.
fn encodeBuilt(arena: Allocator, u: anytype) filter.EncodeError!bson.RawDocument {
    if (u.failure) |err| return err;
    const last = u.last orelse return error.InvalidArgument;
    var count: usize = 0;
    var node: ?*const Node = last;
    while (node) |later| : (node = later.prev) {
        count += 1;
        var other = later.prev;
        while (other) |earlier| : (other = earlier.prev) {
            if (conflict(later.paths, earlier.paths)) return error.InvalidArgument;
        }
    }
    if (count == 1) return last.doc;
    const nodes = try arena.alloc(*const Node, count);
    node = last;
    for (0..count) |i| {
        nodes[count - 1 - i] = node.?;
        node = node.?.prev;
    }
    var b: Builder = .init(arena);
    defer b.deinit();
    merge(&b, nodes) catch |err| return filter.encodeError(err);
    const doc = b.finish() catch |err| return filter.encodeError(err);
    return doc.raw();
}

/// Whether a path of `a` is one of `b`, or holds one, or is inside one.
fn conflict(a: []const []const u8, b: []const []const u8) bool {
    for (a) |p| {
        for (b) |q| {
            if (std.mem.eql(u8, p, q) or overlap(p, q)) return true;
        }
    }
    return false;
}

/// Writes the operators of the `with` of an `Update`, `nodes` in call
/// order: each once, in the order of its first `with`, with the fields of
/// every `with` that has it.
fn merge(b: *Builder, nodes: []const *const Node) filter.WriteError!void {
    var done: std.EnumSet(Op) = .empty;
    for (nodes) |node| {
        var ops = node.doc.iterator();
        while (try ops.next()) |op| {
            const which = opOfKey(op.key) orelse return error.InvalidBson;
            if (done.contains(which)) continue;
            done.insert(which);
            try b.beginDocument(op.key);
            for (nodes) |other| {
                const changes = (try other.doc.get(op.key)) orelse continue;
                if (changes != .document) return error.InvalidBson;
                var elements = changes.document.iterator();
                while (try elements.next()) |element| try b.putValue(element.key, element.value);
            }
            try b.end();
        }
    }
}

/// The operator whose key in BSON is `key`.
fn opOfKey(key: []const u8) ?Op {
    inline for (@typeInfo(Op).@"enum".field_names) |name| {
        if (std.mem.eql(u8, key, comptime keyOfOp(@field(Op, name)))) return @field(Op, name);
    }
    return null;
}
