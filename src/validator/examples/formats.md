# Formats

Rules for strings that hold a value in a known format: numbers, booleans and
coordinates written as text (`v.numberString`, `v.decimal`, `v.booleanString`,
`v.hexadecimal`, `v.octal`, `v.port`, `v.latitude`, `v.longitude`,
`v.latLong`), and network addresses and names (`v.email`, `v.httpUrl`,
`v.fqdn`, `v.ip`, `v.ipv4`, `v.ipv6`, `v.macAddress`). Each rule has a
predicate with the same grammar, `v.isEmail(s)` and so on, for code outside
`field_rules`.

```zig
const Server = struct {
    host: []const u8,
    port: []const u8,
    admin: ?[]const u8 = null,
    mirrors: []const []const u8 = &.{},
    lat: f64,

    pub const field_rules = .{
        .host = v.fqdn(.{ .require_tld = false }), // "localhost" passes
        .port = v.port,
        .admin = v.email, // null skips the rule
        .mirrors = .{ v.maxItems(5), v.each(v.httpUrl) },
        .lat = v.latitude, // a float field: NaN fails with validation.finite
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.numberString](#vnumberstring)
- [v.decimal(options)](#vdecimaloptions)
- [v.booleanString](#vbooleanstring)
- [v.hexadecimal](#vhexadecimal)
- [v.octal](#voctal)
- [v.port](#vport)
- [v.latitude](#vlatitude)
- [v.longitude](#vlongitude)
- [v.latLong](#vlatlong)
- [v.email](#vemail)
- [v.httpUrl](#vhttpurl)
- [v.fqdn(options)](#vfqdnoptions)
- [v.ip](#vip)
- [v.ipv4](#vipv4)
- [v.ipv6](#vipv6)
- [v.macAddress(options)](#vmacaddressoptions)

## Common to all rules on this page

- The field is a string: a slice of `u8` of any constness, sentinel and
  alignment (`[]const u8`, `[]u8`, `[:0]const u8`). `[N]u8` is an array of
  numbers, not a string, and slices with `volatile` or `allowzero` are not
  strings either: the rules reject them with a compile error. `v.latitude` and
  `v.longitude` also take float fields.
- Every rule also accepts `?T` and `??T` of the types it accepts: `null` skips
  the rule. Inside `v.each(...)` it checks each item; on a slice or an array of
  strings itself it is a compile error that suggests `v.each`.
- The grammars are ASCII and the rules read bytes: nothing is trimmed, decoded
  or normalized. Invalid UTF-8 and any byte from 0x80 up fail under the rule's
  own code, so `.withMessage` applies to them too.
- `""` fails every rule on this page: it is not in the language of any of these
  formats. Put `v.notEmpty` first to give an empty value a message of its own.
- Only `v.latitude` and `v.longitude` have a precondition, and only on float
  fields: NaN, `+inf` and `-inf` fail with `validation.finite` /
  `must be a finite number` ([Preconditions](README.md#preconditions)).
- `v.decimal`, `v.fqdn` and `v.macAddress` take their options as a struct
  literal known at compile time: omitted fields keep their defaults, and
  `.{}` takes them all. Compile errors and hints show the options as `.{...}`.
  A rule used without its call, `.host = v.fqdn`, is a compile error that shows
  the call: `fqdn must be called, e.g. v.fqdn(.{})`.
- **Predicates.** Each rule has a predicate, `pub fn isX(s: []const u8) bool`, or
  `isX(s: []const u8, options: XOptions) bool` for a rule with options: it is
  true exactly when the rule passes `s`. Use it where a rule does not fit, in
  `validateSelf`, a service or a test. It never panics, allocates nothing and
  runs in O(n) on any bytes. Its options may be known only at run time and are
  applied as given, without the checks of the rule. `v.isLatitude` and
  `v.isLongitude` cover the string form only. A predicate in `field_rules` is a
  compile error that names the rule: `expected a rule, got the predicate
  isEmail; use the rule v.email`.
- The rules take O(n) time without backtracking and allocate nothing.
  `v.port`, `v.ip`, `v.ipv4`, `v.ipv6` and `v.macAddress` read at most 45
  bytes, `v.email` gives up above 254 bytes and `v.fqdn` above 253 (254 with an
  allowed trailing dot). The others have no length limit: combine them with a
  length rule.
- They check the form only: an address that passes may not exist, and a URL
  that passes may point anywhere.

## v.numberString

A number in decimal notation.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** after one optional `+` or `-`, the value is 1 or more ASCII
  digits, or 0 or more digits, `.` and 1 or more digits: `.5` and `-.5` pass. No
  exponent, digit grouping, `_` or whitespace, and the size of the number is
  not limited.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.number_string`.
- **Default message:** `must be a number`.
- **Placeholders:** none.
- **Predicate:** `v.isNumberString(s: []const u8) bool`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** none: validator.js `isNumeric` with its default options.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: number_string expects a string, field is u32; the field is already a number: use v.min, v.max or v.range
validator: <Type>.field_rules.<field>: number_string expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: number_string expects a string, field is []const []const u8; use v.each(v.numberString)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.numberString` | `[]const u8` | `"-12.5"`, `"007"`, `"+0"` | passes |
| `v.numberString` | `[]const u8` | `".5"` | passes: the digits before the point may be absent |
| `v.numberString` | `[]const u8` | `"5."` | `validation.number_string`: a point needs digits after it |
| `v.numberString` | `[]const u8` | `"1e5"`, `"1,000"`, `"1_000"`, `"0x1F"` | `validation.number_string` |
| `v.numberString` | `[]const u8` | `" 1"` | `validation.number_string`: nothing is trimmed |
| `v.numberString` | `?[]const u8` | `null` | passes: `null` skips the rule |

## v.decimal(options)

A decimal number with as many digits after the point as the options allow.
Written `v.decimal(.{ ... })`.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** `options: v.DecimalOptions`, known at compile time:
  - `.force_decimal: bool = false`: the point and digits after it are
    required;
  - `.min_decimal_digits: usize = 1`: the fewest digits after the point, at
    least 1;
  - `.max_decimal_digits: ?usize = null`: the most digits after the point, not
    below `min_decimal_digits`; `null` for no limit.
- **Passes when:** after one optional `+` or `-`, a run of ASCII digits, then
  either the end (when `force_decimal` is false and the run is not empty) or
  `.` followed by only digits, from `min_decimal_digits` to
  `max_decimal_digits` of them. The digits before the point may be absent:
  `.5` passes, also with `force_decimal`. `v.decimal(.{})` passes exactly what
  `v.numberString` passes. No exponent, grouping, comma as the decimal mark or
  whitespace.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.decimal`.
- **Default message:** chosen from the options; `decimal places` becomes
  `decimal place` when the number shown is 1:

  | `force_decimal` | Digits after the point | Message |
  | --- | --- | --- |
  | `false` | the defaults: 1 or more | `must be a decimal number` |
  | `false` | at least `min`, from 2 | `must be a whole number or have at least {min_decimal_digits} decimal places` |
  | `false` | at most `max`, `min` 1 | `must be a decimal number with at most {max_decimal_digits} decimal places` |
  | `false` | exactly `min` = `max`, from 2 | `must be a whole number or have exactly {min_decimal_digits} decimal places` |
  | `false` | from `min` (2 or more) to `max` | `must be a whole number or have {min_decimal_digits} to {max_decimal_digits} decimal places` |
  | `true` | at least `min` | `must be a decimal number with at least {min_decimal_digits} decimal places` |
  | `true` | exactly `min` = `max` | `must be a decimal number with exactly {min_decimal_digits} decimal places` |
  | `true` | from `min` to `max` | `must be a decimal number with {min_decimal_digits} to {max_decimal_digits} decimal places` |

- **Placeholders:** `{min_decimal_digits}`, and `{max_decimal_digits}` when the
  maximum is set (otherwise it is an unknown placeholder).
- **Predicate:** `v.isDecimal(s: []const u8, options: v.DecimalOptions) bool`. It
  applies its options as given: `.min_decimal_digits = 0` accepts `"1."` and
  `"."`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D28](class_validator.md#deviations-from-validatorjs)
  (`.min_decimal_digits = 0` and a maximum below the minimum are compile
  errors).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: decimal(.{...}): min_decimal_digits must be at least 1 (0 would accept "1." and ".")
validator: decimal(.{...}): max_decimal_digits (2) is less than min_decimal_digits (3)
validator: decimal(.{...}).withMessage("at most {max_decimal_digits} places"): unknown placeholder {max_decimal_digits}; available: {min_decimal_digits}
validator: <Type>.field_rules.<field>: decimal expects a string, field is f64; the field is already a number: use v.min, v.max or v.range
validator: <Type>.field_rules.<field>: decimal expects a string, field is []const []const u8; use v.each(v.decimal(.{...}))
validator: <Type>.field_rules.<field>: decimal must be called, e.g. v.decimal(.{})
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.decimal(.{})` | `[]const u8` | `"12"`, `"+.5"`, `"-12.25"` | passes |
| `v.decimal(.{})` | `[]const u8` | `"1."` | `validation.decimal`: `must be a decimal number` |
| `v.decimal(.{ .max_decimal_digits = 2 })` | `[]const u8` | `"19.99"` | passes |
| `v.decimal(.{ .max_decimal_digits = 2 })` | `[]const u8` | `"1.234"` | `validation.decimal`: `must be a decimal number with at most 2 decimal places` |
| `v.decimal(.{ .force_decimal = true })` | `[]const u8` | `"12"` | `validation.decimal`: `must be a decimal number with at least 1 decimal place` |
| `v.decimal(.{ .min_decimal_digits = 2 })` | `[]const u8` | `"15"` | passes: a whole number has no decimal places to count |
| `v.decimal(.{ .min_decimal_digits = 2 })` | `[]const u8` | `"1.5"` | `validation.decimal`: `must be a whole number or have at least 2 decimal places` |
| `v.decimal(.{})` | `[]const u8` | `"1,5"`, `"1e3"` | `validation.decimal` |

## v.booleanString

`true`, `false`, `1` or `0` as text.

- **Field types:** a string; `?T` and `??T` of these. A `bool` field is already a
  boolean, so the rule on it is a compile error.
- **Parameters:** none.
- **Passes when:** the value is exactly `true`, `false`, `1` or `0`:
  case-sensitive, without `yes`, `no` or `on`, nothing trimmed.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.boolean_string`.
- **Default message:** `must be true, false, 1 or 0`.
- **Placeholders:** none.
- **Predicate:** `v.isBooleanString(s: []const u8) bool`.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** none: validator.js `isBoolean` with its default options.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: boolean_string expects a string, field is bool; a bool field is already a boolean and needs no rule
validator: <Type>.field_rules.<field>: boolean_string expects a string, field is u8; use a bool field
validator: <Type>.field_rules.<field>: boolean_string expects a string, field is []const []const u8; use v.each(v.booleanString)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.booleanString` | `[]const u8` | `"true"`, `"false"`, `"1"`, `"0"` | passes |
| `v.booleanString` | `[]const u8` | `"TRUE"`, `"True"` | `validation.boolean_string`: case-sensitive |
| `v.booleanString` | `[]const u8` | `"yes"`, `"on"` | `validation.boolean_string` |
| `v.booleanString` | `[]const u8` | `"true "` | `validation.boolean_string`: nothing is trimmed |

## v.hexadecimal

A hexadecimal number.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** after an optional prefix `0x`, `0X`, `0h` or `0H`, the value
  is 1 or more digits `0-9`, `a-f`, `A-F`. No sign, `#`, `h` suffix or
  separators; the prefix counts toward the length.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.hexadecimal`.
- **Default message:** `must be a hexadecimal number`.
- **Placeholders:** none.
- **Predicate:** `v.isHexadecimal(s: []const u8) bool`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** none: validator.js `isHexadecimal`, the `0h` prefix included.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: hexadecimal expects a string, field is u32; the field is already a number: use v.min, v.max or v.range
validator: <Type>.field_rules.<field>: hexadecimal expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.hexadecimal` | `[]const u8` | `"0xDEADbeef"`, `"ff"`, `"0h1F"`, `"0"` | passes |
| `v.hexadecimal` | `[]const u8` | `"0x"` | `validation.hexadecimal`: a prefix needs digits |
| `v.hexadecimal` | `[]const u8` | `"#ff"`, `"-1"`, `"1h"` | `validation.hexadecimal` |

## v.octal

An octal number.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** after an optional prefix `0o` or `0O`, the value is 1 or more
  digits `0-7`. No sign and no other prefix; `017` is octal digits.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.octal`.
- **Default message:** `must be an octal number`.
- **Placeholders:** none.
- **Predicate:** `v.isOctal(s: []const u8) bool`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** none: validator.js `isOctal`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: octal expects a string, field is u16; the field is already a number: use v.min, v.max or v.range
validator: <Type>.field_rules.<field>: octal expects a string, field is []const []const u8; use v.each(v.octal)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.octal` | `[]const u8` | `"0o755"`, `"0O17"`, `"017"`, `"0"` | passes |
| `v.octal` | `[]const u8` | `"8"`, `"0o8"` | `validation.octal` |
| `v.octal` | `[]const u8` | `"0x17"`, `"0b1"`, `"-7"` | `validation.octal` |

## v.port

A TCP or UDP port number as text, 0 to 65535.

- **Field types:** a string; `?T` and `??T` of these. For a number, use a `u16`
  field: it holds 0 to 65535 already, and `v.min(1)` excludes 0.
- **Parameters:** none.
- **Passes when:** the value is 1 to 5 ASCII digits without a leading zero
  (`"0"` itself passes) and at most 65535. No sign, whitespace, `.`, exponent or
  hex.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.port`.
- **Default message:** `must be a port number from 0 to 65535`.
- **Placeholders:** none.
- **Predicate:** `v.isPort(s: []const u8) bool`.
- **Complexity:** O(1): at most 5 bytes are read; allocates nothing.
- **Deviations:** [D24](class_validator.md#deviations-from-validatorjs) (a sign
  is rejected), [D62](class_validator.md#deviations-from-validatorjs) (a number
  field is a compile error).

The port of `v.httpUrl` differs on purpose: there it is 1 to 65535, and
leading zeros are allowed (`http://example.com:080/` passes).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: port expects a string, field is u16; a u16 field already holds 0-65535: add v.min(1) to exclude 0, or use v.range(0, 65535) on a wider type
validator: <Type>.field_rules.<field>: port expects a string, field is []const []const u8; use v.each(v.port)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.port` | `[]const u8` | `"0"`, `"80"`, `"65535"` | passes |
| `v.port` | `[]const u8` | `"65536"` | `validation.port` |
| `v.port` | `[]const u8` | `"080"` | `validation.port`: no leading zeros |
| `v.port` | `[]const u8` | `"+80"`, `"-0"` | `validation.port`: class-validator's `IsPort` accepts them |

## v.latitude

A latitude from -90 to 90 degrees, as text or as a float.

- **Field types:** a string or a float; `?T` and `??T` of these. An integer field
  is a compile error: integer coordinates are usually scaled (E6, E7), so use
  `v.range` in their unit.
- **Parameters:** none.
- **Passes when:** on a string, after one optional `+` or `-`, 1 or 2 digits of
  whole degrees up to 90 (2 digits do not start with `0`: `"05"` fails), then
  nothing or `.` and 1 or more digits, all `0` after 90. No comma, whitespace,
  exponent, degree sign or hemisphere letter. On a float, the value is finite
  first; then `-90 <= value <= 90` in the field type: `-0.0` and `1e-7` pass.
- **`""`:** fails.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`. A string has no
  precondition: `"NaN"` fails with `validation.latitude`.
- **Code:** `validation.latitude`.
- **Default message:** `must be a latitude from -90 to 90`.
- **Placeholders:** none.
- **Predicate:** `v.isLatitude(s: []const u8) bool`, for strings only.
- **Complexity:** O(n) on strings, O(1) on floats; allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs) (NaN and
  infinities fail with `validation.finite`),
  [D25](class_validator.md#deviations-from-validatorjs) (a comma is rejected),
  [D27](class_validator.md#deviations-from-validatorjs) (a float is a pure range
  check), [D62](class_validator.md#deviations-from-validatorjs) (an integer
  field is a compile error).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: latitude expects a string or a float, field is i32; integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-90_000_000, 90_000_000) for E6
validator: <Type>.field_rules.<field>: latitude expects a string or a float, field is []const f64; use v.each(v.latitude)
validator: <Type>.field_rules.<field>: latitude expects a string or a float, field is bool
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.latitude` | `[]const u8` | `"-33.8688"`, `"90"`, `"-90.000"`, `"0"` | passes |
| `v.latitude` | `[]const u8` | `"90.5"`, `"91"` | `validation.latitude` |
| `v.latitude` | `[]const u8` | `"05"` | `validation.latitude`: 2 digits do not start with 0 |
| `v.latitude` | `[]const u8` | `"1,5"`, `" 45"`, `"45N"` | `validation.latitude` |
| `v.latitude` | `f64` | `-90`, `90`, `-0.0`, `1e-7` | passes |
| `v.latitude` | `f32` | `90.00000762939453`, the `f32` above 90 | `validation.latitude` |
| `v.latitude` | `f64` | NaN | `validation.finite` |
| `v.latitude` | `?f64` | `null` | passes: `null` skips the rule |

## v.longitude

A longitude from -180 to 180 degrees, as text or as a float.

- **Field types:** a string or a float; `?T` and `??T` of these. An integer field
  is a compile error, as for `v.latitude`.
- **Parameters:** none.
- **Passes when:** on a string, after one optional `+` or `-`, 1 to 3 digits of
  whole degrees up to 180 (3 digits start with `1`: `"099"` fails; 2 digits may
  start with `0`: `"05"` passes), then nothing or `.` and 1 or more digits, all
  `0` after 180. No leading whitespace and no comma. On a float, the value is
  finite first; then `-180 <= value <= 180` in the field type.
- **`""`:** fails.
- **Precondition:** on float fields, finite: NaN, `+inf` and `-inf` fail with
  `validation.finite` / `must be a finite number`.
- **Code:** `validation.longitude`.
- **Default message:** `must be a longitude from -180 to 180`.
- **Placeholders:** none.
- **Predicate:** `v.isLongitude(s: []const u8) bool`, for strings only.
- **Complexity:** O(n) on strings, O(1) on floats; allocates nothing.
- **Deviations:** [D16](class_validator.md#deviations-from-validatorjs),
  [D25](class_validator.md#deviations-from-validatorjs) (no comma and no leading
  whitespace), [D27](class_validator.md#deviations-from-validatorjs),
  [D62](class_validator.md#deviations-from-validatorjs).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: longitude expects a string or a float, field is i64; integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-180_000_000, 180_000_000) for E6
validator: <Type>.field_rules.<field>: longitude expects a string or a float, field is []const []const u8; use v.each(v.longitude)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.longitude` | `[]const u8` | `"-74.0060"`, `"180"`, `"180.0"`, `"05"` | passes |
| `v.longitude` | `[]const u8` | `"180.1"`, `"181"`, `"099"` | `validation.longitude` |
| `v.longitude` | `[]const u8` | `" 45"` | `validation.longitude`: validator.js accepts one leading space |
| `v.longitude` | `f32` | `-180`, `180` | passes |
| `v.longitude` | `f64` | `360` | `validation.longitude` |
| `v.longitude` | `f64` | `-inf` | `validation.finite` |

## v.latLong

A `latitude,longitude` pair in one string.

- **Field types:** a string; `?T` and `??T` of these. For numbers, use two float
  fields with `v.latitude` and `v.longitude`.
- **Parameters:** none.
- **Passes when:** the value is a latitude as `v.latitude` reads strings, a
  comma, at most one space (the byte 0x20), and a longitude as `v.longitude`
  reads strings; the whole pair may be in parentheses. Exactly one comma; no
  other whitespace. The order is not checked beyond the ranges: a swapped pair
  passes when its first number is within -90 to 90.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.lat_long`.
- **Default message:** `must be a latitude,longitude pair`.
- **Placeholders:** none.
- **Predicate:** `v.isLatLong(s: []const u8) bool`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D26](class_validator.md#deviations-from-validatorjs) (exactly
  one comma; only a space may follow it).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: lat_long expects a string, field is f64; use two float fields with v.latitude and v.longitude
validator: <Type>.field_rules.<field>: lat_long expects a string, field is []const []const u8; use v.each(v.latLong)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.latLong` | `[]const u8` | `"40.7128,-74.0060"`, `"40.7128, -74.0060"` | passes |
| `v.latLong` | `[]const u8` | `"(40.7128,-74.0060)"` | passes |
| `v.latLong` | `[]const u8` | `"40.7128,\t-74.0060"`, `"40.7128,  -74.0060"` | `validation.lat_long`: one space at most |
| `v.latLong` | `[]const u8` | `"1,2,garbage"` | `validation.lat_long`: validator.js ignores what follows a second comma |
| `v.latLong` | `[]const u8` | `"40.7128,-74.0060)"` | `validation.lat_long`: unbalanced parenthesis |

## v.email

An email address.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the value is at most 254 bytes; before its first `@`, a local
  part of 1 to 64 bytes of letters, digits, `.` and ``!#$%&'*+-/=?^_`{|}~``,
  without a `.` at either end or two in a row; after it, a domain that
  `v.fqdn(.{})` accepts: at least two labels of letters, digits and hyphens, and
  a top-level domain of letters, or `xn` in any case followed by letters, digits
  or hyphens (`XN--P1AI`). No quoted local part, IP literal or non-ASCII byte;
  a second `@` fails in the domain.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.email`.
- **Default message:** `must be a valid email address`.
- **Placeholders:** none.
- **Predicate:** `v.isEmail(s: []const u8) bool`.
- **Complexity:** O(n), and nothing above 254 bytes is read; allocates nothing.
- **Deviations:** [D1](class_validator.md#deviations-from-validatorjs) (no quoted
  local part), [D2](class_validator.md#deviations-from-validatorjs) (ASCII only:
  a domain in another script arrives as `xn--` labels),
  [D4](class_validator.md#deviations-from-validatorjs) (invalid UTF-8 fails).

It checks the syntax only: whether mail can be delivered is a question for the
mail server.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: email expects a string, field is u64
validator: <Type>.field_rules.<field>: email expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: email expects a string, field is []const []const u8; use v.each(v.email)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.email` | `[]const u8` | `"user@example.com"`, `"first.last+tag@example.co.uk"` | passes |
| `v.email` | `[]const u8` | `"user@example.XN--P1AI"` | passes: an IDN top-level domain in any case |
| `v.email` | `[]const u8` | `"user@localhost"` | `validation.email`: the domain needs two labels |
| `v.email` | `[]const u8` | `"user@example.c"`, `"user@example.com1"` | `validation.email`: not a top-level domain |
| `v.email` | `[]const u8` | `"\"a b\"@example.com"` | `validation.email`: class-validator accepts a quoted local part |
| `v.email` | `[]const u8` | `"jösé@example.com"` | `validation.email`: ASCII only |
| `v.email.withMessage("enter an email address")` | `?[]const u8` | `"x"` | `validation.email` / `enter an email address` |

## v.httpUrl

An `http` or `https` URL.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the value starts with `http://` or `https://` in any case;
  then the authority, up to the first `/`, `?` or `#`: an IPv6 address in
  brackets, an IPv4 address or a host name, with an optional port; then the
  path, query and fragment.
  - A host name is labels of 1 to 63 letters, digits and hyphens (no hyphen at
    either end) joined by `.`, at most 253 bytes, with one optional trailing
    `.`; one label is enough (`localhost`). When its last label is a number
    (`1.2.3`, `0x7f`), the host must be an IPv4 address.
  - A port, when its `:` is present, is 1 to 5 digits from 1 to 65535; leading
    zeros are allowed (`:080`). No userinfo (`user@`).
  - The path, query and fragment are printable ASCII (0x21 to 0x7E) without
    `"`, `<`, `>` and `\`; `%` is followed by 2 hex digits; at most one `#`.
  - The length is not limited: combine the rule with a length rule.
  - `xn--` labels are not checked as Punycode, so a URL that passes may still
    be rejected by a WHATWG URL parser (`https://xn--a.example.com/`).
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.http_url`.
- **Default message:** `must be a valid HTTP or HTTPS URL`.
- **Placeholders:** none.
- **Predicate:** `v.isHttpUrl(s: []const u8) bool`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D6](class_validator.md#deviations-from-validatorjs) (the
  scheme is required), [D7](class_validator.md#deviations-from-validatorjs)
  (one-label hosts and a trailing dot pass),
  [D8](class_validator.md#deviations-from-validatorjs) (no userinfo, no empty
  port), [D9](class_validator.md#deviations-from-validatorjs) (ASCII only, no
  zone id, the characters of the tail),
  [D10](class_validator.md#deviations-from-validatorjs) (no length limit),
  [D59](class_validator.md#deviations-from-validatorjs) (the host is at most 253
  bytes).

It checks the syntax only and is no protection against server-side request
forgery: `http://127.0.0.1/` and `http://169.254.169.254/latest/meta-data/`
pass, and so does a typo such as `https://googlecom`. Decide where a URL may
point in your own code.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: http_url expects a string, field is bool
validator: <Type>.field_rules.<field>: http_url expects a string, field is []const []const u8; use v.each(v.httpUrl)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.httpUrl` | `[]const u8` | `"https://example.com/search?q=zig#top"` | passes |
| `v.httpUrl` | `[]const u8` | `"http://localhost:8080"`, `"http://[::1]:8443/"` | passes |
| `v.httpUrl` | `[]const u8` | `"https://api.example.com/articles?page[number]=2"` | passes: `[`, `]` and `\|` pass in the tail |
| `v.httpUrl` | `[]const u8` | `"example.com"`, `"ftp://example.com"` | `validation.http_url`: the scheme is http or https |
| `v.httpUrl` | `[]const u8` | `"https://user@example.com"` | `validation.http_url`: no userinfo |
| `v.httpUrl` | `[]const u8` | `"http://example.com:0/"`, `"http://example.com:"` | `validation.http_url`: the port is 1 to 65535 |
| `v.httpUrl` | `[]const u8` | `"http://example.com/%zz"`, `"http://example.com/a b"` | `validation.http_url` |
| `v.httpUrl` | `[]const u8` | `"https://münchen.de/"` | `validation.http_url`: use the `xn--` form of the name |

## v.fqdn(options)

A domain name. Written `v.fqdn(.{ ... })`.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** `options: v.FqdnOptions`, known at compile time, with the
  names and defaults of validator.js; every combination is valid:
  - `.require_tld: bool = true`: at least two labels, and a last label of 2 or
    more letters, or `xn` in any case followed by 2 or more letters, digits or
    hyphens;
  - `.allow_underscores: bool = false`: `_` may appear in labels
    (`_dmarc.example.com`);
  - `.allow_trailing_dot: bool = false`: one `.` may end the name
    (`example.com.`);
  - `.allow_wildcard: bool = false`: the name may start with `*.`
    (`*.example.com`).
- **Passes when:** without an allowed trailing dot, the name is 1 to 253 bytes;
  without an allowed `*.` prefix, it is labels of 1 to 63 letters, digits and
  hyphens (and `_` when allowed), without a hyphen at either end, joined by `.`;
  the last label is not all digits; and with `require_tld`, the top-level domain
  above. `xn--` labels are not checked as Punycode.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.fqdn`.
- **Default message:** `must be a valid domain name`, whatever the options.
- **Placeholders:** none.
- **Predicate:** `v.isFqdn(s: []const u8, options: v.FqdnOptions) bool`.
- **Complexity:** O(n), and nothing above 254 bytes is read; allocates nothing.
- **Deviations:** [D4](class_validator.md#deviations-from-validatorjs) (invalid
  UTF-8 fails), [D45](class_validator.md#deviations-from-validatorjs) (ASCII
  only, at most 253 bytes).

"ASCII only" is no protection against look-alike names: `xn--80ak6aa92e.com`,
which displays as a Cyrillic look-alike of `apple.com`, passes.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: fqdn expects a string, field is bool
validator: <Type>.field_rules.<field>: fqdn expects a string, field is []const []const u8; use v.each(v.fqdn(.{...}))
validator: <Type>.field_rules.<field>: fqdn must be called, e.g. v.fqdn(.{})
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.fqdn(.{})` | `[]const u8` | `"example.com"`, `"sub.example.co.uk"`, `"example.XN--P1AI"` | passes |
| `v.fqdn(.{})` | `[]const u8` | `"localhost"` | `validation.fqdn`: a top-level domain is required |
| `v.fqdn(.{ .require_tld = false })` | `[]const u8` | `"localhost"` | passes |
| `v.fqdn(.{})` | `[]const u8` | `"example.com."`, `"*.example.com"`, `"_dmarc.example.com"` | `validation.fqdn` |
| `v.fqdn(.{ .allow_trailing_dot = true })` | `[]const u8` | `"example.com."` | passes |
| `v.fqdn(.{ .allow_wildcard = true })` | `[]const u8` | `"*.example.com"` | passes |
| `v.fqdn(.{})` | `[]const u8` | `"-example.com"`, `"example..com"`, `"example.123"` | `validation.fqdn` |
| `v.fqdn(.{})` | `[]const u8` | `"münchen.de"` | `validation.fqdn`: use `xn--mnchen-3ya.de` |

## v.ip

An IPv4 or an IPv6 address.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** `v.ipv4` or `v.ipv6` passes the value; no string passes both.
  No zone id, brackets, prefix length or port.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.ip`.
- **Default message:** `must be a valid IP address`.
- **Placeholders:** none.
- **Predicate:** `v.isIp(s: []const u8) bool`.
- **Complexity:** O(1): at most 45 bytes are read; allocates nothing.
- **Deviations:** [D43](class_validator.md#deviations-from-validatorjs) (no zone
  id).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: ip expects a string, field is u32
validator: <Type>.field_rules.<field>: ip expects a string, field is []const []const u8; use v.each(v.ip)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.ip` | `[]const u8` | `"192.0.2.1"`, `"2001:db8::1"`, `"::ffff:192.0.2.1"` | passes |
| `v.ip` | `[]const u8` | `"fe80::1%eth0"` | `validation.ip`: no zone id |
| `v.ip` | `[]const u8` | `"192.0.2.1:80"`, `"[::1]"` | `validation.ip` |

## v.ipv4

An IPv4 address in dotted decimal.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the value is four numbers from 0 to 255 joined by `.`, each
  of 1 to 3 digits without a leading zero (`0` itself passes). No shorthand
  (`127.1`), single number, hex or octal parts, sign, prefix length, port or
  whitespace; `::ffff:192.0.2.1` is an IPv6 address.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.ipv4`.
- **Default message:** `must be a valid IPv4 address`.
- **Placeholders:** none.
- **Predicate:** `v.isIpv4(s: []const u8) bool`.
- **Complexity:** O(1): at most 15 bytes are read; allocates nothing.
- **Deviations:** none: validator.js `isIP(s, 4)`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: ipv4 expects a string, field is u32
validator: <Type>.field_rules.<field>: ipv4 expects a string, field is []const []const u8; use v.each(v.ipv4)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.ipv4` | `[]const u8` | `"192.0.2.1"`, `"0.0.0.0"`, `"255.255.255.255"` | passes |
| `v.ipv4` | `[]const u8` | `"256.0.0.1"`, `"1.2.3"` | `validation.ipv4` |
| `v.ipv4` | `[]const u8` | `"01.2.3.4"` | `validation.ipv4`: no leading zeros |
| `v.ipv4` | `[]const u8` | `"127.1"`, `"2130706433"`, `"1.2.3.4/24"` | `validation.ipv4` |

## v.ipv6

An IPv6 address.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the value is 8 groups of 1 to 4 hex digits in any case joined
  by `:`, or fewer groups around one `::`, which stands for one or more groups
  of zeros; the last two groups may be written as an IPv4 address
  (`::ffff:192.0.2.1`, `64:ff9b::192.0.2.1`). Leading zeros and uppercase pass:
  the canonical form of RFC 5952 is not required. No zone id, brackets or
  prefix length.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.ipv6`.
- **Default message:** `must be a valid IPv6 address`.
- **Placeholders:** none.
- **Predicate:** `v.isIpv6(s: []const u8) bool`.
- **Complexity:** O(1): at most 45 bytes are read; allocates nothing.
- **Deviations:** [D43](class_validator.md#deviations-from-validatorjs) (no zone
  id).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: ipv6 expects a string, field is u128
validator: <Type>.field_rules.<field>: ipv6 expects a string, field is []const []const u8; use v.each(v.ipv6)
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.ipv6` | `[]const u8` | `"2001:db8::1"`, `"::1"`, `"::"` | passes |
| `v.ipv6` | `[]const u8` | `"2001:DB8:0:0:0:0:0:0001"` | passes: leading zeros and uppercase |
| `v.ipv6` | `[]const u8` | `"::ffff:192.0.2.1"` | passes |
| `v.ipv6` | `[]const u8` | `"1::2::3"`, `"1:2:3:4:5:6:7:8:9"` | `validation.ipv6` |
| `v.ipv6` | `[]const u8` | `"fe80::1%eth0"`, `"[::1]"`, `"::1/128"` | `validation.ipv6` |

## v.macAddress(options)

A MAC address. Written `v.macAddress(.{ ... })`.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** `options: v.MacAddressOptions`, known at compile time; every
  combination is valid:
  - `.eui: Eui = .any`: `.any` for EUI-48 (6 octets) or EUI-64 (8 octets),
    `.eui48` or `.eui64` for one of them;
  - `.format: Format = .separated`: `.separated` for two-digit octets joined by
    `:`, `-` or a space, the same one throughout (`00:1A:2B:3C:4D:5E`), or groups
    of four digits joined by `.` (`001a.2b3c.4d5e`); `.bare` for hex digits only
    (`001A2B3C4D5E`).

  `Eui` and `Format` are `v.MacAddressOptions.Eui` and
  `v.MacAddressOptions.Format`.
- **Passes when:** the value is one of the sizes in the format of the options;
  letters in any case. Only the byte 0x20 is a space: a tab or a line feed is
  no separator. Separators do not mix, and every octet has two digits.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.mac_address`.
- **Default message:** chosen from the options:

  | Options | Message |
  | --- | --- |
  | `.{}` | `must be a valid MAC address` |
  | `.eui = .eui48` | `must be a valid 48-bit MAC address` |
  | `.eui = .eui64` | `must be a valid 64-bit MAC address` |
  | `.format = .bare` | `must be a MAC address of 12 or 16 hex digits without separators` |
  | `.eui = .eui48, .format = .bare` | `must be a MAC address of 12 hex digits without separators` |
  | `.eui = .eui64, .format = .bare` | `must be a MAC address of 16 hex digits without separators` |

- **Placeholders:** none.
- **Predicate:** `v.isMacAddress(s: []const u8, options: v.MacAddressOptions) bool`.
- **Complexity:** O(1): only values of 12, 14, 16, 17, 19 or 23 bytes are read;
  allocates nothing.
- **Deviations:** [D44](class_validator.md#deviations-from-validatorjs) (only
  0x20 is a space separator).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: mac_address expects a string, field is u64
validator: <Type>.field_rules.<field>: mac_address expects a string, field is []const []const u8; use v.each(v.macAddress(.{...}))
validator: <Type>.field_rules.<field>: macAddress must be called, e.g. v.macAddress(.{})
```

Examples:

| Rule | Field type | Value | Result |
| --- | --- | --- | --- |
| `v.macAddress(.{})` | `[]const u8` | `"00:1A:2B:3C:4D:5E"`, `"00-1a-2b-3c-4d-5e"`, `"001a.2b3c.4d5e"` | passes |
| `v.macAddress(.{})` | `[]const u8` | `"00:1a:2b:3c:4d:5e:6f:70"` | passes: EUI-64 |
| `v.macAddress(.{})` | `[]const u8` | `"00:1a-2b:3c:4d:5e"` | `validation.mac_address`: mixed separators |
| `v.macAddress(.{})` | `[]const u8` | `"001A2B3C4D5E"` | `validation.mac_address`: no separators needs `.format = .bare` |
| `v.macAddress(.{ .format = .bare })` | `[]const u8` | `"001A2B3C4D5E"` | passes |
| `v.macAddress(.{ .eui = .eui48 })` | `[]const u8` | `"00:1a:2b:3c:4d:5e:6f:70"` | `validation.mac_address`: `must be a valid 48-bit MAC address` |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
