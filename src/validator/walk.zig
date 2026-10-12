//! The walker, the public entry points built on it, and the declaration
//! checks of every type the walker visits.
//!
//! Before walking, an entry point runs `verify(T)` at comptime: the checks of
//! `T` and of each type the walk can reach from it, each type once. The walk
//! runs a value's own rules left to right, reports the first one that fails
//! as the value's only violation, and descends into the value (the items of
//! a list, the fields of a struct) only when they all passed.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;
const Rule = core.Rule;
const Violation = core.Violation;

// ------------------------------------------------------------------ entry points

/// The first violation of `value.*` in walk order, or null. `value` is a
/// single-item pointer (`&dto`); the path is written into `path_buf`, and
/// `field` is null when it does not fit. Allocates nothing.
pub fn check(value: anytype, path_buf: []u8) ?Violation {
    const T = comptime pointee(@TypeOf(value));
    comptime verify(T);
    var sink: First = .{ .buf = path_buf };
    _ = walkRoot(T, value, &sink) catch |err| switch (err) {};
    return sink.found;
}

/// Every violation of `value.*` in walk order, at most
/// `max_report_violations` of them. `value` is passed as for `check`. The
/// report owns its memory, one arena from `gpa`, even when it is empty: call
/// `deinit` once. On `error.OutOfMemory` everything is already freed.
pub fn checkAll(gpa: Allocator, value: anytype) Allocator.Error!Report {
    const T = comptime pointee(@TypeOf(value));
    comptime verify(T);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var sink: All = .{ .arena = arena.allocator() };
    _ = try walkRoot(T, value, &sink);
    return .{ .violations = sink.list.items, .truncated = sink.truncated, .arena = arena };
}

/// The result of `checkAll`, like `std.json.Parsed`: the violations and
/// their paths live in `arena`. Copies share the memory; call `deinit` once.
pub const Report = struct {
    /// In walk order; the first one equals `check`'s result (its `field` too
    /// when the path fits `check`'s `path_buf`).
    violations: []const Violation,
    /// More than `max_report_violations` violations existed: the walk stopped
    /// at the next one, which is not in `violations`.
    truncated: bool,
    /// Holds `violations` and every `field`; code and message are static.
    arena: *std.heap.ArenaAllocator,

    /// Frees `violations` and every `field` through the allocator given to
    /// `checkAll`.
    pub fn deinit(report: Report) void {
        const gpa = report.arena.child_allocator;
        report.arena.deinit();
        gpa.destroy(report.arena);
    }
};

/// The compile-time declaration check of `T` and of every type the walker
/// would visit from it, without walking a value: exactly the checks that
/// `check` and `checkAll` run for a `*T`. Zig analyzes only code that is
/// referenced, so a package that declares DTOs calls it in a test to have
/// their declarations checked where they are written:
/// `test { comptime v.assertRules(CreateUserRequest); }`. Pass the DTO type
/// itself (`CreateUserRequest`, `[]const User`), not a pointer type: pointers
/// are not walked. It also analyzes the body of every `validateSelf`, an
/// `inline fn` included, so the compile-time checks of `v.fail` run too.
/// Does nothing at run time.
pub fn assertRules(comptime T: type) void {
    comptime verify(T);
}

/// Builds the result of a `validateSelf`, checked at compile time: `T` is the
/// struct that declares `validateSelf` (usually `@This()`), `field` names one
/// of its non-comptime fields (`.end`) or is null for the struct itself, and
/// `code` and `message` follow the rules of `v.custom`.
///
///     return v.fail(@This(), .end, "orders.end_before_start", "must not be before start");
pub fn fail(comptime T: type, comptime field: ?FailField(T), comptime code: []const u8, comptime message: []const u8) Violation {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const where = "fail(" ++ @typeName(T) ++ ", " ++ (if (field) |f| "." ++ @tagName(f) else "null") ++ ")";
        if (field) |f| {
            if (isComptimeField(T, @tagName(f)))
                @compileError("validator: " ++ where ++ ": " ++ @tagName(f) ++ " is a comptime field; comptime fields are not validated");
        }
        core.checkCode(where, code);
        core.checkMessage(where, message);
    }
    return .{ .code = code, .message = message, .field = if (field) |f| @tagName(f) else null };
}

/// The type of `fail`'s `field`: the field names of `T` as an enum, so that a
/// misspelled field is Zig's own error at the caller's line. A `T` that is not
/// a struct is rejected here, before `std.meta.FieldEnum` would fail inside std.
fn FailField(comptime T: type) type {
    if (@typeInfo(T) != .@"struct")
        @compileError("validator: fail(" ++ @typeName(T) ++ "): expects the struct that declares validateSelf, e.g. v.fail(@This(), .field, code, message)");
    return std.meta.FieldEnum(T);
}

/// The root type behind `&value`. A value or a bare slice is a compile error:
/// the root must be passed by pointer, so that a slice root is unambiguous.
fn pointee(comptime P: type) type {
    switch (@typeInfo(P)) {
        .pointer => |p| if (p.size == .one) return p.child,
        else => {},
    }
    const slice_hint = if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .slice) "; pass &slice, not the slice" else "";
    @compileError("validator: pass a pointer to the value (&value), got " ++ @typeName(P) ++ slice_hint);
}

// ------------------------------------------------------------------ which types carry rules

/// A type declares rules: `field_rules`, `validateSelf`, or a non-function
/// `validate` (rules written under confy's hook name).
fn declaresRules(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "field_rules") or @hasDecl(T, "validateSelf") or misnamedRules(T),
        else => false,
    };
}

fn misnamedRules(comptime T: type) bool {
    return @hasDecl(T, "validate") and @typeInfo(@TypeOf(T.validate)) != .@"fn";
}

fn includes(comptime list: []const type, comptime T: type) bool {
    for (list) |X| {
        if (X == T) return true;
    }
    return false;
}

/// Types reached from `X` when looking for rules: the non-comptime fields of
/// a struct, the fields of a union, and the children of optionals, pointers
/// of every size, arrays, vectors and error-union payloads.
fn reachable(comptime X: type) []const type {
    return switch (@typeInfo(X)) {
        .@"struct" => |s| blk: {
            var out: []const type = &.{};
            for (s.field_types, s.field_attrs) |F, attrs| {
                if (!attrs.@"comptime") out = out ++ &[_]type{F};
            }
            break :blk out;
        },
        .@"union" => |u| u.field_types,
        .optional => |o| &.{o.child},
        .pointer => |p| &.{p.child},
        .array => |a| &.{a.child},
        .vector => |v| &.{v.child},
        .error_union => |e| &.{e.payload},
        else => &.{},
    };
}

/// The nearest type reachable from `T` (`T` included) that declares rules.
/// Breadth-first with one visited set, so each type is looked at once per
/// query; Zig memoizes the result per type.
fn findRuleType(comptime T: type) ?type {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var queue: []const type = &.{T};
        var next: usize = 0;
        while (next < queue.len) : (next += 1) {
            const X = queue[next];
            if (declaresRules(X)) return X;
            for (reachable(X)) |C| {
                if (!includes(queue, C)) queue = queue ++ &[_]type{C};
            }
        }
        return null;
    }
}

fn containsRules(comptime T: type) bool {
    return findRuleType(T) != null;
}

/// A struct (not a tuple) with rules in it or below it: the walker visits
/// its fields.
fn isWalkedStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !@typeInfo(T).@"struct".is_tuple and containsRules(T);
}

// ------------------------------------------------------------------ declaration checks

/// Every compile-time check of `Root` and of each type the walker visits from
/// it: `check`, `checkAll` and `assertRules` run it before anything else.
/// Each struct is checked once per root.
fn verify(comptime Root: type) void {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        _ = visit(Root, @typeName(Root), &.{}, &.{});
    }
}

/// Checks `T` and every type the walker visits below it, and returns `done`
/// plus the structs it finished. `where` names `T` in errors: the root type
/// or the nearest named struct above `T`, then `.field` per field and `[]`
/// per list level (`shop.Order.items[]`). `stack` holds the structs being
/// visited, so a struct that reaches itself is an error instead of an
/// endless descent.
fn visit(comptime T: type, comptime where: []const u8, comptime stack: []const type, comptime done: []const type) []const type {
    @setEvalBranchQuota(core.eval_quota);
    switch (@typeInfo(T)) {
        .optional => |o| return visit(o.child, where, stack, done),
        .array => |a| return visit(a.child, where ++ "[]", stack, done),
        .pointer => {
            // A string is a leaf and a list slice is walked item by item, as
            // in walkValue; every other pointer is opaque: one-item, many-item
            // and C pointers, and volatile, allowzero or under-aligned slices.
            if (core.isString(T)) return done;
            if (core.ListChild(T)) |Item| return visit(Item, where ++ "[]", stack, done);
            hidden(T, "pointers", where);
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                hidden(T, "tuples", where);
                return done;
            }
            if (!containsRules(T) or includes(done, T)) return done;
            if (includes(stack, T))
                @compileError("validator: " ++ where ++ ": recursive types are not supported; " ++ @typeName(T) ++ " contains itself");
            const label = if (isAnonymous(T)) where else @typeName(T);
            checkStruct(T, label);
            var finished = done;
            for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (!attrs.@"comptime") finished = visit(F, label ++ "." ++ name, stack ++ &[_]type{T}, finished);
            }
            return finished ++ &[_]type{T};
        },
        .@"union" => hidden(T, "unions", where),
        .@"enum" => hidden(T, "enums", where),
        .@"opaque" => hidden(T, "opaque types", where),
        .vector => hidden(T, "vectors", where),
        .error_union => hidden(T, "error unions", where),
        else => {},
    }
    return done;
}

/// `T` is a type the walker does not descend into; `what` names its kind in
/// the error ("pointers", "unions", ...). Rules declared below `T` would be
/// skipped without a word, so reaching a type that declares them is a
/// compile error.
fn hidden(comptime T: type, comptime what: []const u8, comptime where: []const u8) void {
    if (findRuleType(T)) |R| {
        const reach = if (R == T) @typeName(T) ++ " declares" else @typeName(T) ++ " reaches " ++ @typeName(R) ++ ", which declares";
        @compileError("validator: " ++ where ++ ": " ++ what ++ " are not walked; " ++ reach ++ " field_rules or validateSelf that would be skipped");
    }
}

/// Zig names a struct declared in place, such as a field type
/// (`address: struct { ... }`), after its parent with a generated suffix:
/// `users.Request__struct_1234`, and a struct declared in place inside that
/// one gets a second suffix, so the last suffix decides. Errors name such a
/// struct by its path instead (`users.Request.address`). The suffix is a
/// convention of the compiler, not of the language; the fixture
/// `anonymous_struct_label` fails if a Zig release changes it.
fn isAnonymous(comptime T: type) bool {
    const name = @typeName(T);
    const at = std.mem.findLast(u8, name, "__struct_") orelse return false;
    const digits = name[at + "__struct_".len ..];
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The declaration checks of one walked struct, named `label` in errors: a
/// `validate` that is not a function, field names that would make paths
/// ambiguous, then `field_rules`.
fn checkStruct(comptime T: type, comptime label: []const u8) void {
    @setEvalBranchQuota(core.eval_quota);
    if (misnamedRules(T))
        @compileError("validator: " ++ label ++ ".validate: rules are declared in pub const field_rules; rename validate to field_rules (a pub fn validate is left to confy)");
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs) |name, attrs| {
        if (attrs.@"comptime") continue;
        if (std.mem.findAny(u8, name, ".[]") != null)
            @compileError("validator: " ++ label ++ "." ++ name ++ ": a field name with '.', '[' or ']' makes paths ambiguous; rename the field");
    }
    if (@hasDecl(T, "field_rules")) checkFieldRules(T, label);
    if (@hasDecl(T, "validateSelf")) checkValidateSelf(T, label);
}

/// `field_rules` is a struct literal whose keys are non-comptime fields of
/// `T` and whose values are rules that fit those fields.
fn checkFieldRules(comptime T: type, comptime label: []const u8) void {
    @setEvalBranchQuota(core.eval_quota);
    const R = @TypeOf(T.field_rules);
    const shape = @typeInfo(R);
    if (R == Rule or shape != .@"struct" or (shape.@"struct".is_tuple and shape.@"struct".field_names.len != 0)) {
        const got = if (shape == .@"struct" and shape.@"struct".is_tuple) "a tuple" else @typeName(R);
        @compileError("validator: " ++ label ++ ".field_rules: must be a struct literal .{ .field = rule or .{ rules } }, got " ++ got);
    }
    for (shape.@"struct".field_names) |key| {
        const where = label ++ ".field_rules." ++ key;
        if (fieldIndex(T, key) == null) @compileError("validator: " ++ where ++ ": no such field" ++ core.suggestion(T, key));
        if (isComptimeField(T, key)) @compileError("validator: " ++ where ++ ": comptime fields are not validated");
        core.checkRuleList(rulesFor(T, key, label), core.Unwrap(@FieldType(T, key)), where);
    }
}

/// `validateSelf` must be `pub fn validateSelf(self: *const T) ?Violation`;
/// an `inline fn` is accepted (only the parameter and return types are
/// compared). The body is then analyzed through a generated caller, so the
/// compile-time checks of `v.fail` inside it run under `assertRules` too
/// (taking `&T.validateSelf` would not analyze an inline body).
fn checkValidateSelf(comptime T: type, comptime label: []const u8) void {
    const F = @TypeOf(T.validateSelf);
    const ok = switch (@typeInfo(F)) {
        .@"fn" => |f| f.param_types.len == 1 and f.param_types[0] == *const T and
            f.return_type != null and f.return_type.? == ?Violation,
        else => false,
    };
    const self_type = if (isAnonymous(T)) "@This()" else @typeName(T);
    if (!ok) @compileError("validator: " ++ label ++ ".validateSelf: must be `pub fn validateSelf(self: *const " ++ self_type ++
        ") ?validator.Violation`, got " ++ @typeName(F));
    _ = &struct {
        fn call(self: *const T) ?Violation {
            return T.validateSelf(self);
        }
    }.call;
}

fn fieldIndex(comptime T: type, comptime name: []const u8) ?usize {
    for (@typeInfo(T).@"struct".field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) return i;
    }
    return null;
}

fn isComptimeField(comptime T: type, comptime name: []const u8) bool {
    const i = fieldIndex(T, name) orelse return false;
    return @typeInfo(T).@"struct".field_attrs[i].@"comptime";
}

/// The rules of field `name` of `T` as a slice, or none.
fn rulesFor(comptime T: type, comptime name: []const u8, comptime label: []const u8) []const Rule {
    if (!@hasDecl(T, "field_rules") or !@hasField(@TypeOf(T.field_rules), name)) return &.{};
    return core.toRules(@field(T.field_rules, name), label ++ ".field_rules." ++ name);
}

/// The indices of the fields of struct `T` that the walk visits, in
/// declaration order: not comptime, with rules in or below them.
fn walkedFields(comptime T: type) []const usize {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const info = @typeInfo(T).@"struct";
        var out: []const usize = &.{};
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (attrs.@"comptime") continue;
            if (rulesFor(T, name, @typeName(T)).len == 0 and !containsRules(F)) continue;
            out = out ++ &[_]usize{i};
        }
        return out;
    }
}

/// The names of the comptime fields of struct `T` (`comptime_fields` true)
/// or of its other fields.
fn fieldNames(comptime T: type, comptime comptime_fields: bool) []const []const u8 {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: []const []const u8 = &.{};
        for (info.field_names, info.field_attrs) |name, attrs| {
            if (attrs.@"comptime" == comptime_fields) out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

// ------------------------------------------------------------------ paths

const Segment = union(enum) { field: []const u8, index: usize };

/// The only place that produces path text: `.name` (no dot at the root) and
/// `[index]` (0-based decimal).
fn writeSegment(out: anytype, at_root: bool, segment: Segment) !void {
    switch (segment) {
        .field => |name| {
            if (!at_root) try out.writeAll(".");
            try out.writeAll(name);
        },
        .index => |index| {
            var digits: [20]u8 = undefined;
            var start: usize = digits.len;
            var rest = index;
            while (true) {
                start -= 1;
                digits[start] = @intCast('0' + rest % 10);
                rest /= 10;
                if (rest == 0) break;
            }
            try out.writeAll("[");
            try out.writeAll(digits[start..]);
            try out.writeAll("]");
        },
    }
}

// ------------------------------------------------------------------ sinks

/// `check`: the first violation; the path goes into the caller's buffer.
/// `len` is the logical path length: writes past the buffer are dropped, so
/// a path that fits after a longer sibling's overflow is still exact.
const First = struct {
    buf: []u8,
    len: usize = 0,
    found: ?Violation = null,

    const Error = error{};

    fn writeAll(sink: *First, bytes: []const u8) Error!void {
        if (sink.len < sink.buf.len) {
            const n = @min(bytes.len, sink.buf.len - sink.len);
            @memcpy(sink.buf[sink.len..][0..n], bytes[0..n]);
        }
        sink.len += bytes.len;
    }

    /// The mark that `pop` takes the path back to.
    fn pathLen(sink: *const First) usize {
        return sink.len;
    }

    fn push(sink: *First, segment: Segment) Error!void {
        try writeSegment(sink, sink.len == 0, segment);
    }

    fn pop(sink: *First, mark: usize) void {
        sink.len = mark;
    }

    /// Returns true: stop walking.
    fn report(sink: *First, code: []const u8, message: []const u8) Error!bool {
        const fits = sink.len != 0 and sink.len <= sink.buf.len;
        sink.found = .{ .code = code, .message = message, .field = if (fits) sink.buf[0..sink.len] else null };
        return true;
    }

    /// Violations reported so far: 0 or 1.
    fn count(sink: *const First) usize {
        return @intFromBool(sink.found != null);
    }
};

/// `checkAll`: every violation up to the cap; the paths and the list live
/// in the report's arena.
const All = struct {
    arena: Allocator,
    path: std.ArrayList(u8) = .empty,
    list: std.ArrayList(Violation) = .empty,
    truncated: bool = false,

    const Error = Allocator.Error;

    fn writeAll(sink: *All, bytes: []const u8) Error!void {
        try sink.path.appendSlice(sink.arena, bytes);
    }

    /// The mark that `pop` takes the path back to.
    fn pathLen(sink: *const All) usize {
        return sink.path.items.len;
    }

    fn push(sink: *All, segment: Segment) Error!void {
        try writeSegment(sink, sink.path.items.len == 0, segment);
    }

    fn pop(sink: *All, mark: usize) void {
        sink.path.shrinkRetainingCapacity(mark);
    }

    /// Returns true (stop) only when a violation beyond the cap shows up.
    fn report(sink: *All, code: []const u8, message: []const u8) Error!bool {
        if (sink.list.items.len == core.max_report_violations) {
            sink.truncated = true;
            return true;
        }
        const field: ?[]const u8 = if (sink.path.items.len == 0) null else try sink.arena.dupe(u8, sink.path.items);
        try sink.list.append(sink.arena, .{ .code = code, .message = message, .field = field });
        return false;
    }

    /// Violations kept so far.
    fn count(sink: *const All) usize {
        return sink.list.items.len;
    }
};

fn ErrorOf(comptime SinkPtr: type) type {
    return @typeInfo(SinkPtr).pointer.child.Error;
}

// ------------------------------------------------------------------ the walk

/// Walks the root of `check` and `checkAll` behind `value`, the pointer they
/// were given. A pointer that coerces to the `*const T` that the walk takes
/// is walked in place, an over-aligned or explicitly aligned one too (a
/// `std.heap.MemoryPool(T)` item is a `*align(N) T`, a pointer type of its
/// own). `*volatile T`, `*allowzero T`, an under-aligned `*align(1) const T`
/// and a bit pointer to a packed field do not coerce: such a root is walked
/// through a copy of its value, as walkStruct walks a packed or under-aligned
/// field, and the copy takes the whole value onto the stack.
fn walkRoot(comptime T: type, value: anytype, sink: anytype) ErrorOf(@TypeOf(sink))!bool {
    // A root without rules is never read: there is nothing to walk, an opaque
    // type has no value to copy, and inPlace would ask for its alignment.
    if (comptime !containsRules(T)) return false;
    if (comptime inPlace(@TypeOf(value), T)) return walkValue(T, value, &.{}, sink);
    const copy: T = value.*;
    return walkValue(T, &copy, &.{}, sink);
}

/// `P`, a single-item pointer to `T`, coerces to `*const T`: it is neither
/// volatile nor allowzero, points into the generic address space, is aligned
/// at least as `T`, and is not a bit pointer (rebuilt from its attributes, a
/// bit pointer gives another type).
fn inPlace(comptime P: type, comptime T: type) bool {
    const p = @typeInfo(P).pointer;
    if (p.attrs.@"volatile" or p.attrs.@"allowzero") return false;
    if ((p.attrs.@"addrspace" orelse .generic) != .generic) return false;
    if ((p.attrs.@"align" orelse @alignOf(T)) < @alignOf(T)) return false;
    return P == @Pointer(.one, p.attrs, T, null);
}

/// Walks one value: its own rules left to right (the first failure is its
/// only violation and nothing inside it is visited); then, if all passed,
/// its items (with the list's `each` rules) or its fields. Returns true when
/// the sink wants to stop.
fn walkValue(comptime T: type, value: *const T, comptime rules: []const Rule, sink: anytype) ErrorOf(@TypeOf(sink))!bool {
    @setEvalBranchQuota(core.eval_quota);
    if (@typeInfo(T) == .optional) {
        const payload = if (value.*) |*p| p else return false;
        return walkValue(@typeInfo(T).optional.child, payload, rules, sink);
    }
    inline for (comptime core.ownRules(rules)) |rule| {
        switch (rule.eval(value)) {
            .pass => {},
            .fail => return sink.report(rule.code, rule.message),
            .precondition => if (comptime rule.precondition) |p| return sink.report(p.code, p.message) else unreachable,
        }
    }
    if (comptime core.ListChild(T)) |Child| {
        const item_rules = comptime core.itemRules(rules);
        if (comptime (item_rules.len == 0 and !containsRules(Child))) return false;
        const items: []const Child = if (@typeInfo(T) == .array) value else value.*;
        for (items, 0..) |*item, i| {
            const mark = sink.pathLen();
            defer sink.pop(mark);
            try sink.push(.{ .index = i });
            if (try walkValue(Child, item, item_rules, sink)) return true;
        }
        return false;
    }
    if (comptime isWalkedStruct(T)) return walkStruct(T, value, sink);
    return false;
}

/// Walks the fields of a struct in declaration order; comptime fields and
/// fields with no rules in or below them are skipped.
fn walkStruct(comptime T: type, value: *const T, sink: anytype) ErrorOf(@TypeOf(sink))!bool {
    @setEvalBranchQuota(core.eval_quota);
    const info = @typeInfo(T).@"struct";
    const before = sink.count();
    // The loop is unrolled, and each unrolled copy gets stack slots of its
    // own, so the frame grows with every unrolled field: fields without rules
    // are not unrolled, the mark is taken once (every field is pushed onto the
    // same path), and push returns nothing.
    const mark = sink.pathLen();
    inline for (comptime walkedFields(T)) |i| {
        const name = info.field_names[i];
        const F = info.field_types[i];
        const attrs = info.field_attrs[i];
        const rules = comptime rulesFor(T, name, @typeName(T));
        defer sink.pop(mark);
        try sink.push(.{ .field = name });
        // A packed field has a bit pointer, and a field declared below the
        // alignment of its type (`n: u32 align(1)`) an under-aligned one:
        // neither coerces to `*const F`, so such a field is walked as a copy,
        // which takes the whole field onto the stack.
        const by_copy = comptime (info.layout == .@"packed" or (attrs.@"align" != null and attrs.@"align".? < @alignOf(F)));
        const stop = if (by_copy) blk: {
            const copy: F = @field(value.*, name);
            break :blk try walkValue(F, &copy, rules, sink);
        } else try walkValue(F, &@field(value.*, name), rules, sink);
        if (stop) return true;
    }
    // validateSelf runs only when nothing in this struct's subtree failed.
    if (@hasDecl(T, "validateSelf") and sink.count() == before) {
        if (T.validateSelf(value)) |violation| return reportSelf(T, violation, sink);
    }
    return false;
}

/// Checks a `validateSelf` result at run time, because a hand-built result
/// is not checked by the compiler: the code follows the custom-code grammar,
/// the message is 1-512 bytes of valid UTF-8, and `field` is null or the name
/// of a non-comptime field of `T`. The result is reported at the struct's
/// path plus that field name taken from `T`, so the path never points into
/// the caller's memory. A malformed result is a programmer error: Debug
/// builds panic; other modes report `validation.invalid` / "is invalid" at
/// the struct's path, so the value is rejected, not accepted.
fn reportSelf(comptime T: type, violation: Violation, sink: anytype) ErrorOf(@TypeOf(sink))!bool {
    if (core.codeProblem(violation.code) != null) {
        if (builtin.mode == .debug)
            std.debug.panic("validator: {s}.validateSelf returned a malformed violation: code \"{f}\" is not a valid custom code", .{ @typeName(T), std.zig.fmtString(violation.code) });
        return sink.report("validation.invalid", "is invalid");
    }
    if (core.messageProblem(violation.message) != null) {
        if (builtin.mode == .debug)
            std.debug.panic("validator: {s}.validateSelf returned a malformed violation: its message is not 1-{d} bytes of valid UTF-8", .{ @typeName(T), core.max_message_bytes });
        return sink.report("validation.invalid", "is invalid");
    }
    const field = violation.field orelse return sink.report(violation.code, violation.message);
    // Run-time loops over the names: unrolling them would give every field its
    // own stack slots.
    for (comptime fieldNames(T, false)) |name| {
        if (std.mem.eql(u8, name, field)) {
            const mark = sink.pathLen();
            defer sink.pop(mark);
            try sink.push(.{ .field = name });
            return sink.report(violation.code, violation.message);
        }
    }
    if (builtin.mode == .debug) {
        for (comptime fieldNames(T, true)) |name| {
            if (std.mem.eql(u8, name, field))
                std.debug.panic("validator: {s}.validateSelf returned a malformed violation: field \"{f}\" is a comptime field of {s}; comptime fields are not validated", .{ @typeName(T), std.zig.fmtString(field), @typeName(T) });
        }
        std.debug.panic("validator: {s}.validateSelf returned a malformed violation: field \"{f}\" is not a field of {s}", .{ @typeName(T), std.zig.fmtString(field), @typeName(T) });
    }
    return sink.report("validation.invalid", "is invalid");
}
