//! The walker, the public entry points built on it, and the declaration
//! checks of every type the walker visits.
//!
//! Before walking, an entry point runs `verify(T)` at comptime: the checks of
//! `T` and of each type the walk can reach from it, each type once. The walk
//! runs a value's own rules left to right, reports the first one that fails
//! as the value's only violation, and descends into the value (the items of
//! a list, the fields of a struct) only when they all passed.
const std = @import("std");
const core = @import("core.zig");
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
    _ = walkValue(T, value, &.{}, &sink) catch |err| switch (err) {};
    return sink.found;
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

/// Every compile-time check of `Root` and of each type the walker visits
/// from it. Each type is checked once (one `done` list per root).
fn verify(comptime Root: type) void {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        _ = visit(Root, @typeName(Root), &.{}, &.{});
    }
}

/// `where` is the path of this type for error messages (`Type.field[]`),
/// `stack` the structs being visited (a struct met again on it contains
/// itself, which is not supported), `done` the structs already checked.
/// Returns `done` plus the structs checked here.
fn visit(comptime T: type, comptime where: []const u8, comptime stack: []const type, comptime done: []const type) []const type {
    @setEvalBranchQuota(core.eval_quota);
    switch (@typeInfo(T)) {
        .optional => |o| return visit(o.child, where, stack, done),
        .array => |a| return visit(a.child, where ++ "[]", stack, done),
        .pointer => {
            if (core.isString(T)) return done; // a string: a leaf
            if (core.ListChild(T)) |Item| return visit(Item, where ++ "[]", stack, done);
            // Any other pointer is not walked.
        },
        .@"struct" => |s| {
            if (s.is_tuple) return done; // tuples are not walked
            if (!containsRules(T) or includes(done, T)) return done;
            if (includes(stack, T))
                @compileError("validator: " ++ where ++ ": recursive types are not supported; " ++ @typeName(T) ++ " contains itself");
            const label = @typeName(T);
            checkStruct(T, label);
            var finished = done;
            for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (!attrs.@"comptime") finished = visit(F, label ++ "." ++ name, stack ++ &[_]type{T}, finished);
            }
            return finished ++ &[_]type{T};
        },
        // Unions, enums, opaque types, vectors and error unions are not walked.
        else => {},
    }
    return done;
}

/// The checks of one visited struct; `label` names it in errors.
fn checkStruct(comptime T: type, comptime label: []const u8) void {
    @setEvalBranchQuota(core.eval_quota);
    if (@hasDecl(T, "field_rules")) checkFieldRules(T, label);
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

    fn push(sink: *First, segment: Segment) Error!usize {
        const mark = sink.len;
        try writeSegment(sink, mark == 0, segment);
        return mark;
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
};

fn ErrorOf(comptime SinkPtr: type) type {
    return @typeInfo(SinkPtr).pointer.child.Error;
}

// ------------------------------------------------------------------ the walk

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
            const mark = try sink.push(.{ .index = i });
            defer sink.pop(mark);
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
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        if (attrs.@"comptime") continue;
        const rules = comptime rulesFor(T, name, @typeName(T));
        if (comptime (rules.len == 0 and !containsRules(F))) continue;
        const mark = try sink.push(.{ .field = name });
        defer sink.pop(mark);
        // A packed field has a bit pointer, and a field declared below the
        // alignment of its type (`n: u32 align(1)`) an under-aligned one:
        // neither coerces to `*const F`, so such a field is walked as a copy.
        const by_copy = comptime (info.layout == .@"packed" or (attrs.@"align" != null and attrs.@"align".? < @alignOf(F)));
        const stop = if (by_copy) blk: {
            const copy: F = @field(value.*, name);
            break :blk try walkValue(F, &copy, rules, sink);
        } else try walkValue(F, &@field(value.*, name), rules, sink);
        if (stop) return true;
    }
    return false;
}
