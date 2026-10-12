# Numbers

Rules for integer and float fields: `v.positive` checks that a number is
greater than 0.

```zig
const Payment = struct {
    amount_cents: u64,
    rate: f64,
    installments: []const u32,

    pub const field_rules = .{
        .amount_cents = v.positive,
        .rate = v.positive, // NaN and infinities fail first, with validation.finite
        .installments = v.each(v.positive),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.positive](#vpositive)

## Common to all rules on this page

- An integer is any integer type, signed or unsigned, of any width: `u8` …
  `u128`, `i8` … `i128`, `usize`, `isize`. A float is `f16`, `f32`, `f64`,
  `f80`, `f128` or `c_longdouble`.
- On a float field a rule first checks that the value is finite: NaN, `+inf`
  and `-inf` fail with `validation.finite` / `must be a finite number`, before
  the rule's own check ([D16](class_validator.md#deviations-from-validatorjs)).
  Integer fields have no precondition.
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule. Inside `v.each(...)` it checks each item; on a slice or an array of
  numbers itself it is a compile error that suggests `v.each`.
- The rules take O(1) time and allocate nothing.

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

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
