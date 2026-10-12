# Common rules

Rules for values of several kinds: `v.notEmpty` checks that a string or a list
is not empty.

```zig
const Team = struct {
    name: []const u8,
    members: []const []const u8,
    motto: ?[]const u8 = null,

    pub const field_rules = .{
        .name = v.notEmpty,
        .members = .{ v.notEmpty, v.each(v.notEmpty) },
        .motto = v.notEmpty, // null skips the rule
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.notEmpty](#vnotempty)

## Common to all rules on this page

- A string is any slice of `u8`: `[]const u8`, `[]u8`, `[:0]const u8`, `[:0]u8`,
  with any alignment. Slices with `volatile` or `allowzero` are not strings, and
  `[N]u8` is an array of numbers, not a string.
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule. Inside `v.each(...)` it checks each item.
- A rule on a field type it does not accept is a compile error, not a failure
  at run time ([D62](class_validator.md#deviations-from-validatorjs)).
- Nothing is normalized: no trimming, no case folding, no Unicode
  normalization. The rules allocate nothing.

## v.notEmpty

A string has at least one byte; a list has at least one item.

- **Field types:** a string; a slice `[]const T` or `[]T` of any other item
  type; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** `value.len > 0`. A string counts bytes without decoding, so a
  string of spaces and invalid UTF-8 pass: the rule does not look at the
  content. A slice counts items, `null` items included. A `null` optional skips
  the rule: presence is the job of the field type.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.not_empty`.
- **Default message:** `must not be empty`.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D14](class_validator.md#deviations-from-validatorjs) (`null`
  skips the rule; one rule for strings and lists),
  [D61](class_validator.md#deviations-from-validatorjs) (a fixed-length array is
  a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: not_empty on [3]u32 is always true: the length of an array is fixed
validator: <Type>.field_rules.<field>: not_empty on [0]u32 is always false: the length of an array is fixed
validator: <Type>.field_rules.<field>: not_empty on [4]u8 is always true: the length of an array is fixed; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: not_empty expects a string or a slice, field is u32
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `[]const u8` | `""` | `validation.not_empty` |
| `[]const u8` | `" "` | passes: spaces are bytes |
| `[]const u8` | `"\xff"` | passes: the bytes are not decoded |
| `[]const u32` | `&.{}` | `validation.not_empty` |
| `[]const u32` | `&.{0}` | passes: the values of the items do not matter |
| `[]const ?u32` | `&.{null}` | passes: a `null` item is an item |
| `[]const []const u8` | `&.{""}` | passes: an empty string is an item; item rules go into `v.each` |
| `[]const []const u32` | `&.{&.{}}` | passes: an empty inner list is an item |
| `?[]const u32` | `null` | passes: `null` skips the rule |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
