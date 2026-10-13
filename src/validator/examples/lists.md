# Lists

Rules for slices and arrays: `v.minItems` and `v.maxItems` bound the number of
items, `v.uniqueItems` and `v.uniqueBy` reject repeated items or keys,
`v.containsAll` and `v.containsNone` require or forbid listed values among the
items, and `v.each` declares the rules of the items.

```zig
const Order = struct {
    tags: []const []const u8,
    quantities: [3]u32,
    scores: []const ?f64,

    pub const field_rules = .{
        .tags = .{ v.maxItems(10), v.uniqueItems, v.each(v.notEmpty) }, // the list, then each item
        .quantities = v.each(v.positive),
        .scores = v.each(v.positive), // null items are skipped
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.minItems(min)](#vminitemsmin)
- [v.maxItems(max)](#vmaxitemsmax)
- [v.uniqueItems](#vuniqueitems)
- [v.uniqueBy(key)](#vuniquebykey)
- [v.containsAll(values)](#vcontainsallvalues)
- [v.containsNone(values)](#vcontainsnonevalues)
- [v.each(rules)](#veachrules)

## Common to all rules on this page

- A list is a slice `[]const T` or `[]T` whose items are not `u8` (a slice of
  `u8` is a string), or an array `[N]T`, `[N]u8` included: an array of `u8` is
  an array of numbers. A slice with `volatile`, `allowzero` or an alignment
  below that of its items is not a list: the rules reject it, and the walk
  treats it like a pointer.
- The rules of the list itself go first in the field's entry, the rules of its
  items into `v.each(...)`, the last rule of the entry. When a rule of the list
  fails, no item is checked.
- `null` items of `[]const ?T` are skipped by item rules, and the other items
  keep their indexes in paths. `v.uniqueItems`, `v.uniqueBy`, `v.containsAll`
  and `v.containsNone` do not take optional items: a compile error.
- Two rules of one entry whose bounds on the number of items let no list pass
  are a compile error, inside `v.each` too: `.{ v.minItems(5), v.maxItems(3) }`,
  `v.empty` with `v.minItems(1)` or `v.notEmpty`. Equal bounds,
  `.{ v.minItems(3), v.maxItems(3) }`, are fine.
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule.
- The rules allocate nothing.

## v.minItems(min)

A list has at least `min` items.

- **Field types:** a slice `[]const T` or `[]T` whose items are not `u8`; `?T`
  and `??T` of these. A fixed-length array `[N]T` is a compile error: the rule
  would always pass or always fail. A string is not a list: on a string field the
  rule is a compile error, and its hint names the rules for the length of a
  string, [v.minLength](strings.md#vminlengthmin) and
  [v.minBytes](strings.md#vminbytesmin).
- **Parameters:** `min`, a `usize` known at compile time, at least 1.
- **Passes when:** `value.len >= min`. It counts items, `null` items included,
  and never looks at them.
- **`""`:** not a string rule.
- **Precondition:** none.
- **Code:** `validation.min_items`.
- **Default message:** `must have at least {min} items`; for `min` 1
  `must have at least 1 item`.
- **Placeholders:** `{min}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D61](class_validator.md#deviations-from-validatorjs)
  (`v.minItems(0)` and a fixed-length array are compile errors),
  [D60](class_validator.md#deviations-from-validatorjs) (`v.minItems(5)` with
  `v.maxItems(3)` is a compile error).

[v.notEmpty](common.md#vnotempty) fails an empty list too, with the code
`validation.not_empty`, so `v.notEmpty` and `v.minItems(1)` overlap and differ in
the code. Prefer `v.notEmpty`; use `v.minItems(1)` when clients branch on
`validation.min_items`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)
validator: <Type>.field_rules.<field>: min_items(1) on [3]u32 is always true: the length of an array is fixed
validator: <Type>.field_rules.<field>: min_items expects a slice, field is u32
validator: <Type>.field_rules.<field>: minItems must be called, e.g. v.minItems(1)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.minItems(1)` | `[]const u32` | `&.{}` | `validation.min_items`: `must have at least 1 item` |
| `v.minItems(2)` | `[]const u32` | `&.{1}` | `validation.min_items`: `must have at least 2 items` |
| `v.minItems(2)` | `[]const u32` | `&.{ 1, 2 }` | passes: exactly the minimum |
| `v.minItems(3)` | `[]const u32` | `&.{ 1, 2, 3, 4 }` | passes |
| `v.minItems(1)` | `[]const ?u32` | `&.{null}` | passes: a `null` item is an item |
| `v.minItems(1)` | `[]const []const u8` | `&.{}` | `validation.min_items` |
| `v.minItems(1)` | `?[]const u32` | `null` | passes: `null` skips the rule |
| `v.minItems(1).withMessage("add an item")` | `[]const u32` | `&.{}` | `validation.min_items` / `add an item` |

## v.maxItems(max)

A list has at most `max` items.

- **Field types:** a slice `[]const T` or `[]T` whose items are not `u8`; `?T`
  and `??T` of these. A fixed-length array `[N]T` is a compile error: the rule
  would always pass or always fail. A string is not a list: on a string field the
  rule is a compile error, and its hint names the rules for the length of a
  string, [v.maxLength](strings.md#vmaxlengthmax) and
  [v.maxBytes](strings.md#vmaxbytesmax).
- **Parameters:** `max`, a `usize` known at compile time, at least 1. For an empty
  list use `v.empty`.
- **Passes when:** `value.len <= max`. It counts items, `null` items included,
  and never looks at them.
- **`""`:** not a string rule.
- **Precondition:** none.
- **Code:** `validation.max_items`.
- **Default message:** `must have at most {max} items`; for `max` 1
  `must have at most 1 item`.
- **Placeholders:** `{max}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D61](class_validator.md#deviations-from-validatorjs)
  (`v.maxItems(0)` and a fixed-length array are compile errors),
  [D60](class_validator.md#deviations-from-validatorjs) (`v.maxItems(3)` after
  `v.minItems(5)` is a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: maxItems(0): max must be at least 1; use v.empty
validator: <Type>.field_rules.<field>: max_items(2) on [3]u32 is always false: the length of an array is fixed
validator: <Type>.field_rules.<field>: max_items expects a slice, field is u32
validator: <Type>.field_rules.<field>: maxItems must be called, e.g. v.maxItems(100)
validator: <Type>.field_rules.<field>: min_items(5) and max_items(3) contradict; no value can pass
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.maxItems(1)` | `[]const u32` | `&.{ 1, 2 }` | `validation.max_items`: `must have at most 1 item` |
| `v.maxItems(3)` | `[]const u32` | `&.{ 1, 2, 3, 4 }` | `validation.max_items`: `must have at most 3 items` |
| `v.maxItems(3)` | `[]const u32` | `&.{ 1, 2, 3 }` | passes: exactly the maximum |
| `v.maxItems(3)` | `[]const u32` | `&.{}` | passes |
| `v.maxItems(1)` | `[]const ?u32` | `&.{ null, null }` | `validation.max_items`: `null` items count |
| `v.maxItems(2)` | `[]const []const u8` | `&.{ "", "" }` | passes: items are counted, not inspected |
| `v.maxItems(2)` | `?[]const u32` | `null` | passes: `null` skips the rule |

## v.uniqueItems

No two items of a list are equal.

- **Field types:** a slice or an array `[N]T` of `bool`, enum, integer or string
  items; `?T` and `??T` of these. Float items (NaN is not equal to itself, and
  `-0.0` equals `0.0`), optional items, structs (use `v.uniqueBy`) and other
  items are compile errors. Integers, strings and non-exhaustive enums are
  capped: on a slice an earlier `v.maxItems(n)` with `n` at most
  `v.max_unique_items` (1000) must come in the same tuple, and `[N]T` needs `N`
  at most 1000. Bools and exhaustive enums need no cap. Any `[N]T` needs `N` of
  at least 2 (`[0]T` and `[1]T` always pass) and no more items than the item
  type has values (`[3]bool` always fails).
- **Parameters:** none.
- **Passes when:** no two items are equal: integers by value, exactly at every
  width; enums by tag (a non-exhaustive enum by its integer); strings byte for
  byte, with no case folding or normalization.
- **`""`:** not a string rule; two `""` items are equal.
- **Precondition:** none.
- **Code:** `validation.unique_items`.
- **Default message:** `must not contain duplicates`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** bools and exhaustive enums: a bitset, O(n), at any length.
  Integers, strings and non-exhaustive enums: their indexes are sorted on the
  stack, O(n log n); strings are sorted by a 64-bit hash, and only strings with
  equal hashes are compared byte for byte. Allocates nothing: the buffers
  live on the stack, at most 10 KB (1000 indexes and 1000 hashes).
- **Deviations:** [D17](class_validator.md#deviations-from-validatorjs) (the
  item types and the cap),
  [D58](class_validator.md#deviations-from-validatorjs) (exact integers),
  [D61](class_validator.md#deviations-from-validatorjs) (`[0]T`, `[1]T`,
  `[3]bool`).

The cap keeps the check fast and free of allocation: the capping `v.maxItems`
runs first, so a longer list fails with `validation.max_items` before its
items are compared. Write it before the rule: `.ids = .{ v.maxItems(100),
v.uniqueItems }`. Inside `v.each`, each inner list needs its own cap.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: unique_items needs an earlier v.maxItems(n) with n <= 1000 (max_unique_items) in the same tuple
validator: <Type>.field_rules.<field>: unique_items after max_items(1001): 1001 is more than max_unique_items (1000)
validator: <Type>.field_rules.<field>: unique_items on [1001]u32: 1001 items is more than max_unique_items (1000)
validator: <Type>.field_rules.<field>: unique_items on [1]u32 is always true; remove it
validator: <Type>.field_rules.<field>: unique_items on [3]bool is always false: 3 items cannot all differ
validator: <Type>.field_rules.<field>: unique_items: items are f64; float items are not supported (NaN != NaN, -0.0 == 0.0)
validator: <Type>.field_rules.<field>: unique_items: items are orders.Item; struct items are not supported; use v.uniqueBy(.field)
validator: <Type>.field_rules.<field>: unique_items expects a slice or an array, field is []const u8 (a string)
```

Examples:

| Rules | Field type | Value | Result |
| --- | --- | --- | --- |
| `.{ v.maxItems(10), v.uniqueItems }` | `[]const u32` | `&.{ 1, 2, 1 }` | `validation.unique_items`: `must not contain duplicates` |
| `.{ v.maxItems(10), v.uniqueItems }` | `[]const u64` | `&.{ 9007199254740992, 9007199254740993 }` | passes: integers are exact |
| `.{ v.maxItems(10), v.uniqueItems }` | `[]const []const u8` | `&.{ "go", "Go" }` | passes: case matters |
| `.{ v.maxItems(10), v.uniqueItems }` | `[]const u32` | `&.{}` | passes |
| `.{ v.maxItems(2), v.uniqueItems }` | `[]const u32` | `&.{ 1, 1, 1 }` | `validation.max_items`: the cap runs first |
| `v.uniqueItems` | `[]const Role` (an enum) | `&.{ .admin, .admin }` | `validation.unique_items`; no `v.maxItems` needed |
| `v.uniqueItems` | `[3]u8` | `.{ 1, 2, 3 }` | passes |

## v.uniqueBy(key)

No two struct items of a list have equal values of the field `key`.

- **Field types:** a slice or an array `[N]T` of structs; `?T` and `??T` of
  these. The key field is a `bool`, enum, integer or string field that is not
  `comptime`. The cap and the lengths of `[N]T` are those of `v.uniqueItems`,
  by the type of the key: `.{ v.maxItems(50), v.uniqueBy(.sku) }` for a string
  key, no `v.maxItems` for a `bool` or exhaustive enum key.
- **Parameters:** `key`, the name of the field as an enum literal: `.id`.
- **Passes when:** no two items have equal keys, compared as `v.uniqueItems`
  compares items; the other fields are not looked at.
- **`""`:** not a string rule.
- **Precondition:** none.
- **Code:** `validation.unique_items`, as `v.uniqueItems`.
- **Default message:** `must not contain duplicate {key} values`.
- **Placeholders:** `{key}`: the name of the field.
- **Predicate:** none.
- **Complexity:** as `v.uniqueItems`, over the keys; allocates nothing.
- **Deviations:** [D17](class_validator.md#deviations-from-validatorjs),
  [D58](class_validator.md#deviations-from-validatorjs),
  [D61](class_validator.md#deviations-from-validatorjs).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: uniqueBy("id"): the key must be a field name such as .id, got *const [2:0]u8
validator: <Type>.field_rules.<field>: unique_by(.idd): orders.Item has no field idd; did you mean "id"?
validator: <Type>.field_rules.<field>: unique_by(.id): items are u32, not structs; use v.uniqueItems
validator: <Type>.field_rules.<field>: unique_by(.price): the key price is f64; float keys are not supported (NaN != NaN, -0.0 == 0.0)
validator: <Type>.field_rules.<field>: unique_by(.id) needs an earlier v.maxItems(n) with n <= 1000 (max_unique_items) in the same tuple
validator: <Type>.field_rules.<field>: uniqueBy must be called, e.g. v.uniqueBy(.id)
```

Examples (`Line` is `struct { sku: []const u8, qty: u32 }`):

| Rules | Field type | Value | Result |
| --- | --- | --- | --- |
| `.{ v.maxItems(50), v.uniqueBy(.sku) }` | `[]const Line` | `&.{ .{ .sku = "A", .qty = 1 }, .{ .sku = "A", .qty = 2 } }` | `validation.unique_items`: `must not contain duplicate sku values` |
| `.{ v.maxItems(50), v.uniqueBy(.sku) }` | `[]const Line` | `&.{ .{ .sku = "A", .qty = 1 }, .{ .sku = "B", .qty = 1 } }` | passes: only the key is compared |
| `v.uniqueBy(.qty).withMessage("{key} repeats")` | `[2]Line` | `.{ .{ .sku = "A", .qty = 1 }, .{ .sku = "B", .qty = 1 } }` | `validation.unique_items` / `qty repeats` |

## v.containsAll(values)

Every listed value is an item of the list.

- **Field types:** a slice or an array `[N]T` of `bool`, enum, integer or string
  items, of the kind of the listed values; `?T` and `??T` of these. Optional and
  float items are compile errors. On a string field it is a compile error that
  points to `v.contains`, the rule for a substring. On `[N]T` the list has at
  most `N` values, and `[0]T`, where the rule would always fail, is a compile
  error.
- **Parameters:** `values`, a tuple or an array `[N]T` known at compile time
  (not a pointer to one, not a slice) of at least one value, none twice, all of
  one kind: non-empty strings in valid UTF-8, enum tags of the item type,
  integers within the item type, or bools.
- **Passes when:** each listed value equals an item: strings byte for byte,
  integers exactly, enums by tag. The items are scanned in index order; one item
  never counts for two values. An empty list fails.
- **`""`:** not a string rule; `""` cannot be listed.
- **Precondition:** none.
- **Code:** `validation.contains_all`.
- **Default message:** `must contain all of: {values}`; for one value
  `must contain {values}`; `must contain all of the required values` when the
  message would be longer than 512 bytes.
- **Placeholders:** `{values}`: the values joined by `, `.
- **Predicate:** none.
- **Complexity:** O(items × values), ending when every value is found;
  allocates nothing.
- **Deviations:** [D22](class_validator.md#deviations-from-validatorjs),
  [D58](class_validator.md#deviations-from-validatorjs).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: containsAll(.{}): the list is empty
validator: containsAll(.{ 1, 2, 1 }): 1 is listed twice
validator: containsAll(.{""}): the empty string cannot be listed
validator: containsAll(...): expected a tuple or an array of values, e.g. .{ "a", "b" }, got *const [2][]const u8; pass the array itself, not a pointer to it
validator: <Type>.field_rules.<field>: contains_all expects a slice or an array, field is []const u8; for a substring use v.contains
validator: <Type>.field_rules.<field>: contains_all(.{"1"}) lists strings, items are u32
validator: <Type>.field_rules.<field>: contains_all(.{ 1, 2, 3 }) on [2]u8: an array of 2 items cannot contain 3 different values
validator: <Type>.field_rules.<field>: containsAll must be called, e.g. v.containsAll(.{"a"})
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.containsAll(.{ "read", "write" })` | `[]const []const u8` | `&.{ "write", "read" }` | passes |
| `v.containsAll(.{ "read", "write" })` | `[]const []const u8` | `&.{ "read", "read" }` | `validation.contains_all`: `must contain all of: read, write` |
| `v.containsAll(.{"read"})` | `[]const []const u8` | `&.{}` | `validation.contains_all`: `must contain read` |
| `v.containsAll(.{.admin})` | `[]const Role` | `&.{ .viewer, .admin }` | passes |
| `v.containsAll(.{ 2, 3 })` | `[3]u8` | `.{ 3, 1, 1 }` | `validation.contains_all` |

## v.containsNone(values)

No item of the list is a listed value.

- **Field types:** as `v.containsAll`; on a string field the error points to
  `v.notContains`, and on `[0]T` the rule would always pass: a compile error.
- **Parameters:** `values`, as for `v.containsAll`. The list cannot hold every
  value of the item type (both bools, every tag of an exhaustive enum, every
  value of an integer type): on a slice only an empty list would pass (use
  `v.empty`), and on `[N]T` no value would. `""` cannot be listed: to reject
  empty strings among the items, use `v.each(v.notEmpty)`.
- **Passes when:** no item equals a listed value, compared as by
  `v.containsAll`. An empty list passes.
- **`""`:** not a string rule.
- **Precondition:** none.
- **Code:** `validation.contains_none`.
- **Default message:** `must not contain any of: {values}`; for one value
  `must not contain {values}`; `must not contain any of the forbidden values`
  when the message would be longer than 512 bytes.
- **Placeholders:** `{values}`: the values joined by `, `.
- **Predicate:** none.
- **Complexity:** O(items × values); allocates nothing.
- **Deviations:** [D22](class_validator.md#deviations-from-validatorjs),
  [D58](class_validator.md#deviations-from-validatorjs).

`v.containsNone(.{.blue})` reports one violation at the list's path (`colors`);
`v.each(v.noneOf(.{.blue}))` reports each item that is `.blue` at its index
(`colors[1]`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: containsNone(.{""}): the empty string cannot be listed; use v.each(v.notEmpty) to reject empty items
validator: <Type>.field_rules.<field>: contains_none expects a slice or an array, field is []const u8; for a substring use v.notContains
validator: <Type>.field_rules.<field>: contains_none(.{.red}): .red is a tag of colors.Color, the items are users.Role
validator: <Type>.field_rules.<field>: contains_none(.{ true, false }) lists every value of bool; only an empty list would pass; use v.empty
validator: <Type>.field_rules.<field>: contains_none(.{ true, false }) lists every value of bool; no value would pass
validator: <Type>.field_rules.<field>: containsNone must be called, e.g. v.containsNone(.{"a"})
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.containsNone(.{ "root", "admin" })` | `[]const []const u8` | `&.{ "user", "Root" }` | passes: case matters |
| `v.containsNone(.{ "root", "admin" })` | `[]const []const u8` | `&.{ "user", "admin" }` | `validation.contains_none`: `must not contain any of: root, admin` |
| `v.containsNone(.{.guest})` | `[]const Role` | `&.{.guest}` | `validation.contains_none`: `must not contain guest` |
| `v.containsNone(.{0})` | `[]const i32` | `&.{}` | passes |

## v.each(rules)

Applies rules to every item of a slice or an array. Written `v.each(rule)` or
`v.each(.{ rules })`.

- **Field types:** a slice or an array `[N]T` of any item type, `[N]u8`
  included; `?T` and `??T` of these. A string is not a list.
- **Parameters:** `rules`: one rule or a tuple of at least one rule, any rule
  including `v.each` (for lists of lists) and `v.custom`.
- **Passes when:** `v.each` is not a check of the list: it declares the rules of
  the items. It is the last rule of its tuple, at most one per tuple. Only when
  all rules of the list passed, the walk visits the items by index, skipping
  `null` items. The inner rules run left to right as the item's own rules: the
  first one that fails is the item's only violation, at the path `field[i]`. When
  they all pass, the walk enters the item: the fields of a struct and its
  `validateSelf`, or the items of an inner list with the inner `v.each`.
  `v.each(v.each(rule))` on `[][]T` applies `rule` once to every element.
  `checkAll` goes on with the next item.
- **`""`:** an item `""` is checked by the inner rules.
- **Precondition:** none of its own; the inner rules keep theirs, so a NaN item
  under `v.each(v.positive)` fails with `validation.finite`.
- **Code and message:** none of its own: a violation has the code and message
  of the inner rule that failed.
- **Placeholders:** none. `.withMessage` on `v.each` is a compile error: put it
  on the inner rules, `v.each(v.notEmpty.withMessage("..."))`.
- **Predicate:** none.
- **Complexity:** O(items) times the cost of the inner rules; allocates nothing.
- **Deviations:** [D63](class_validator.md#deviations-from-validatorjs) (item
  rules never see `null` items).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: each(...): expected a rule or a tuple of rules, got *const [1:0]u8
validator: each(...): item 1 of the tuple is comptime_int
validator: each(.{}): the list is empty
validator: each(...).withMessage("x"): each has no message of its own; put .withMessage on the inner rules
validator: <Type>.field_rules.<field>: each expects a slice or an array, field is []const u8 (a string)
validator: <Type>.field_rules.<field>: each must be called, e.g. v.each(v.notEmpty)
validator: <Type>.field_rules.<field>: each must be the last rule
validator: <Type>.field_rules.<field>: each appears twice; put all item rules into one v.each(.{ ... })
```

Examples (the path follows the field's name):

| Field type | Rules | Value | Result |
| --- | --- | --- | --- |
| `[]const u32` | `v.each(v.positive)` | `&.{ 1, 0 }` | `validation.positive` at `[1]` |
| `[]const ?u32` | `v.each(v.positive)` | `&.{ null, 0 }` | `validation.positive` at `[1]`: `null` is skipped, the index kept |
| `[]const ?u32` | `v.each(v.positive)` | `&.{null}` | passes |
| `[3]u32` | `v.each(v.positive)` | `.{ 1, 2, 0 }` | `validation.positive` at `[2]` |
| `[]const []const u32` | `v.each(v.each(v.positive))` | `&.{ &.{1}, &.{ 0, 1 } }` | `validation.positive` at `[1][0]` |
| `[]const f64` | `v.each(v.positive)` | `&.{ 1, nan }` | `validation.finite` at `[1]` |
| `[]const u32` | `v.each(v.positive)`, with `checkAll` | `&.{ 0, 1, 0 }` | two violations, at `[0]` and at `[2]` |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
