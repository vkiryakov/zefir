# Numbers

Rules for integer and float fields: `v.min`, `v.max` and `v.range` bound a
number, `v.positive`, `v.nonNegative`, `v.negative` and `v.nonPositive` check its
sign, `v.divisibleBy` checks that it is a multiple, and `v.finite` that a float
is a number at all.

```zig
const Payment = struct {
    amount_cents: u64,
    rate: f64,
    installments: []const u32,
    retries: u8,

    pub const field_rules = .{
        .amount_cents = .{ v.positive, v.divisibleBy(5) },
        .rate = v.range(0, 1), // NaN and infinities fail first, with validation.finite
        .installments = v.each(v.positive),
        .retries = v.max(5),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.min(min)](#vminmin)
- [v.max(max)](#vmaxmax)
- [v.range(min, max)](#vrangemin-max)
- [v.positive](#vpositive)
- [v.nonNegative](#vnonnegative)
- [v.negative](#vnegative)
- [v.nonPositive](#vnonpositive)
- [v.divisibleBy(divisor)](#vdivisiblebydivisor)
- [v.finite](#vfinite)

## Common to all rules on this page

- An integer is any integer type, signed or unsigned, of any width: `u8` …
  `u128`, `i8` … `i128`, `usize`, `isize`. A float is `f16`, `f32`, `f64`,
  `f80`, `f128` or `c_longdouble`.
- On a float field every rule of this page except `v.finite` first checks that
  the value is finite: NaN, `+inf` and `-inf` fail with `validation.finite` /
  `must be a finite number`, before the rule's own check
  ([D16](class_validator.md#deviations-from-validatorjs)). `.withMessage` does not
  change that code and message ([Messages](README.md#preconditions)). Integer
  fields have no precondition.
- A bound or a divisor is known at compile time and converted to the field type
  then: an integer exactly, a float rounded to the nearest value of the type. A
  rule that every value of the field type passes, such as `v.min(0)` on a `u8`,
  `v.nonNegative` on an unsigned integer or `v.finite` on an integer, is a
  compile error with a hint to remove it
  ([D61](class_validator.md#deviations-from-validatorjs)).
- A typed float bound narrower than a float field, such as an `f32` constant
  on an `f64` field, keeps its exact value there: `@as(f32, 0.1)` is
  0.10000000149011612 in `f64`. When that value reads differently from the
  bound as written, the bound is a compile error, since the message would show
  another value than the one compared: write it as a literal or in the field's
  type. On a `c_longdouble` field this depends on the target.
- The default messages show a bound as written, before the conversion
  (`v.max(0.1)` on an `f32` says `must be at most 0.1`), and
  `.withMessage` can use it as a placeholder
  ([Messages](README.md#placeholders)).
- `v.min`, `v.max`, `v.range` and `v.divisibleBy` have no fallback message: a
  bound or a divisor of hundreds of digits makes the field a compile error
  unless `.withMessage` replaces the message
  ([Fallback messages](README.md#fallback-messages)).
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule. Inside `v.each(...)` it checks each item; on a slice or an array of
  numbers itself it is a compile error that suggests `v.each`.
- The rules take O(1) time and allocate nothing.

## v.min(min)

A number is at least `min`.

- **Field types:** an integer or a float; `?T` and `??T` of these.
- **Parameters:** `min`, known at compile time: an integer or a finite float. It
  must fit the field type. On an integer field it is an integer within the type,
  not a float (`2.0` included), and not `minInt(T)`, which every value passes. On
  a float field an integer must be exactly representable (`v.min(16777217)` on an
  `f32` is an error that names the nearest value), a float must not become
  infinite or, when it is not zero, round to 0, and a typed float narrower than
  the field must read the same there (`v.min(@as(f32, 0.1))` on an `f64` is an
  error).
- **Passes when:** on a float field, the value is finite first; then
  `value >= min`, compared in the field type `T`: integers exactly at every width,
  floats against `min` rounded to nearest, so `v.min(0.1)` on an `f32` accepts the
  `f32` nearest to 0.1.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.min`.
- **Default message:** `must be at least {min}`.
- **Placeholders:** `{min}`: the bound as written, before the conversion to the
  field type.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D58](class_validator.md#deviations-from-validatorjs) (integers are exact),
  [D61](class_validator.md#deviations-from-validatorjs) (`v.min(minInt(T))` is a
  compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: min("5"): the bound must be a number, got *const [1:0]u8
validator: <Type>.field_rules.<field>: min(1.5): 1.5 is a float (comptime_float), field is u8; use an integer bound
validator: <Type>.field_rules.<field>: min(-1): -1 is outside u64 (0..18446744073709551615)
validator: <Type>.field_rules.<field>: min(16777217): 16777217 is not exactly representable in f32 (nearest: 16777216)
validator: <Type>.field_rules.<field>: min(0.1): 0.1 is a float (f32), 0.10000000149011612 in f64; write it as a literal or as f64
validator: <Type>.field_rules.<field>: min(0) is always true for u8; remove it
validator: <Type>.field_rules.<field>: min must be called, e.g. v.min(0)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.min(10)` | `u8` | `9` | `validation.min` |
| `v.min(10)` | `u8` | `10` | passes: the bound itself |
| `v.min(255)` | `u8` | `254` | `validation.min`: the bound `maxInt(u8)` is not vacuous, only 255 passes |
| `v.min(18446744073709551615)` | `u64` | `18446744073709551614` | `validation.min`: integers are exact at every width |
| `v.min(0.5)` | `f32` | `0.49` | `validation.min`: `must be at least 0.5` |
| `v.min(0.1)` | `f32` | the `f32` nearest to 0.1 | passes: the bound is rounded to the field type |
| `v.min(0.1)` | `f32` | `0.099999994`, the `f32` below it | `validation.min`: `must be at least 0.1` |
| `v.min(-0.0)` | `f64` | `-1e-300` | `validation.min`: `must be at least 0` |
| `v.min(0)` | `f64` | NaN | `validation.finite` |
| `v.min(0)` | `f64` | `+inf` | `validation.finite`: class-validator's `Min` accepts it |
| `v.min(10)` | `?u8` | `null` | passes: `null` skips the rule |

## v.max(max)

A number is at most `max`.

- **Field types:** an integer or a float; `?T` and `??T` of these.
- **Parameters:** `max`, a bound as for [v.min](#vminmin); `v.max(maxInt(T))`
  would pass every value and is a compile error.
- **Passes when:** on a float field, the value is finite first; then
  `value <= max`, compared in the field type `T` after the bound is converted at
  compile time, as in `v.min`.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.max`.
- **Default message:** `must be at most {max}`.
- **Placeholders:** `{max}`: the bound as written, before the conversion to the
  field type.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D58](class_validator.md#deviations-from-validatorjs) (integers are exact),
  [D61](class_validator.md#deviations-from-validatorjs) (`v.max(maxInt(T))` is a
  compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: max(nan): nan is not finite
validator: <Type>.field_rules.<field>: max(300): 300 is outside u8 (0..255)
validator: <Type>.field_rules.<field>: max(18446744073709551615) is always true for u64; remove it
validator: <Type>.field_rules.<field>: max expects a number, field is []const i32; use v.each(v.max(0))
validator: <Type>.field_rules.<field>: max must be called, e.g. v.max(100)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.max(10)` | `u8` | `11` | `validation.max` |
| `v.max(10)` | `u8` | `10` | passes: the bound itself |
| `v.max(0)` | `u8` | `1` | `validation.max`: not vacuous on an unsigned field, only 0 passes |
| `v.max(-1)` | `i64` | `0` | `validation.max` |
| `v.max(18446744073709551614)` | `u64` | `18446744073709551615` | `validation.max`: integers are exact at every width |
| `v.max(0.1)` | `f32` | `0.10000001`, the `f32` above 0.1 | `validation.max`: `must be at most 0.1` |
| `v.max(1e-7)` | `f64` | `2e-7` | `validation.max`: `must be at most 1e-7` |
| `v.max(10)` | `f64` | `-inf` | `validation.finite`: class-validator's `Max` accepts it |
| `v.max(120).withMessage("must be a realistic age")` | `u8` | `121` | `validation.max` / `must be a realistic age` |

## v.range(min, max)

A number is from `min` to `max`, both included.

- **Field types:** an integer or a float; `?T` and `??T` of these.
- **Parameters:** `min` and `max`, each a bound as for [v.min](#vminmin), with
  `min` not greater than `max` as written. `v.range(a, a)` is allowed;
  `v.range(minInt(T), maxInt(T))` would pass every value and is a compile error.
  One bound at the limit of the type is fine: `v.range(0, 100)` on a `u8`.
- **Passes when:** on a float field, the value is finite first; then
  `min <= value` and `value <= max`, compared in the field type `T` after both
  bounds are converted at compile time.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.range`.
- **Default message:** `must be from {min} to {max}`; for `min` equal to `max`
  `must be {min}`.
- **Placeholders:** `{min}` and `{max}`: the bounds as written.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D58](class_validator.md#deviations-from-validatorjs) (integers are exact),
  [D61](class_validator.md#deviations-from-validatorjs) (`v.range(minInt(T),
  maxInt(T))` is a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: range(10, 5): min is greater than max
validator: <Type>.field_rules.<field>: range(-129, 0): -129 is outside i8 (-128..127)
validator: <Type>.field_rules.<field>: range(0, 255) is always true for u8; remove it
validator: <Type>.field_rules.<field>: range expects a number, field is []const i32; use v.each(v.range(0, 100))
validator: <Type>.field_rules.<field>: range must be called, e.g. v.range(1, 100)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.range(1, 254)` | `u8` | `0` | `validation.range`: `must be from 1 to 254` |
| `v.range(1, 254)` | `u8` | `255` | `validation.range` |
| `v.range(1, 254)` | `u8` | `1` | passes: the lower bound itself |
| `v.range(1, 254)` | `u8` | `254` | passes: the upper bound itself |
| `v.range(0, 100)` | `u8` | `101` | `validation.range`: a bound at the limit of the type is allowed |
| `v.range(5, 5)` | `u8` | `6` | `validation.range`: `must be 5` |
| `v.range(-2.5, 2.5)` | `f64` | `-2.6` | `validation.range`: `must be from -2.5 to 2.5` |
| `v.range(-2.5, 2.5)` | `f64` | `-2.5` | passes |
| `v.range(-1, 1)` | `f64` | NaN | `validation.finite` |

## v.positive

A number is greater than 0.

- **Field types:** an integer or a float; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** on a float field, the value is finite first; then
  `value > 0` (on an unsigned integer, `value != 0`). `-0.0` and `0.0` fail; the
  smallest subnormal number passes; `+inf` fails with `validation.finite`.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.positive`.
- **Default message:** `must be greater than 0`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: positive expects a number, field is []const u8
validator: <Type>.field_rules.<field>: positive expects a number, field is []const u32; use v.each(v.positive)
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `u8` | `0` | `validation.positive` |
| `u8` | `1` | passes |
| `i64` | `-1` | `validation.positive` |
| `i64` | `-9223372036854775808` (`minInt(i64)`) | `validation.positive` |
| `i64` | `9223372036854775807` (`maxInt(i64)`) | passes |
| `u64` | `18446744073709551615` (`maxInt(u64)`) | passes |
| `f64` | `-0.0` | `validation.positive` |
| `f64` | `0.0` | `validation.positive` |
| `f64` | `5e-324`, the smallest subnormal | passes |
| `f32` | `1e-45`, the smallest subnormal | passes |
| `f64` | NaN | `validation.finite` |
| `f64` | `+inf` | `validation.finite` |
| `??f64` | `0.0` | `validation.positive`: nested optionals are unwrapped |

## v.nonNegative

A number is not negative: 0 or greater.

- **Field types:** a signed integer or a float; `?T` and `??T` of these. On an
  unsigned integer the rule is always true, which is a compile error.
- **Parameters:** none.
- **Passes when:** on a float field, the value is finite first; then
  `value >= 0`. `-0.0` passes; `-inf` fails with `validation.finite`.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.non_negative`.
- **Default message:** `must not be negative`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D61](class_validator.md#deviations-from-validatorjs) (an unsigned field is a
  compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: non_negative is always true for u32; remove it
validator: <Type>.field_rules.<field>: non_negative expects a signed integer or a float, field is []const u8
validator: <Type>.field_rules.<field>: non_negative expects a signed integer or a float, field is []const i32; use v.each(v.nonNegative)
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `i64` | `-1` | `validation.non_negative` |
| `i64` | `-9223372036854775808` (`minInt(i64)`) | `validation.non_negative` |
| `i64` | `0` | passes |
| `i64` | `9223372036854775807` (`maxInt(i64)`) | passes |
| `f64` | `-0.0` | passes: `-0.0` is not negative |
| `f64` | `-5e-324`, the smallest negative subnormal | `validation.non_negative` |
| `f64` | NaN | `validation.finite` |
| `f64` | `+inf` | `validation.finite`: class-validator's `Min(0)` accepts it |

## v.negative

A number is less than 0.

- **Field types:** a signed integer or a float; `?T` and `??T` of these. On an
  unsigned integer the rule is always false, which is a compile error.
- **Parameters:** none.
- **Passes when:** on a float field, the value is finite first; then
  `value < 0`. `-0.0` fails, `minInt(T)` passes, and `-inf` fails with
  `validation.finite`.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.negative`.
- **Default message:** `must be less than 0`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D61](class_validator.md#deviations-from-validatorjs) (an unsigned field is a
  compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: negative is always false for u32 (an unsigned type)
validator: <Type>.field_rules.<field>: negative expects a signed integer or a float, field is []const u8
validator: <Type>.field_rules.<field>: negative expects a signed integer or a float, field is []const i32; use v.each(v.negative)
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `i32` | `-1` | passes |
| `i32` | `0` | `validation.negative` |
| `i64` | `-9223372036854775808` (`minInt(i64)`) | passes |
| `f64` | `-0.0` | `validation.negative`: `-0.0 < 0` is false |
| `f64` | `-5e-324`, the smallest negative subnormal | passes |
| `f64` | NaN | `validation.finite` |
| `f64` | `-inf` | `validation.finite`: class-validator's `IsNegative` accepts it |

## v.nonPositive

A number is not positive: 0 or less.

- **Field types:** a signed integer or a float; `?T` and `??T` of these. On an
  unsigned integer only 0 would pass, which is a compile error that suggests
  `v.equals(0)`.
- **Parameters:** none.
- **Passes when:** on a float field, the value is finite first; then
  `value <= 0`. `-0.0` passes; `-inf` fails with `validation.finite`.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.non_positive`.
- **Default message:** `must not be positive`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D61](class_validator.md#deviations-from-validatorjs) (an unsigned field is a
  compile error).

`v.nonPositive` and `v.max(0)` overlap on a signed field; they differ in the code
(`validation.non_positive`, `validation.max`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: non_positive on u8 only accepts 0; use v.equals(0)
validator: <Type>.field_rules.<field>: non_positive expects a signed integer or a float, field is []const u8
validator: <Type>.field_rules.<field>: non_positive expects a signed integer or a float, field is []const i32; use v.each(v.nonPositive)
```

Examples:

| Field type | Value | Result |
| --- | --- | --- |
| `i32` | `0` | passes |
| `i32` | `-1` | passes |
| `i32` | `1` | `validation.non_positive` |
| `i64` | `9223372036854775807` (`maxInt(i64)`) | `validation.non_positive` |
| `f64` | `-0.0` | passes |
| `f64` | `5e-324`, the smallest subnormal | `validation.non_positive` |
| `f64` | NaN | `validation.finite` |
| `f64` | `-inf` | `validation.finite`: class-validator's `Max(0)` accepts it |

## v.divisibleBy(divisor)

A number is a multiple of `divisor`.

- **Field types:** an integer or a float; `?T` and `??T` of these.
- **Parameters:** `divisor`, known at compile time: an integer of at least 1.
  A float divisor is an error (`2.0` included). On an integer field the divisor
  is from 2 up to the largest magnitude of the type, `max(maxInt(T), -minInt(T))`:
  `v.divisibleBy(1)` would pass every value, and a larger divisor would leave
  only 0 (use `v.equals(0)`). On a float field the divisor must be exactly
  representable in the type, and 1 is allowed: it means "a whole number".
- **Passes when:** for an integer, `@rem(value, divisor) == 0`, exact at every
  width, with no rounding above 2^53; when the divisor is `-minInt(T)` (128 on an
  `i8`), only 0 and `minInt(T)` pass. For a float, the value is finite first;
  then `@rem(value, divisor) == 0` in the field type, which is exact: `-0.0`
  passes and a fractional value fails.
- **`""`:** not a string rule.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.divisible_by`.
- **Default message:** `must be divisible by {divisor}`.
- **Placeholders:** `{divisor}`: the divisor, an integer in decimal.
- **Predicate:** none.
- **Complexity:** O(1) (the remainder of a float is bounded by the exponent
  range); allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D18](class_validator.md#deviations-from-validatorjs) (integers are exact),
  [D19](class_validator.md#deviations-from-validatorjs) (the divisor is a
  positive integer that fits).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: divisibleBy(0): division by zero; no value would pass
validator: divisibleBy(-5): the divisor is negative; use v.divisibleBy(5)
validator: divisibleBy(0.5): the divisor must be an integer, got comptime_float; fractional divisors are inexact on binary floats: count whole units (e.g. cents)
validator: <Type>.field_rules.<field>: divisible_by(1) is always true for u32; remove it
validator: <Type>.field_rules.<field>: divisible_by(1000) on u8 (0..255): only 0 would pass; use v.equals(0)
validator: <Type>.field_rules.<field>: divisibleBy must be called, e.g. v.divisibleBy(2)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.divisibleBy(5)` | `i32` | `10` | passes |
| `v.divisibleBy(5)` | `i32` | `0` | passes: 0 is a multiple of every divisor |
| `v.divisibleBy(5)` | `i32` | `-15` | passes |
| `v.divisibleBy(5)` | `i32` | `-7` | `validation.divisible_by` |
| `v.divisibleBy(3)` | `u64` | `9007199254740993` | passes: exact above 2^53, unlike class-validator |
| `v.divisibleBy(128)` | `i8` | `-128` | passes: the divisor does not fit an `i8`, but `minInt(i8)` is its multiple |
| `v.divisibleBy(128)` | `i8` | `127` | `validation.divisible_by` |
| `v.divisibleBy(5)` | `f64` | `10` | passes |
| `v.divisibleBy(5)` | `f64` | `7.5` | `validation.divisible_by` |
| `v.divisibleBy(5)` | `f64` | `-0.0` | passes |
| `v.divisibleBy(1)` | `f64` | `2.5` | `validation.divisible_by`: on a float field 1 means a whole number |
| `v.divisibleBy(5)` | `f64` | NaN | `validation.finite` |

## v.finite

A float is neither NaN nor an infinity.

- **Field types:** a float; `?T` and `??T` of these. On an integer field the rule
  is always true, which is a compile error.
- **Parameters:** none.
- **Passes when:** the value is not NaN, `+inf` or `-inf` (`std.math.isFinite`).
  `-0.0`, subnormal numbers and `±floatMax` pass.
- **`""`:** not a string rule.
- **Precondition:** none. NaN and infinities are the rule's own failure, with the
  same code and message that the other rules of this page report as their
  precondition. `.withMessage` applies to it: put `v.finite.withMessage(...)`
  before other number rules to give NaN and infinities a message of your own
  ([Messages](README.md#preconditions)).
- **Code:** `validation.finite`.
- **Default message:** `must be a finite number`.
- **Placeholders:** none.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D61](class_validator.md#deviations-from-validatorjs) (an
  integer field is a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: finite is always true for u32; remove it
validator: <Type>.field_rules.<field>: finite expects a float, field is []const u8
validator: <Type>.field_rules.<field>: finite expects a float, field is []const f64; use v.each(v.finite)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.finite` | `f64` | `0.0`, `-0.0` or `1.5` | passes |
| `v.finite` | `f64` | NaN | `validation.finite` / `must be a finite number` |
| `v.finite` | `f64` | `+inf` or `-inf` | `validation.finite` |
| `v.finite` | `f64` | `1.7976931348623157e308`, the largest `f64` | passes |
| `v.finite` | `f64` | `5e-324`, the smallest subnormal | passes |
| `v.finite.withMessage("цена должна быть числом")` | `f64` | NaN | `validation.finite` / `цена должна быть числом` |
| `v.finite` | `?f64` | `null` | passes: `null` skips the rule |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
