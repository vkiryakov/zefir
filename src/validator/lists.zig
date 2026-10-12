//! List rules: `minItems`, `maxItems`, `uniqueItems`, `uniqueBy` and `each`.
//! A list is a slice whose items are not `u8`, or an array `[N]T` (`[N]u8`
//! included: it is an array of numbers).
const std = @import("std");
const core = @import("core.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

fn acceptsList(comptime T: type) bool {
    return core.ListChild(T) != null;
}

// ------------------------------------------------------------------ minItems, maxItems

/// `len >= min` on a slice: items are counted, null items included, never
/// checked. `min` is at least 1 (`minItems(0)` is always true). `v.notEmpty`
/// says the same as `minItems(1)` with its own code: prefer `v.notEmpty`
/// unless clients branch on `validation.min_items`. A fixed-size array `[N]T`
/// is a compile error: its length never changes.
pub fn minItems(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.min_items, min)) |text| @compileError(text);
    return countRule(.min_items, min, "must have at least " ++ core.plural(min, "item", "items"), "min");
}

/// `len <= max` on a slice, null items included. `max` is at least 1: for
/// no items use `v.empty`. A fixed-size array `[N]T` is a compile error.
pub fn maxItems(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.max_items, max)) |text| @compileError(text);
    return countRule(.max_items, max, "must have at most " ++ core.plural(max, "item", "items"), "max");
}

/// The error of the call `minItems(n)` or `maxItems(n)`, or null: the count
/// is at least 1.
fn countCallProblem(comptime kind: core.Kind, comptime n: usize) ?[]const u8 {
    if (n != 0) return null;
    return switch (kind) {
        .min_items => "validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)",
        .max_items => "validator: maxItems(0): max must be at least 1; " ++ core.hints.use_empty,
        else => @compileError("validator: internal: " ++ @tagName(kind) ++ " is not a count rule"),
    };
}

/// `minItems(n)` or `maxItems(n)`, whose count is the placeholder `name`.
fn countRule(comptime kind: core.Kind, comptime n: usize, comptime message: []const u8, comptime name: []const u8) Rule {
    return core.define(kind, .{
        .message = message,
        .args = core.renderArg(n),
        .params = &.{core.param(name, n)},
        .bounds = &.{if (kind == .min_items) .atLeast(.items, n) else .atMost(.items, n)},
        .fits = countFits(n),
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(if (kind == .min_items) value.*.len >= n else value.*.len <= n);
            }
        }.eval,
    });
}

/// The field-type check of `minItems(n)` and `maxItems(n)`.
fn countFits(comptime n: usize) fn (comptime *const Rule, comptime type, comptime []const u8) void {
    return struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (countProblem(rule, n, T, where)) |text| @compileError(text);
        }
    }.fits;
}

/// The declaration error of `minItems(n)` or `maxItems(n)` on the unwrapped
/// field type `T`, or null: the field is a slice that is not a string. On a
/// fixed-size array the verdict never changes, so the error says which it
/// is; a string field gets the string rules as the hint.
fn countProblem(comptime rule: *const Rule, comptime n: usize, comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = if (rule.kind == .min_items) a.len >= n else a.len <= n;
            return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++ ": the length of an array is fixed");
        },
        else => {},
    }
    if (core.isListSlice(T)) return null;
    const strings = if (rule.kind == .min_items) core.hints.min_items_on_string else core.hints.max_items_on_string;
    return core.typeErrorText(rule, T, where, "a slice", core.isListSlice, if (core.isString(T)) strings else null);
}

// ------------------------------------------------------------------ uniqueItems, uniqueBy

/// No two items are equal: bools, enums and integers by value (exactly, at
/// every width; a non-exhaustive enum by its integer), strings byte for byte,
/// without case folding or normalization. Bools and exhaustive enums are
/// checked with a bitset in O(n), at any length. Integers, strings and
/// non-exhaustive enums are sorted on the stack in O(n log n), without
/// allocating: on a slice an earlier `v.maxItems(n)` in the same tuple must
/// cap the list at `max_unique_items` (1000), and on `[N]T` N must be at most
/// 1000. Float, optional, struct and other items are compile errors (for
/// structs use `v.uniqueBy`), and so is `[N]T` with N below 2 (always true)
/// or with more items than the item type has values (always false).
pub const uniqueItems: Rule = core.define(.unique_items, .{
    .message = "must not contain duplicates",
    .fits = struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (uniqueItemsProblem(rule, T, where)) |text| @compileError(text);
        }
    }.fits,
    .check_list = capCheck(null),
    .eval = uniqueEval(null),
});

/// No two struct items have equal values of the field `key`, written as a
/// field name: `v.uniqueBy(.id)`. Only the key is compared, as `uniqueItems`
/// compares items, with the same cap by the key's type; the key is a bool,
/// enum, integer or string field that is not comptime. The code is
/// `validation.unique_items`, as for `uniqueItems`; the message names the
/// key, which is also the placeholder `{key}`.
pub fn uniqueBy(comptime key: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (keyCallProblem(key)) |text| @compileError(text);
    const name = @tagName(key);
    return core.define(.unique_by, .{
        .message = "must not contain duplicate " ++ core.renderValue(key) ++ " values",
        .args = core.renderArg(key),
        .params = &.{core.param("key", key)},
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (uniqueByProblem(rule, name, T, where)) |text| @compileError(text);
            }
        }.fits,
        .check_list = capCheck(name),
        .eval = uniqueEval(name),
    });
}

/// The error of the call `uniqueBy(key)`, or null: the key is a field name
/// written as an enum literal.
fn keyCallProblem(comptime key: anytype) ?[]const u8 {
    const K = @TypeOf(key);
    if (@typeInfo(K) == .enum_literal) return null;
    return "validator: uniqueBy(" ++ core.renderArg(key) ++ "): the key must be a field name such as .id, got " ++ @typeName(K);
}

/// The declaration error of `uniqueItems` on the unwrapped field type `T`,
/// or null: a list of bools, enums, integers or strings, and on `[N]T` a
/// length the rule can decide at run time.
fn uniqueItemsProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const Item = core.ListChild(T) orelse return core.typeErrorText(rule, T, where, "a slice or an array", acceptsList, null);
    const struct_text = "; struct items are not supported; " ++ core.hints.use_unique_by;
    if (keyTypeProblem(Item, "items are " ++ @typeName(Item), "items", struct_text)) |text| return core.ruleErrorText(rule, where, text);
    return uniqueArrayProblem(rule, T, Item, where);
}

/// The declaration error of `uniqueBy(.name)` on the unwrapped field type
/// `T`, or null: a list of structs whose non-comptime field `name` is a bool,
/// enum, integer or string, and on `[N]T` a length the rule can decide.
fn uniqueByProblem(comptime rule: *const Rule, comptime name: []const u8, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const Item = core.ListChild(T) orelse return core.typeErrorText(rule, T, where, "a slice or an array of structs", acceptsList, null);
    const not_structs = ": items are " ++ @typeName(Item) ++ ", not structs; " ++ core.hints.use_unique_items;
    switch (@typeInfo(Item)) {
        .@"struct" => |s| if (s.is_tuple) return core.ruleErrorText(rule, where, not_structs),
        .optional => return core.ruleErrorText(rule, where, ": items are " ++ @typeName(Item) ++ "; optional items are not supported"),
        else => return core.ruleErrorText(rule, where, not_structs),
    }
    const shown = core.tagIdentifier(name);
    const info = @typeInfo(Item).@"struct";
    const index = for (info.field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) break i;
    } else return core.ruleErrorText(rule, where, ": " ++ @typeName(Item) ++ " has no field " ++ shown ++ core.suggestion(Item, name));
    if (info.field_attrs[index].@"comptime") return core.ruleErrorText(rule, where, ": " ++ shown ++ " is a comptime field");
    const Key = info.field_types[index];
    if (keyTypeProblem(Key, "the key " ++ shown ++ " is " ++ @typeName(Key), "keys", null)) |text| return core.ruleErrorText(rule, where, text);
    return uniqueArrayProblem(rule, T, Key, where);
}

/// Why the compared values of type `K` (`noun`: "items" or "keys") cannot
/// be checked for uniqueness, as the text after the rule's label, or null:
/// they are bools, enums, integers or strings. `what` names them
/// (`items are f64`); `struct_text` is the text for structs, null for the
/// general one.
fn keyTypeProblem(comptime K: type, comptime what: []const u8, comptime noun: []const u8, comptime struct_text: ?[]const u8) ?[]const u8 {
    if (core.isString(K)) return null;
    const other = ": " ++ what ++ "; only bool, enum, integer and string " ++ noun ++ " are supported";
    return switch (@typeInfo(K)) {
        .bool, .int, .@"enum" => null,
        .float => ": " ++ what ++ "; float " ++ noun ++ " are not supported (NaN != NaN, -0.0 == 0.0)",
        .optional => ": " ++ what ++ "; optional " ++ noun ++ " are not supported",
        .@"struct" => |s| if (s.is_tuple) other else if (struct_text) |text| ": " ++ what ++ text else other,
        else => other,
    };
}

/// The declaration error of a uniqueness rule on `[N]T` with compared values
/// of type `K`, or null; a slice has none here. N below 2 is always true, N
/// above the number of values of `K` always false, and a sorted `K` needs N
/// to be at most `max_unique_items`.
fn uniqueArrayProblem(comptime rule: *const Rule, comptime T: type, comptime K: type, comptime where: []const u8) ?[]const u8 {
    const n = switch (@typeInfo(T)) {
        .array => |a| a.len,
        else => return null,
    };
    if (n <= 1) return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always true; remove it");
    if (n > valueCount(K)) return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" on {s} is always false: {d} items cannot all differ", .{ @typeName(T), n }));
    if (needsCap(K) and n > core.max_unique_items)
        return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" on {s}: {d} items is more than max_unique_items ({d})", .{ @typeName(T), n, core.max_unique_items }));
    return null;
}

/// How many different values of type `K` a list may hold: 2 for bool, the
/// number of tags of an exhaustive enum, every value of an integer type;
/// unbounded otherwise.
fn valueCount(comptime K: type) comptime_int {
    if (K == bool) return 2;
    return switch (@typeInfo(K)) {
        .@"enum" => |e| if (e.mode == .exhaustive) e.field_names.len else std.math.maxInt(e.tag_type) - std.math.minInt(e.tag_type) + 1,
        .int => std.math.maxInt(K) - std.math.minInt(K) + 1,
        else => std.math.maxInt(u128),
    };
}

/// Integers, strings and non-exhaustive enums are sorted on the stack, so
/// their lists are capped; bools and exhaustive enums use a bitset.
fn needsCap(comptime K: type) bool {
    return K != bool and !core.isExhaustiveEnum(K);
}

/// The type a uniqueness rule compares: the item, or its field `key`.
fn KeyOf(comptime Item: type, comptime key: ?[]const u8) type {
    return if (key) |name| @FieldType(Item, name) else Item;
}

/// The list check of `uniqueItems` (`key` null) and `uniqueBy(.key)`: a
/// slice whose compared values are sorted needs an earlier `maxItems(n)`
/// with `n <= max_unique_items` in the same tuple; the smallest earlier one
/// counts.
fn capCheck(comptime key: ?[]const u8) core.ListCheck {
    return struct {
        fn check(comptime rule: *const Rule, comptime rules: []const Rule, comptime index: usize, comptime T: type, comptime where: []const u8) void {
            if (capProblem(rule, rules[0..index], KeyOf(core.ListChild(T).?, key), T, where)) |text| @compileError(text);
        }
    }.check;
}

/// The cap error of a uniqueness rule that compares values of type `K` on
/// the unwrapped field type `T`, after the rules `earlier`, or null.
fn capProblem(comptime rule: *const Rule, comptime earlier: []const Rule, comptime K: type, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    if (!core.isListSlice(T) or !needsCap(K)) return null;
    var cap: ?comptime_int = null;
    var source: []const u8 = "";
    for (earlier) |*other| {
        for (other.bounds) |bound| {
            if (bound.measure != .items or bound.side != .upper) continue;
            const n: comptime_int = if (bound.inclusive) bound.value.int else bound.value.int - 1;
            if (cap == null or n < cap.?) {
                cap = n;
                source = other.label();
            }
        }
    }
    const n = cap orelse return core.ruleErrorText(rule, where, " " ++ core.hints.unique_cap);
    if (n > core.max_unique_items)
        return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" after {s}: {d} is more than max_unique_items ({d})", .{ source, n, core.max_unique_items }));
    return null;
}

/// The run-time check of `uniqueItems` (`key` null) and `uniqueBy(.key)`.
fn uniqueEval(comptime key: ?[]const u8) fn (anytype) Outcome {
    return struct {
        fn eval(value: anytype) Outcome {
            const T = @TypeOf(value.*);
            const Item = core.ListChild(T) orelse @compileError("validator: internal: a uniqueness rule's eval was instantiated for a type its fits rejected");
            const K = KeyOf(Item, key);
            const items: []const Item = if (@typeInfo(T) == .array) value else value.*;
            const length: ?usize = if (@typeInfo(T) == .array) @typeInfo(T).array.len else null;
            return core.passIf(allUnique(Item, K, keyFn(Item, key), items, length));
        }
    }.eval;
}

/// The function that reads the compared value of an item.
fn keyFn(comptime Item: type, comptime key: ?[]const u8) fn (*const Item) KeyOf(Item, key) {
    return struct {
        fn get(item: *const Item) KeyOf(Item, key) {
            return if (key) |name| @field(item.*, name) else item.*;
        }
    }.get;
}

/// Lists of up to this many items are sorted in small buffers.
const short_list = 64;

/// No two of `items` have equal keys. Bools and exhaustive enums: a bitset,
/// O(n). Other keys are sorted on the stack by `sortedUnique`, which only a
/// list of 2 or more items reaches: a slice of up to `short_list` items in
/// buffers of that size, a longer one in buffers of `max_unique_items`, and
/// `[N]T` (`length` N) in buffers of N. A list longer than
/// `max_unique_items` fails: the declaration checks keep lists shorter, and
/// a list that got past them is rejected rather than accepted unchecked.
fn allUnique(comptime Item: type, comptime K: type, comptime key: fn (*const Item) K, items: []const Item, comptime length: ?usize) bool {
    if (K == bool) {
        var seen = [2]bool{ false, false };
        for (items) |*item| {
            const i = @intFromBool(key(item));
            if (seen[i]) return false;
            seen[i] = true;
        }
        return true;
    }
    if (comptime core.isExhaustiveEnum(K)) {
        var seen: std.bit_set.Static(@typeInfo(K).@"enum".field_names.len) = .empty;
        for (items) |*item| {
            const i = tagIndex(K, key(item));
            if (seen.isSet(i)) return false;
            seen.set(i);
        }
        return true;
    }
    if (items.len < 2) return true;
    if (items.len > core.max_unique_items) return false;
    if (length) |n| return sortedUnique(n, Item, K, key, items);
    if (items.len <= short_list) return sortedUnique(short_list, Item, K, key, items);
    return sortedUnique(core.max_unique_items, Item, K, key, items);
}

/// No two of `items`, 2 to `capacity` of them, have equal keys: their
/// indexes, sorted on the stack by key, have no two equal neighbours.
/// Strings are sorted by their 64-bit Wyhash, then by bytes, so only strings
/// with equal hashes are compared byte for byte; integers and non-exhaustive
/// enums by value. `noinline`, so that the walk does not keep the buffers'
/// frame while it visits the items of nested lists.
noinline fn sortedUnique(comptime capacity: usize, comptime Item: type, comptime K: type, comptime key: fn (*const Item) K, items: []const Item) bool {
    var index_buf: [capacity]u16 = undefined;
    const order = index_buf[0..items.len];
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    if (comptime core.isString(K)) {
        var hash_buf: [capacity]u64 = undefined;
        const hashes = hash_buf[0..items.len];
        for (items, hashes) |*item, *hash| hash.* = std.hash.Wyhash.hash(0, key(item));
        const ByHash = struct { items: []const Item, hashes: []const u64 };
        std.mem.sortUnstable(u16, order, ByHash{ .items = items, .hashes = hashes }, struct {
            fn lessThan(by: ByHash, a: u16, b: u16) bool {
                if (by.hashes[a] != by.hashes[b]) return by.hashes[a] < by.hashes[b];
                return std.mem.order(u8, key(&by.items[a]), key(&by.items[b])) == .lt;
            }
        }.lessThan);
        for (order[0 .. order.len - 1], order[1..]) |a, b| {
            if (hashes[a] == hashes[b] and std.mem.eql(u8, key(&items[a]), key(&items[b]))) return false;
        }
        return true;
    }
    std.mem.sortUnstable(u16, order, items, struct {
        fn lessThan(list: []const Item, a: u16, b: u16) bool {
            return ordinal(key(&list[a])) < ordinal(key(&list[b]));
        }
    }.lessThan);
    for (order[0 .. order.len - 1], order[1..]) |a, b| {
        if (ordinal(key(&items[a])) == ordinal(key(&items[b]))) return false;
    }
    return true;
}

/// An integer as it is, a non-exhaustive enum by its integer value.
fn ordinal(x: anytype) switch (@typeInfo(@TypeOf(x))) {
    .@"enum" => |e| e.tag_type,
    else => @TypeOf(x),
} {
    return switch (@typeInfo(@TypeOf(x))) {
        .@"enum" => @backingInt(x),
        else => x,
    };
}

/// The bit of an exhaustive enum's tag: its rank among the tags by value,
/// found at compile time for each tag (an `inline else` prong), so sparse
/// tag values need no larger bitset.
fn tagIndex(comptime E: type, tag: E) usize {
    switch (tag) {
        inline else => |t| return comptime valueRank(E, @backingInt(t)),
    }
}

/// The number of tags of `E` whose value is below `value`.
fn valueRank(comptime E: type, comptime value: comptime_int) usize {
    const values = sortedTagValues(E);
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (values[mid] < value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The values of the tags of `E`, in increasing order.
fn sortedTagValues(comptime E: type) []const comptime_int {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const e = @typeInfo(E).@"enum";
        var values = e.field_values[0..e.field_names.len].*;
        std.mem.sortUnstable(comptime_int, &values, {}, struct {
            fn lessThan(_: void, a: comptime_int, b: comptime_int) bool {
                return a < b;
            }
        }.lessThan);
        const final = values;
        return &final;
    }
}

// ------------------------------------------------------------------ each

/// The rules for every item of a slice or an array: one rule or a tuple of
/// rules. It declares item rules rather than checking the list: it must be
/// the last rule of its tuple and appear once, and it has no code or message
/// of its own. Null items are skipped; item paths are `tags[3]`.
pub fn each(comptime rules: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const inner = core.toRules(rules, "each(...)");
    if (inner.len == 0) @compileError("validator: each(.{}): the list is empty");
    return .{
        .kind = .each,
        .code = "",
        .message = "",
        .args = "...",
        .inner = inner,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                const Item = core.ListChild(T) orelse core.typeError(rule, T, where, "a slice or an array", acceptsList, null);
                core.checkRuleList(rule.inner, core.Unwrap(Item), where ++ "[]");
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                _ = value;
                @compileError("validator: internal: each is applied by the walker and never evaluated");
            }
        }.eval,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `each must be called, e.g. v.each(v.notEmpty)`.
pub const call_examples = .{ .minItems = "1", .maxItems = "100", .uniqueBy = ".id", .each = "v.notEmpty" };

const expectOutcome = core.expectOutcome;

/// A struct for the tests below.
const Record = struct { id: u32 };

const test_where = "Dto.field_rules.x";

/// The declaration error of `minItems(n)` or `maxItems(n)` on a field of
/// type `T`, or null.
fn minItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&minItems(n), n, T, test_where);
}

fn maxItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&maxItems(n), n, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "minItems and maxItems have their documented codes, messages and count parameters and no precondition" {
    const t = std.testing;
    const at_least = minItems(2);
    try t.expectEqual(core.Kind.min_items, at_least.kind);
    try t.expectEqualStrings("validation.min_items", at_least.code);
    try t.expectEqualStrings("must have at least 2 items", at_least.message);
    try t.expectEqualStrings("2", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("2", at_least.params[0].text);
    try t.expect(at_least.params[0].placeholder);
    try t.expect(comptime at_least.params[0].value.int == 2);
    try t.expectEqual(null, at_least.precondition);
    try t.expectEqualStrings("minItems(2)", comptime at_least.call());
    try t.expectEqualStrings("min_items(2)", comptime at_least.label());

    const at_most = maxItems(100);
    try t.expectEqual(core.Kind.max_items, at_most.kind);
    try t.expectEqualStrings("validation.max_items", at_most.code);
    try t.expectEqualStrings("must have at most 100 items", at_most.message);
    try t.expectEqualStrings("100", at_most.args.?);
    try t.expectEqual(1, at_most.params.len);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("100", at_most.params[0].text);
    try t.expect(at_most.params[0].placeholder);
    try t.expectEqual(null, at_most.precondition);
    try t.expectEqualStrings("max_items(100)", comptime at_most.label());

    // One item is singular; counts are decimal at every size.
    try t.expectEqualStrings("must have at least 1 item", minItems(1).message);
    try t.expectEqualStrings("must have at most 1 item", maxItems(1).message);
    try t.expectEqualStrings("must have at most 18446744073709551615 items", maxItems(std.math.maxInt(u64)).message);
}

test "minItems and maxItems take a count of at least 1" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)", comptime countCallProblem(.min_items, 0).?);
    try expect("validator: maxItems(0): max must be at least 1; use v.empty", comptime countCallProblem(.max_items, 0).?);
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.max_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, std.math.maxInt(usize)));
}

test "minItems and maxItems on a fixed-size array are errors: its length never changes" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const fixed = ": the length of an array is fixed";
    try expect(head ++ "min_items(1) on [3]u32 is always true" ++ fixed, comptime minItemsText(1, [3]u32).?);
    try expect(head ++ "min_items(3) on [3]u32 is always true" ++ fixed, comptime minItemsText(3, [3]u32).?);
    try expect(head ++ "min_items(4) on [3]u32 is always false" ++ fixed, comptime minItemsText(4, [3]u32).?);
    try expect(head ++ "min_items(1) on [0]u32 is always false" ++ fixed, comptime minItemsText(1, [0]u32).?);
    try expect(head ++ "max_items(2) on [3]u32 is always false" ++ fixed, comptime maxItemsText(2, [3]u32).?);
    try expect(head ++ "max_items(3) on [3]u32 is always true" ++ fixed, comptime maxItemsText(3, [3]u32).?);
    try expect(head ++ "max_items(1) on [0]u32 is always true" ++ fixed, comptime maxItemsText(1, [0]u32).?);
    try expect(head ++ "min_items(2) on [3:0]u32 is always true" ++ fixed, comptime minItemsText(2, [3:0]u32).?);
    try expect(head ++ "max_items(1) on [2][]const u8 is always false" ++ fixed, comptime maxItemsText(1, [2][]const u8).?);
    // [N]u8 is an array too; these rules take no strings, so no string hint follows.
    try expect(head ++ "min_items(1) on [4]u8 is always true" ++ fixed, comptime minItemsText(1, [4]u8).?);
}

test "minItems and maxItems take slices; a string field gets the string rules as the hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const min_strings = "; for strings use v.minLength or v.minBytes";
    const max_strings = "; for strings use v.maxLength or v.maxBytes";
    try expect(head ++ "min_items expects a slice, field is []const u8" ++ min_strings, comptime minItemsText(1, []const u8).?);
    try expect(head ++ "min_items expects a slice, field is [:0]u8" ++ min_strings, comptime minItemsText(1, [:0]u8).?);
    try expect(head ++ "max_items expects a slice, field is []const u8" ++ max_strings, comptime maxItemsText(3, []const u8).?);
    try expect(head ++ "max_items expects a slice, field is []u8" ++ max_strings, comptime maxItemsText(3, []u8).?);
    try expect(head ++ "min_items expects a slice, field is u32", comptime minItemsText(1, u32).?);
    try expect(head ++ "max_items expects a slice, field is u32", comptime maxItemsText(3, u32).?);
    try expect(head ++ "min_items expects a slice, field is lists.Record", comptime minItemsText(1, Record).?);
    try expect(head ++ "max_items expects a slice, field is *const [3]u32", comptime maxItemsText(3, *const [3]u32).?);
    try expect(
        head ++ "min_items expects a slice, field is []volatile u32; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime minItemsText(1, []volatile u32).?,
    );
    inline for (.{ []const u32, []u32, [:0]const u32, []const ?u32, []const []const u8, [][]u32, []const Record, []const f64 }) |T| {
        try std.testing.expectEqual(null, comptime minItemsText(1, T));
        try std.testing.expectEqual(null, comptime maxItemsText(1, T));
    }
}

test "an uncalled minItems or maxItems gets an example call, and inside each the head is each(...)" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: minItems must be called, e.g. v.minItems(1)", comptime uncalledText("minItems", @TypeOf(minItems)));
    try expect("validator: Dto.field_rules.x: maxItems must be called, e.g. v.maxItems(100)", comptime uncalledText("maxItems", @TypeOf(maxItems)));
    // each checks its argument when it is called, before the field is known.
    try expect("validator: each(...): minItems must be called, e.g. v.minItems(1)", "validator: each(...): " ++ comptime core.hints.mustBeCalled("minItems", @TypeOf(minItems)));
}

test "minItems and maxItems count the items of a slice, null items included" {
    try expectOutcome(.fail, minItems(2), @as([]const u32, &.{1}));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2, 3 }));
    try expectOutcome(.fail, minItems(1), @as([]const []const u8, &.{}));
    try expectOutcome(.pass, minItems(1), @as([]const ?u32, &.{null}));
    try expectOutcome(.pass, maxItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.fail, maxItems(2), @as([]const ?u32, &.{ null, null, null }));
    try expectOutcome(.pass, maxItems(1), @as([]const u32, &.{}));
    try expectOutcome(.pass, maxItems(std.math.maxInt(usize)), @as([]const u32, &.{ 1, 2 }));
}

/// Types for the uniqueness tests: enums of every kind and a struct item
/// with keys of every kind.
const Role = enum { admin, user, guest };
const Sparse = enum(u32) { high = 1_000_000, low = 1, mid = 500 };
const Open = enum(u8) { a, b, _ };
const OpenWide = enum(u16) { a, _ };
const Line = struct {
    sku: []const u8,
    qty: u32 = 1,
    active: bool = true,
    role: Role = .user,
    comptime kind: u8 = 1,
    price: f64 = 0,
    ref: ?u32 = null,
    tags: []const []const u8 = &.{},
};

/// The declaration error of `uniqueItems` on a field of type `T`, or null.
fn uniqueItemsText(comptime T: type) ?[]const u8 {
    return uniqueItemsProblem(&uniqueItems, T, test_where);
}

/// The declaration error of `uniqueBy(key)` on a field of type `T`, or null.
fn uniqueByText(comptime key: @EnumLiteral(), comptime T: type) ?[]const u8 {
    return uniqueByProblem(&uniqueBy(key), @tagName(key), T, test_where);
}

/// The cap error of the last rule of `rules`, a uniqueness rule, on a field
/// of type `T`, or null.
fn capText(comptime rules: []const Rule, comptime T: type) ?[]const u8 {
    const rule = &rules[rules.len - 1];
    const Item = core.ListChild(T).?;
    const K = if (rule.kind == .unique_by) @FieldType(Item, rule.params[0].value.tag) else Item;
    return capProblem(rule, rules[0 .. rules.len - 1], K, T, test_where);
}

test "uniqueItems and uniqueBy share the code validation.unique_items; uniqueBy names its key in the message and in {key}" {
    const t = std.testing;
    try t.expectEqual(core.Kind.unique_items, uniqueItems.kind);
    try t.expectEqualStrings("validation.unique_items", uniqueItems.code);
    try t.expectEqualStrings("must not contain duplicates", uniqueItems.message);
    try t.expectEqual(null, uniqueItems.args);
    try t.expectEqual(0, uniqueItems.params.len);
    try t.expectEqual(null, uniqueItems.precondition);
    const by_email = uniqueBy(.email);
    try t.expectEqual(core.Kind.unique_by, by_email.kind);
    try t.expectEqualStrings("validation.unique_items", by_email.code);
    try t.expectEqualStrings("must not contain duplicate email values", by_email.message);
    try t.expectEqualStrings(".email", by_email.args.?);
    try t.expectEqualStrings("unique_by(.email)", comptime by_email.label());
    try t.expectEqual(1, by_email.params.len);
    try t.expectEqualStrings("key", by_email.params[0].name);
    try t.expectEqualStrings("email", by_email.params[0].text);
    try t.expect(by_email.params[0].placeholder);
    try t.expectEqual(null, by_email.precondition);
    // A key that is no plain identifier: escaped in the message, quoted in the call.
    try t.expectEqualStrings("must not contain duplicate a\\nb values", uniqueBy(.@"a\nb").message);
    try t.expectEqualStrings("unique_by(.@\"error\")", comptime uniqueBy(.@"error").label());
}

test "uniqueBy takes a field name written as an enum literal" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: uniqueBy(\"id\"): the key must be a field name such as .id, got *const [2:0]u8", comptime keyCallProblem("id").?);
    try expect("validator: uniqueBy(1): the key must be a field name such as .id, got comptime_int", comptime keyCallProblem(1).?);
    try expect("validator: uniqueBy(.user): the key must be a field name such as .id, got lists.Role", comptime keyCallProblem(Role.user).?);
    try std.testing.expectEqual(null, comptime keyCallProblem(.id));
}

test "uniqueItems takes lists of bools, enums, integers and strings" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_items";
    try expect(head ++ " expects a slice or an array, field is []const u8 (a string)", comptime uniqueItemsText([]const u8).?);
    try expect(head ++ " expects a slice or an array, field is u32", comptime uniqueItemsText(u32).?);
    try expect(head ++ ": items are f64; float items are not supported (NaN != NaN, -0.0 == 0.0)", comptime uniqueItemsText([]const f64).?);
    try expect(head ++ ": items are lists.Record; struct items are not supported; use v.uniqueBy(.field)", comptime uniqueItemsText([]const Record).?);
    try expect(head ++ ": items are ?u32; optional items are not supported", comptime uniqueItemsText([]const ?u32).?);
    try expect(head ++ ": items are []const u32; only bool, enum, integer and string items are supported", comptime uniqueItemsText([]const []const u32).?);
    try expect(head ++ ": items are struct { u32, u32 }; only bool, enum, integer and string items are supported", comptime uniqueItemsText([]const struct { u32, u32 }).?);
    try expect(head ++ ": items are [2]u8; only bool, enum, integer and string items are supported", comptime uniqueItemsText([3][2]u8).?);
    inline for (.{ []const u32, []i8, [:0]const u64, []const bool, []const Role, []const Sparse, []const Open, []const []const u8, [][:0]u8, []const u128, [4]u8, [2]bool, [3]Role }) |T| {
        try std.testing.expectEqual(null, comptime uniqueItemsText(T));
    }
}

test "uniqueItems on [N]T needs 2 to 1000 items, and no more than the item type has values" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_items on ";
    try expect(head ++ "[1]u32 is always true; remove it", comptime uniqueItemsText([1]u32).?);
    try expect(head ++ "[0][]const u8 is always true; remove it", comptime uniqueItemsText([0][]const u8).?);
    try expect(head ++ "[3]bool is always false: 3 items cannot all differ", comptime uniqueItemsText([3]bool).?);
    try expect(head ++ "[4]lists.Role is always false: 4 items cannot all differ", comptime uniqueItemsText([4]Role).?);
    try expect(head ++ "[3]u1 is always false: 3 items cannot all differ", comptime uniqueItemsText([3]u1).?);
    try expect(head ++ "[1001]u32: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001]u32).?);
    try expect(head ++ "[1001][]const u8: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001][]const u8).?);
    try expect(head ++ "[1001]lists.OpenWide: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001]OpenWide).?);
    // A non-exhaustive enum holds every value of its integer type: 256 for u8.
    try expect(head ++ "[257]lists.Open is always false: 257 items cannot all differ", comptime uniqueItemsText([257]Open).?);
    // Bitset items need no cap.
    try std.testing.expectEqual(null, comptime uniqueItemsText([1000]u32));
    try std.testing.expectEqual(null, comptime uniqueItemsText([2]u1));
    try std.testing.expectEqual(null, comptime uniqueItemsText([3]Sparse));
}

test "uniqueBy takes lists of structs whose key is a bool, enum, integer or string field" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_by";
    try expect(head ++ " expects a slice or an array of structs, field is lists.Line", comptime uniqueByText(.sku, Line).?);
    try expect(head ++ " expects a slice or an array of structs, field is []const u8 (a string)", comptime uniqueByText(.sku, []const u8).?);
    try expect(head ++ "(.id): items are u32, not structs; use v.uniqueItems", comptime uniqueByText(.id, []const u32).?);
    try expect(head ++ "(.id): items are struct { u32, u32 }, not structs; use v.uniqueItems", comptime uniqueByText(.id, []const struct { u32, u32 }).?);
    try expect(head ++ "(.id): items are ?lists.Record; optional items are not supported", comptime uniqueByText(.id, []const ?Record).?);
    try expect(head ++ "(.skus): lists.Line has no field skus; did you mean \"sku\"?", comptime uniqueByText(.skus, []const Line).?);
    try expect(head ++ "(.zzz): lists.Line has no field zzz", comptime uniqueByText(.zzz, []const Line).?);
    try expect(head ++ "(.kind): kind is a comptime field", comptime uniqueByText(.kind, []const Line).?);
    try expect(head ++ "(.price): the key price is f64; float keys are not supported (NaN != NaN, -0.0 == 0.0)", comptime uniqueByText(.price, []const Line).?);
    try expect(head ++ "(.ref): the key ref is ?u32; optional keys are not supported", comptime uniqueByText(.ref, []const Line).?);
    try expect(head ++ "(.tags): the key tags is []const []const u8; only bool, enum, integer and string keys are supported", comptime uniqueByText(.tags, []const Line).?);
    try expect(head ++ "(.sku) on [1]lists.Line is always true; remove it", comptime uniqueByText(.sku, [1]Line).?);
    try expect(head ++ "(.active) on [3]lists.Line is always false: 3 items cannot all differ", comptime uniqueByText(.active, [3]Line).?);
    try expect(head ++ "(.qty) on [1001]lists.Line: 1001 items is more than max_unique_items (1000)", comptime uniqueByText(.qty, [1001]Line).?);
    inline for (.{ []const Line, [2]Line, []Line }) |T| {
        try std.testing.expectEqual(null, comptime uniqueByText(.sku, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.qty, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.active, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.role, T));
    }
}

test "on a slice, integer, string and non-exhaustive enum items need an earlier maxItems(n) with n <= 1000" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const needs = " needs an earlier v.maxItems(n) with n <= 1000 (max_unique_items) in the same tuple";
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const u32).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const []const u8).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const Open).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{ minItems(1), uniqueItems }, []const u32).?);
    try expect(head ++ "unique_by(.sku)" ++ needs, comptime capText(&.{uniqueBy(.sku)}, []const Line).?);
    try expect(head ++ "unique_items after max_items(1001): 1001 is more than max_unique_items (1000)", comptime capText(&.{ maxItems(1001), uniqueItems }, []const u32).?);
    try expect(head ++ "unique_by(.qty) after max_items(5000): 5000 is more than max_unique_items (1000)", comptime capText(&.{ maxItems(5000), maxItems(9000), uniqueBy(.qty) }, []const Line).?);
    // The smallest earlier maxItems counts.
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(1000), uniqueItems }, []const u32));
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(5000), maxItems(10), uniqueItems }, []const u32));
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(50), uniqueBy(.sku) }, []const Line));
    // Bools and exhaustive enums, and arrays, need no maxItems.
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, []const bool));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, []const Role));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueBy(.role)}, []const Line));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueBy(.active)}, []const Line));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, [1000]u32));
}

test "an uncalled uniqueBy gets an example call" {
    try std.testing.expectEqualStrings("validator: Dto.field_rules.x: uniqueBy must be called, e.g. v.uniqueBy(.id)", comptime uncalledText("uniqueBy", @TypeOf(uniqueBy)));
}

test "uniqueItems compares integers exactly at every width, by value" {
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{}));
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{7}));
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{ 1, 2, 3 }));
    try expectOutcome(.fail, uniqueItems, @as([]const u32, &.{ 1, 2, 1 }));
    try expectOutcome(.fail, uniqueItems, @as([]const i8, &.{ -128, 127, -128 }));
    try expectOutcome(.pass, uniqueItems, @as([]const u64, &.{ 9007199254740992, 9007199254740993 }));
    try expectOutcome(.fail, uniqueItems, @as([]const u128, &.{ std.math.maxInt(u128), 0, std.math.maxInt(u128) }));
    try expectOutcome(.pass, uniqueItems, @as([:0]const u32, &.{ 1, 2 }));
    try expectOutcome(.pass, uniqueItems, [4]u8{ 1, 2, 3, 4 });
    try expectOutcome(.fail, uniqueItems, [4]u8{ 1, 2, 3, 1 });
}

test "uniqueItems compares strings byte for byte, case and normalization included" {
    try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &.{ "a", "A", "", "a " }));
    try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &.{ "a", "b", "a" }));
    try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &.{ "", "" }));
    // "é" composed and decomposed are different bytes.
    try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &.{ "\u{e9}", "e\u{301}" }));
    try expectOutcome(.fail, uniqueItems, @as([]const [:0]const u8, &.{ "x", "y", "x" }));
    try expectOutcome(.pass, uniqueItems, [2][]const u8{ "x", "y" });
}

test "uniqueItems compares bools and enums by tag, sparse and non-exhaustive ones too" {
    try expectOutcome(.pass, uniqueItems, @as([]const bool, &.{ true, false }));
    try expectOutcome(.fail, uniqueItems, @as([]const bool, &.{ false, true, false }));
    try expectOutcome(.fail, uniqueItems, @as([]const bool, &.{ true, true }));
    try expectOutcome(.pass, uniqueItems, @as([]const Role, &.{ .guest, .admin, .user }));
    try expectOutcome(.fail, uniqueItems, @as([]const Role, &.{ .guest, .admin, .guest }));
    try expectOutcome(.pass, uniqueItems, @as([]const Sparse, &.{ .high, .low, .mid }));
    try expectOutcome(.fail, uniqueItems, @as([]const Sparse, &.{ .mid, .high, .mid }));
    try expectOutcome(.pass, uniqueItems, @as([]const Open, &.{ .a, .b, @fromBackingInt(7) }));
    try expectOutcome(.fail, uniqueItems, @as([]const Open, &.{ @fromBackingInt(7), .a, @fromBackingInt(7) }));
    try expectOutcome(.pass, uniqueItems, [3]Role{ .user, .guest, .admin });
    try expectOutcome(.fail, uniqueItems, [2]bool{ true, true });
}

test "uniqueBy compares only the key of each item" {
    const lines: []const Line = &.{ .{ .sku = "A", .qty = 1 }, .{ .sku = "B", .qty = 1 } };
    try expectOutcome(.pass, uniqueBy(.sku), lines);
    try expectOutcome(.fail, uniqueBy(.qty), lines);
    try expectOutcome(.fail, uniqueBy(.active), lines);
    try expectOutcome(.fail, uniqueBy(.role), lines);
    try expectOutcome(.fail, uniqueBy(.sku), @as([]const Line, &.{ .{ .sku = "A" }, .{ .sku = "B" }, .{ .sku = "A", .qty = 2 } }));
    try expectOutcome(.pass, uniqueBy(.role), [3]Line{ .{ .sku = "", .role = .admin }, .{ .sku = "", .role = .user }, .{ .sku = "", .role = .guest } });
    try expectOutcome(.pass, uniqueBy(.active), [2]Line{ .{ .sku = "", .active = true }, .{ .sku = "", .active = false } });
    try expectOutcome(.pass, uniqueBy(.id), @as([]const Record, &.{}));
    try expectOutcome(.pass, uniqueBy(.id), @as([]const Record, &.{.{ .id = 1 }}));
}

/// `n` different integers, the last one repeated when `duplicate`.
fn distinctInts(comptime n: usize, comptime duplicate: bool) [n]u64 {
    var out: [n]u64 = undefined;
    for (&out, 0..) |*slot, i| slot.* = (n - i) * 7919;
    if (duplicate) out[n - 1] = out[0];
    return out;
}

/// `n` different strings of `len` bytes that differ only in their last
/// bytes, the last one repeated when `duplicate`.
fn distinctStrings(comptime n: usize, comptime len: usize, comptime duplicate: bool) [n][]const u8 {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var out: [n][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = &(@as([len - 4]u8, @splat('s')) ++ std.fmt.comptimePrint("{d:0>4}", .{i}).*);
        if (duplicate) out[n - 1] = out[(n - 1) / 2];
        const final = out;
        return final;
    }
}

test "uniqueItems sorts short lists, long lists and arrays up to max_unique_items" {
    // Short lists (up to 64 items), longer ones and an array of 1000 items.
    inline for (.{ 2, 64, 65, 1000 }) |n| {
        const ints = comptime distinctInts(n, false);
        const ints_dup = comptime distinctInts(n, true);
        try expectOutcome(.pass, uniqueItems, @as([]const u64, &ints));
        try expectOutcome(.fail, uniqueItems, @as([]const u64, &ints_dup));
        try expectOutcome(.pass, uniqueItems, ints);
        try expectOutcome(.fail, uniqueItems, ints_dup);
        const strings = comptime distinctStrings(n, 40, false);
        const strings_dup = comptime distinctStrings(n, 40, true);
        try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &strings));
        try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &strings_dup));
        try expectOutcome(.fail, uniqueItems, strings_dup);
    }
}
