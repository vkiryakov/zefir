# Lists

Rules for slices and arrays: `v.minItems` and `v.maxItems` bound the number of
items, and `v.each` declares the rules of the items.

```zig
const Order = struct {
    tags: []const []const u8,
    quantities: [3]u32,
    scores: []const ?f64,

    pub const field_rules = .{
        .tags = .{ v.maxItems(10), v.each(v.notEmpty) }, // the list, then each item
        .quantities = v.each(v.positive),
        .scores = v.each(v.positive), // null items are skipped
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.minItems(min)](#vminitemsmin)
- [v.maxItems(max)](#vmaxitemsmax)
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
  keep their indexes in paths.
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
  (`v.minItems(0)` and a fixed-length array are compile errors).

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
  (`v.maxItems(0)` and a fixed-length array are compile errors).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: maxItems(0): max must be at least 1; use v.empty
validator: <Type>.field_rules.<field>: max_items(2) on [3]u32 is always false: the length of an array is fixed
validator: <Type>.field_rules.<field>: max_items expects a slice, field is u32
validator: <Type>.field_rules.<field>: maxItems must be called, e.g. v.maxItems(100)
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
