# Lists

Rules for slices and arrays: `v.each` declares the rules of the items.

```zig
const Order = struct {
    tags: []const []const u8,
    quantities: [3]u32,
    scores: []const ?f64,

    pub const field_rules = .{
        .tags = .{ v.notEmpty, v.each(v.notEmpty) }, // the list, then each item
        .quantities = v.each(v.positive),
        .scores = v.each(v.positive), // null items are skipped
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
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
- **Predicate:** none.
- **Complexity:** O(items) times the cost of the inner rules; allocates nothing.
- **Deviations:** [D63](class_validator.md#deviations-from-validatorjs) (item
  rules never see `null` items).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: each(...): expected a rule or a tuple of rules, got *const [1:0]u8
validator: each(...): item 1 of the tuple is comptime_int
validator: each(.{}): the list is empty
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
