# Common rules

Rules for values of several kinds: `v.equals` and `v.notEquals` compare a value
with one value, `v.oneOf` and `v.noneOf` with a list of values, and `v.empty` and
`v.notEmpty` check that a string or a list is empty or not.

```zig
const Role = enum { admin, editor, viewer };

const Team = struct {
    name: []const u8,
    members: []const []const u8,
    motto: ?[]const u8 = null,
    lead: Role,
    accepted: bool,

    pub const field_rules = .{
        .name = .{ v.notEmpty, v.noneOf(.{ "admin", "root" }) },
        .members = .{ v.notEmpty, v.each(v.notEmpty) },
        .motto = v.notEmpty, // null skips the rule
        .lead = v.oneOf(.{ .admin, .editor }),
        .accepted = v.equals(true),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.equals(expected)](#vequalsexpected)
- [v.notEquals(forbidden)](#vnotequalsforbidden)
- [v.oneOf(values)](#voneofvalues)
- [v.noneOf(values)](#vnoneofvalues)
- [v.empty](#vempty)
- [v.notEmpty](#vnotempty)

## Common to all rules on this page

- A string is any slice of `u8`: `[]const u8`, `[]u8`, `[:0]const u8`, `[:0]u8`,
  with any alignment. Slices with `volatile` or `allowzero` are not strings, and
  `[N]u8` is an array of numbers, not a string.
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule. Inside `v.each(...)` it checks each item.
- A rule on a field type it does not accept is a compile error, not a failure
  at run time ([D62](class_validator.md#deviations-from-validatorjs)).
- The parameters of `v.equals`, `v.notEquals`, `v.oneOf` and `v.noneOf` are
  known at compile time, and a parameter that does not fit the field type, such
  as `300` on a `u8`, is a compile error.
- On a float field `v.equals` and `v.notEquals` first check that the value is
  finite: NaN, `+inf` and `-inf` fail with `validation.finite` /
  `must be a finite number`, before the comparison
  ([D16](class_validator.md#deviations-from-validatorjs)). The other rules of
  this page have no precondition. `.withMessage` does not change the code and
  the message of a precondition ([Messages](README.md#preconditions)).
- The default messages show the parameters of the rule (`must be one of: a, b`).
  `.withMessage` replaces a message and can use the placeholders `{expected}`,
  `{forbidden}` and `{values}` ([Messages](README.md#messages)).
- Nothing is normalized: no trimming, no case folding, no Unicode
  normalization. The rules allocate nothing.

## v.equals(expected)

A value is equal to the one value you give.

- **Field types:** an integer, a float, a `bool`, an enum or a string; `?T` and
  `??T` of these.
- **Parameters:** `expected`, known at compile time: an integer, a finite float,
  `true` or `false`, a named enum tag such as `.admin`, or a non-empty string of
  valid UTF-8. It must fit the field type: an integer within the range of an
  integer field (and exactly representable in a float field), a float only for a
  float field, a tag of the field's enum, a string only for a string field. A
  typed float narrower than a float field keeps its exact value there, so it is
  an error when that value reads differently: `v.equals(@as(f32, 0.1))` on an
  `f64` would compare with 0.10000000149011612; write it as a literal or in the
  field's type.
- **Passes when:** on a float field, the value is finite first; then, for an
  integer or a `bool`, `value == expected`, exact at every width. A float is
  compared under IEEE `==` with `expected` converted to the field type at
  compile time, rounded to nearest: `-0.0` equals `0`, `v.equals(0.1)` on an
  `f32` accepts the `f32` nearest to 0.1, and there is no epsilon. An enum must
  be the named tag; an unnamed value of a non-exhaustive enum never matches. A
  string must have the same length and the same bytes: case-sensitive, with no
  trimming, decoding or Unicode normalization (`"e\u{301}"` is not `"\u{e9}"`).
- **`""`:** fails: `v.equals("")` is a compile error, so `""` never equals the
  parameter (use `v.empty`).
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.equals`.
- **Default message:** `must be equal to {expected}`; when the parameter shown
  would make the message longer than 512 bytes,
  `must be equal to the expected value`.
- **Placeholders:** `{expected}`: the parameter as written, before the
  conversion to the field type.
- **Predicate:** none.
- **Complexity:** O(1) for numbers, `bool` and enums; O(n) bytes for strings (the
  lengths are compared first); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D20](class_validator.md#deviations-from-validatorjs) (exact integers, floats
  rounded to the field type).

`v.equals(true)` on a `?bool` field passes `null`, like every rule: a field
that must be accepted ("accept the terms") is a plain `bool`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: equals(""): the expected value is the empty string; use v.empty
validator: <Type>.field_rules.<field>: equals(300): 300 is outside u8 (0..255); the rule would never pass
validator: <Type>.field_rules.<field>: equals(0.1): 0.1 is a float (f32), 0.10000000149011612 in f64; write it as a literal or as f64
validator: <Type>.field_rules.<field>: equals("admin"): "admin" is a string, field is teams.Role; use a tag such as .admin
validator: <Type>.field_rules.<field>: equals expects a number, a bool, an enum or a string, field is []const u32; use v.each(v.equals(5))
validator: <Type>.field_rules.<field>: equals must be called, e.g. v.equals(true)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.equals(5)` | `i32` | `5` | passes |
| `v.equals(5)` | `i32` | `-5` | `validation.equals` |
| `v.equals(9007199254740993)` | `u64` | `9007199254740992` | `validation.equals`: integers are exact at every width |
| `v.equals(0)` | `f64` | `-0.0` | passes: IEEE `==` |
| `v.equals(0.1)` | `f32` | the `f32` nearest to 0.1 | passes: the parameter is rounded to the field type |
| `v.equals(0.3)` | `f64` | `0.1 + 0.2` | `validation.equals`: no epsilon |
| `v.equals(0)` | `f64` | NaN | `validation.finite` |
| `v.equals(true)` | `bool` | `false` | `validation.equals` |
| `v.equals(true)` | `?bool` | `null` | passes: `null` skips the rule |
| `v.equals(.admin)` | `Role` | `.viewer` | `validation.equals` |
| `v.equals("admin")` | `[]const u8` | `"Admin"` | `validation.equals`: case-sensitive |
| `v.equals("admin")` | `[]const u8` | `"admin "` | `validation.equals`: no trimming |
| `v.equals("é")` | `[]const u8` | `"e\u{301}"` | `validation.equals`: no Unicode normalization |

## v.notEquals(forbidden)

A value is not equal to the one value you give.

- **Field types:** an integer, a float, a `bool`, an enum or a string; `?T` and
  `??T` of these.
- **Parameters:** `forbidden`, with the same kinds and checks as `expected` of
  [v.equals](#vequalsexpected).
- **Passes when:** on a float field, the value is finite first; then the
  comparison of `v.equals` fails. So `-0.0` is the forbidden value of
  `v.notEquals(0)`, and NaN and infinities never reach the comparison: they fail
  the precondition, although `NaN != 0` under IEEE. An unnamed value of a
  non-exhaustive enum passes. Strings compare bytes, as in `v.equals`.
- **`""`:** passes: `v.notEquals("")` is a compile error (use `v.notEmpty`).
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.not_equals`.
- **Default message:** `must not be equal to {forbidden}`; when the parameter
  shown would make the message longer than 512 bytes,
  `must not be equal to the forbidden value`.
- **Placeholders:** `{forbidden}`: the parameter as written.
- **Predicate:** none.
- **Complexity:** O(1) for numbers, `bool` and enums; O(n) bytes for strings;
  allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D20](class_validator.md#deviations-from-validatorjs) (exact integers, floats
  rounded to the field type; NaN and `+inf` do not pass `v.notEquals(0)`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: notEquals(""): the forbidden value is the empty string; use v.notEmpty
validator: <Type>.field_rules.<field>: not_equals(-1): -1 is outside u32 (0..4294967295); the rule would always pass
validator: <Type>.field_rules.<field>: not_equals(.root): teams.Role has no tag root; tags: admin, editor, viewer
validator: <Type>.field_rules.<field>: notEquals must be called, e.g. v.notEquals(0)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.notEquals(0)` | `i32` | `0` | `validation.not_equals` |
| `v.notEquals(0)` | `i32` | `-1` | passes |
| `v.notEquals(0)` | `f64` | `-0.0` | `validation.not_equals`: `-0.0 == 0` |
| `v.notEquals(0)` | `f64` | `5e-324`, the smallest subnormal | passes |
| `v.notEquals(0)` | `f64` | NaN | `validation.finite`: NaN fails the precondition although `NaN != 0` |
| `v.notEquals(false)` | `bool` | `true` | passes |
| `v.notEquals(.viewer)` | `Role` | `.viewer` | `validation.not_equals` |
| `v.notEquals("root")` | `[]const u8` | `"Root"` | passes: case-sensitive |
| `v.notEquals("root")` | `[]const u8` | `""` | passes: combine with `v.notEmpty` |

## v.oneOf(values)

A string, an enum tag or an integer is one of the values you list. Written
`v.oneOf(.{ "a", "b" })`.

- **Field types:** a string, an enum or an integer; `?T` and `??T` of these.
- **Parameters:** `values`, known at compile time: a tuple (`.{ "a", "b" }`) or
  an array `[N]T` of at least one value, all of one kind: strings (valid UTF-8,
  `""` allowed), enum tags or integers. Floats, `bool`, `null` and other kinds
  are compile errors, and so are an empty list, a value listed twice, a value
  that does not fit the field type and a kind that does not match the field.
  Pass the array itself: a pointer to an array, or a slice, is rejected.
- **Passes when:** the value equals one listed value. Strings compare bytes:
  case-sensitive, with no trimming, decoding or normalization, and invalid UTF-8
  is just bytes. An enum is compared by tag, and an unnamed value of a
  non-exhaustive enum fails. Integers compare with `==`, exact at every width.
  Listing every tag of an enum, or every value of an integer type, is allowed: it
  pins the current set.
- **`""`:** fails unless `""` is listed.
- **Precondition:** none.
- **Code:** `validation.one_of`.
- **Default message:** `must be one of: {values}`; for one value `must be {values}`;
  when the list shown would make the message longer than 512 bytes,
  `must be one of the allowed values`.
- **Placeholders:** `{values}`: the listed values, each as the messages show a
  value, joined with `, `. A value that contains `, ` itself makes the message
  ambiguous: `.{ "a, b", "c" }` says `must be one of: a, b, c`. Give such a list a
  message of your own with `.withMessage`.
- **Predicate:** none.
- **Complexity:** O(k) comparisons for k listed values (strings compare bytes
  only when the lengths are equal); allocates nothing.
- **Deviations:** [D15](class_validator.md#deviations-from-validatorjs) (the
  list is checked at compile time),
  [D58](class_validator.md#deviations-from-validatorjs) (integers are exact).

`v.oneOf(.{x})` and `v.equals(x)` overlap; they differ in the code
(`validation.one_of`, `validation.equals`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: oneOf(.{}): the list is empty
validator: oneOf(...): expected a tuple or an array of values, e.g. .{ "a", "b" }, got *const [2][]const u8; pass the array itself, not a pointer to it
validator: oneOf(.{ "a", "b", "a" }): "a" is listed twice
validator: <Type>.field_rules.<field>: one_of(.{"admin"}) lists strings, field is teams.Role; list the enum's tags instead: .{ .tag, ... }
validator: <Type>.field_rules.<field>: one_of(.{ 1, 300 }): 300 is outside u8 (0..255); remove it
validator: <Type>.field_rules.<field>: oneOf must be called, e.g. v.oneOf(.{ "a", "b" })
```

Examples:

| List | Field type | Value | Result |
| --- | --- | --- | --- |
| `.{ "a", "b" }` | `[]const u8` | `"a"` | passes |
| `.{ "a", "b" }` | `[]const u8` | `"A"` | `validation.one_of`: `must be one of: a, b` |
| `.{ "a", "b" }` | `[]const u8` | `""` | `validation.one_of`: `""` fails unless listed |
| `.{ "", "a" }` | `[]const u8` | `""` | passes |
| `.{ "", "a" }` | `[]const u8` | `"b"` | `validation.one_of`: `must be one of: "", a` |
| `.{"a"}` | `[]const u8` | `"\xff"` | `validation.one_of`: bytes are compared as they are |
| `.{ .editor, .admin }` | `Role` | `.viewer` | `validation.one_of`: `must be one of: editor, admin` |
| `.{ .a, .b }` | `Open`, a non-exhaustive enum `enum(u8) { a, b, _ }` | `@fromBackingInt(9)` | `validation.one_of`: an unnamed value is never listed |
| `.{ 1, 2, 3 }` | `u8` | `4` | `validation.one_of`: `must be one of: 1, 2, 3` |
| `.{.admin}` in `v.each` | `[]const Role` | `&.{ .admin, .editor }` | `validation.one_of` at `[1]`: `must be admin` |
| `.{ .editor, .admin }` | `?Role` | `null` | passes |

## v.noneOf(values)

A string, an enum tag or an integer is none of the values you list. Written
`v.noneOf(.{ "a", "b" })`.

- **Field types:** a string, an enum or an integer; `?T` and `??T` of these.
- **Parameters:** `values`, as for [v.oneOf](#voneofvalues), except that `""`
  cannot be listed (use `v.notEmpty`) and the list must not exclude every value
  of the field type: every tag of an exhaustive enum, or every value of a small
  integer type such as `u1`, is a compile error.
- **Passes when:** the value equals none of the listed values, compared as in
  `v.oneOf`. An unnamed value of a non-exhaustive enum passes. Only an exact
  match counts: there is no prefix, substring, case-folding or look-alike
  (confusables) check.
- **`""`:** passes: `""` cannot be listed (combine the rule with `v.notEmpty`).
- **Precondition:** none.
- **Code:** `validation.none_of`.
- **Default message:** `must not be one of: {values}`; for one value
  `must not be {values}`; when the list shown would make the message longer than
  512 bytes, `must not be one of the forbidden values`.
- **Placeholders:** `{values}`, as in `v.oneOf`.
- **Predicate:** none.
- **Complexity:** O(k) comparisons for k listed values; allocates nothing.
- **Deviations:** [D15](class_validator.md#deviations-from-validatorjs) (the
  list is checked at compile time),
  [D58](class_validator.md#deviations-from-validatorjs) (integers are exact).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: noneOf(.{ "", "root" }): the empty string cannot be listed; use v.notEmpty
validator: <Type>.field_rules.<field>: none_of(.{ .admin, .editor, .viewer }) lists every tag of teams.Role; no value would pass
validator: <Type>.field_rules.<field>: none_of(.{ 0, 1 }) lists every value of u1; no value would pass
validator: <Type>.field_rules.<field>: noneOf must be called, e.g. v.noneOf(.{ "a", "b" })
```

Examples:

| List | Field type | Value | Result |
| --- | --- | --- | --- |
| `.{ "admin", "root", "system" }` | `[]const u8` | `"alice"` | passes |
| `.{ "admin", "root", "system" }` | `[]const u8` | `"admin"` | `validation.none_of`: `must not be one of: admin, root, system` |
| `.{ "admin", "root", "system" }` | `[]const u8` | `"Admin"` | passes: case-sensitive |
| `.{ "admin", "root", "system" }` | `[]const u8` | `""` | passes: combine with `v.notEmpty` |
| `.{ "admin", "root", "system" }` | `[]const u8` | `"rооt"` with Cyrillic `о` | passes: exact match only, not a look-alike check |
| `.{ .admin, .viewer }` | `Role` | `.editor` | passes |
| `.{ .a, .b }` | `Open`, as above | `@fromBackingInt(9)` | passes: an unnamed value is never listed |
| `.{ 0, 13 }` | `u8` | `13` | `validation.none_of`: `must not be one of: 0, 13` |
| `.{-1}` | `i32` | `-1` | `validation.none_of`: `must not be -1` |

## v.empty

A string has no bytes; a list has no items.

- **Field types:** a string; a slice `[]const T` or `[]T` of any other item type;
  `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** `value.len == 0`. A string counts bytes without decoding, so
  `" "`, `"\t"`, `"\x00"`, `"\xff"` and U+200B are not empty. A slice counts
  items, `null` items included. A `null` optional skips the rule.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.empty`.
- **Default message:** `must be empty`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D21](class_validator.md#deviations-from-validatorjs) (an
  empty slice passes), [D61](class_validator.md#deviations-from-validatorjs) (a
  fixed-length array is a compile error),
  [D60](class_validator.md#deviations-from-validatorjs) (`v.empty` with
  `v.notEmpty` or `v.minItems(1)` is a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: empty on [3]u32 is always false: the length of an array is fixed
validator: <Type>.field_rules.<field>: empty on [0]u32 is always true: the length of an array is fixed
validator: <Type>.field_rules.<field>: empty on [4]u8 is always false: the length of an array is fixed; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: empty expects a string or a slice, field is u32
validator: <Type>.field_rules.<field>: empty and min_items(1) contradict; no value can pass
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `[]const u8` | `""` | passes |
| `[]const u8` | `" "` | `validation.empty`: a space is a byte |
| `[]const u8` | `"\xff"` | `validation.empty`: the bytes are not decoded |
| `[]const u32` | `&.{}` | passes: an empty slice, unlike class-validator's `IsEmpty` |
| `[]const u32` | `&.{0}` | `validation.empty` |
| `[]const ?u32` | `&.{null}` | `validation.empty`: a `null` item is an item |
| `[]const []const u8` | `&.{""}` | `validation.empty`: an empty string is an item |
| `?[]const u8` | `null` | passes: `null` skips the rule |

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
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D14](class_validator.md#deviations-from-validatorjs) (`null`
  skips the rule; one rule for strings and lists),
  [D61](class_validator.md#deviations-from-validatorjs) (a fixed-length array is
  a compile error), [D60](class_validator.md#deviations-from-validatorjs)
  (`v.notEmpty` with `v.empty` is a compile error).

[v.minItems(1)](lists.md#vminitemsmin) fails an empty list too, with the code
`validation.min_items`. The two overlap and differ in the code; prefer
`v.notEmpty`. For text a user must fill in, use
[v.notBlank](strings.md#vnotblank); [v.minBytes(1)](strings.md#vminbytesmin)
fails an empty string too, with `validation.min_bytes`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: not_empty on [3]u32 is always true: the length of an array is fixed
validator: <Type>.field_rules.<field>: not_empty on [0]u32 is always false: the length of an array is fixed
validator: <Type>.field_rules.<field>: not_empty on [4]u8 is always true: the length of an array is fixed; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: not_empty expects a string or a slice, field is u32
validator: <Type>.field_rules.<field>: not_empty and empty contradict; no value can pass
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
