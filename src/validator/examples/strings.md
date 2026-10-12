# Strings

Rules for string fields: `v.minLength`, `v.maxLength` and `v.length` count
characters (code points), `v.minBytes` and `v.maxBytes` count bytes, `v.utf8`
and `v.notBlank` check the text itself, seven ASCII classes and `v.multibyte`
check the bytes, three rules check the widths of validator.js, `v.contains` and
`v.notContains` look for a substring, and `v.strongPassword` checks a password.

```zig
const SignUp = struct {
    name: []const u8,
    login: []const u8,
    password: []const u8,
    pin: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .name = .{ v.notBlank, v.maxLength(64) },
        .login = .{ v.length(3, 32), v.alphanumeric, v.lowercase },
        .password = .{ v.maxLength(128), v.strongPassword(.{ .min_length = 12 }) },
        .pin = .{ v.length(4, 4), v.digits }, // null skips the rules
        .tags = v.each(.{ v.notEmpty, v.notContains(" ") }),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [Predicates](#predicates)
- [v.minLength(min)](#vminlengthmin)
- [v.maxLength(max)](#vmaxlengthmax)
- [v.length(min, max)](#vlengthmin-max)
- [v.minBytes(min)](#vminbytesmin)
- [v.maxBytes(max)](#vmaxbytesmax)
- [v.utf8](#vutf8)
- [v.notBlank](#vnotblank)
- [v.ascii](#vascii)
- [v.printableAscii](#vprintableascii)
- [v.alphanumeric](#valphanumeric)
- [v.alpha](#valpha)
- [v.digits](#vdigits)
- [v.lowercase](#vlowercase)
- [v.uppercase](#vuppercase)
- [v.multibyte](#vmultibyte)
- [v.fullWidth](#vfullwidth)
- [v.halfWidth](#vhalfwidth)
- [v.variableWidth](#vvariablewidth)
- [v.contains(seed)](#vcontainsseed)
- [v.notContains(seed)](#vnotcontainsseed)
- [v.strongPassword(options)](#vstrongpasswordoptions)

## Common to all rules on this page

- A string is a slice of `u8`: `[]const u8`, `[]u8`, `[:0]const u8` or `[:0]u8`,
  of any alignment. A slice with `volatile` or `allowzero` is not a string. Every
  rule also accepts `?T` and `??T` of a string: `null` skips the rule. `""` is a
  value like any other and is checked.
- `[N]u8` is an array of numbers, not a string: every rule of this page is a
  compile error on it, with the hint `use []const u8`. On a list of strings the
  hint is `use v.each(...)`.
- **Characters are code points.** `v.minLength`, `v.maxLength`, `v.length` and
  `v.strongPassword` count Unicode scalar values, and `character` in their
  messages means one: not a grapheme (`"e\u{301}"` is 2, a family emoji joined
  by ZWJ is 7) and not a UTF-16 unit (`"😀"` is 1). `v.minBytes` and
  `v.maxBytes` count bytes.
- **Two ways to read a string.** The rules that read code points —
  `v.minLength`, `v.maxLength`, `v.length`, `v.notBlank`, `v.fullWidth`,
  `v.halfWidth`, `v.variableWidth` and `v.strongPassword` — need valid UTF-8:
  invalid UTF-8 fails with the precondition `validation.utf8` /
  `must be valid UTF-8` before their own check, and `.withMessage` does not
  change that ([D13](class_validator.md#deviations-from-validatorjs);
  [Preconditions](README.md#preconditions)). To word that case, put
  `v.utf8.withMessage("...")` first in the tuple. The other rules read bytes,
  never decode, and have no precondition: a byte of invalid UTF-8 is a byte.
- **No transformations.** The rules only read the value: no trimming, no case
  folding and no Unicode normalization.
- **`""`** passes the character classes (`v.utf8`, `v.ascii`, `v.printableAscii`,
  `v.alphanumeric`, `v.alpha`, `v.digits`, `v.lowercase`, `v.uppercase`),
  `v.notContains`, `v.maxLength` and `v.maxBytes`, and fails the others. To
  require content, put `v.notEmpty` (or `v.notBlank`) first:
  `.{ v.notEmpty, v.digits }`
  ([D11](class_validator.md#deviations-from-validatorjs)).
- Rules of a tuple run left to right, and the first that fails is the value's
  only violation, so a cheap `v.maxBytes(n)` put first rejects a long value
  before rules that read the whole string.
- The rules take O(n) time in the length of the value (`v.minBytes` and
  `v.maxBytes` O(1)), never backtrack, and allocate nothing.

## Predicates

Every rule of this page without a parameter, and `v.strongPassword`, has a
predicate for code outside `field_rules` (`validateSelf`, a service, a test):
`v.isX(s)` is `true` exactly when the rule passes `s`, and it is `false` on
invalid UTF-8 where the rule reports the precondition. A predicate never panics
or allocates.

```zig
pub fn isUtf8(s: []const u8) bool
pub fn isNotBlank(s: []const u8) bool
pub fn isAscii(s: []const u8) bool
pub fn isPrintableAscii(s: []const u8) bool
pub fn isAlphanumeric(s: []const u8) bool
pub fn isAlpha(s: []const u8) bool
pub fn isDigits(s: []const u8) bool
pub fn isLowercase(s: []const u8) bool
pub fn isUppercase(s: []const u8) bool
pub fn isMultibyte(s: []const u8) bool
pub fn isFullWidth(s: []const u8) bool
pub fn isHalfWidth(s: []const u8) bool
pub fn isVariableWidth(s: []const u8) bool
pub fn isStrongPassword(s: []const u8, options: v.StrongPasswordOptions) bool
```

The rules with a count or a substring (`v.minLength`, `v.maxLength`,
`v.length`, `v.minBytes`, `v.maxBytes`, `v.contains`, `v.notContains`) have no
predicate. A predicate written where a rule belongs is a compile error that
names the rule:

```text
validator: <Type>.field_rules.<field>: expected a rule, got the predicate isAlpha; use the rule v.alpha
```

## v.minLength(min)

A string has at least `min` characters (code points).

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `min`, a `usize` known at compile time, at least 1.
- **Passes when:** the number of code points is at least `min`.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first even when the number of bytes
  alone would decide: `"\xff"` fails `v.minLength(3)` with `validation.utf8`.
- **Code:** `validation.min_length`.
- **Default message:** `must be at least {min} characters`; for `min` 1
  `must be at least 1 character`.
- **Placeholders:** `{min}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(n), one pass that validates and counts; allocates nothing.
- **Deviations:** [D12](class_validator.md#deviations-from-validatorjs), [D13](class_validator.md#deviations-from-validatorjs), [D61](class_validator.md#deviations-from-validatorjs).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: minLength(0): min must be at least 1 (minLength(0) is always true; use v.utf8 to require valid UTF-8)
validator: <Type>.field_rules.<field>: min_length expects a string, field is u32
validator: <Type>.field_rules.<field>: min_length expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: min_length expects a string, field is []const []const u8; use v.each(v.minLength(3))
validator: <Type>.field_rules.<field>: min_length expects a string, field is []const u32; for the number of items use v.minItems(3)
validator: <Type>.field_rules.<field>: minLength must be called, e.g. v.minLength(1)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.minLength(3)` | `"ab"` | `validation.min_length`: `must be at least 3 characters` |
| `v.minLength(3)` | `"abc"` | passes |
| `v.minLength(2)` | `"é"` (U+00E9) | `validation.min_length`: one code point |
| `v.minLength(2)` | `"e\u{301}"` | passes: `e` and a combining accent are 2 |
| `v.minLength(1)` | `""` | `validation.min_length`: `must be at least 1 character` |
| `v.minLength(1)` | `"\xff"` | `validation.utf8`: `must be valid UTF-8` |

## v.maxLength(max)

A string has at most `max` characters (code points).

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `max`, a `usize` known at compile time, at least 1. For no
  characters use `v.empty`.
- **Passes when:** the number of code points is at most `max`.
- **`""`:** passes.
- **Precondition:** valid UTF-8, checked first: `"\xff"` fails
  `v.maxLength(100)` with `validation.utf8`.
- **Code:** `validation.max_length`.
- **Default message:** `must be at most {max} characters`; for `max` 1
  `must be at most 1 character`.
- **Placeholders:** `{max}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(n), one pass; allocates nothing.
- **Deviations:** [D12](class_validator.md#deviations-from-validatorjs), [D13](class_validator.md#deviations-from-validatorjs), [D61](class_validator.md#deviations-from-validatorjs).

Compile errors:

```text
validator: maxLength(0): max must be at least 1; use v.empty
validator: <Type>.field_rules.<field>: max_length expects a string, field is []const u32; for the number of items use v.maxItems(64)
validator: <Type>.field_rules.<field>: maxLength must be called, e.g. v.maxLength(100)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.maxLength(2)` | `"abc"` | `validation.max_length`: `must be at most 2 characters` |
| `v.maxLength(1)` | `"😀"` | passes: one code point, four bytes |
| `v.maxLength(1)` | `"❤\u{FE0F}"` | `validation.max_length`: a variation selector counts |
| `v.maxLength(64)` | `""` | passes |
| `v.maxLength(64).withMessage("at most {max} characters, please")` | 65 × `я` | `validation.max_length` / `at most 64 characters, please` |

## v.length(min, max)

A string has from `min` to `max` characters (code points).

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `min` and `max`, `usize` known at compile time,
  `1 <= min <= max`. Equal bounds ask for an exact length. For no lower bound
  use `v.maxLength(max)`.
- **Passes when:** `min <= count <= max`, `count` the number of code points.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first.
- **Code:** `validation.length`.
- **Default message:** `must be from {min} to {max} characters`; when
  `min = max`, `must be exactly {min} characters`; for `min = max = 1`,
  `must be exactly 1 character`.
- **Placeholders:** `{min}` and `{max}`: the counts, in decimal.
- **Predicate:** none.
- **Complexity:** O(n), one pass; allocates nothing.
- **Deviations:** [D12](class_validator.md#deviations-from-validatorjs), [D13](class_validator.md#deviations-from-validatorjs), [D61](class_validator.md#deviations-from-validatorjs).

Compile errors:

```text
validator: length(0, 5): min must be at least 1; use v.maxLength(5)
validator: length(0, 0): min must be at least 1; use v.empty
validator: length(5, 3): min is greater than max
validator: <Type>.field_rules.<field>: length expects a string, field is []const u32; for the number of items use v.minItems(3) and v.maxItems(32)
validator: <Type>.field_rules.<field>: length must be called, e.g. v.length(1, 100)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.length(3, 32)` | `"ab"` | `validation.length`: `must be from 3 to 32 characters` |
| `v.length(3, 32)` | `"Zefir"` | passes |
| `v.length(4, 4)` | `"123"` | `validation.length`: `must be exactly 4 characters` |
| `v.length(1, 5)` | `"abc\xe6\x97"` | `validation.utf8`: a truncated sequence |

## v.minBytes(min)

A string has at least `min` bytes.

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `min`, a `usize` known at compile time, at least 1.
- **Passes when:** `value.len >= min`: the bytes as stored and sent, without
  decoding, so an invalid byte counts as one.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.min_bytes`.
- **Default message:** `must be at least {min} bytes`; for `min` 1
  `must be at least 1 byte`.
- **Placeholders:** `{min}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D23](class_validator.md#deviations-from-validatorjs), [D61](class_validator.md#deviations-from-validatorjs).

[v.notEmpty](common.md#vnotempty) is the same check as `v.minBytes(1)` with its
own code.

Compile errors:

```text
validator: minBytes(0): min must be at least 1 (minBytes(0) is always true; remove it)
validator: <Type>.field_rules.<field>: min_bytes expects a string, field is u32
validator: <Type>.field_rules.<field>: minBytes must be called, e.g. v.minBytes(1)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.minBytes(8)` | `"abc"` | `validation.min_bytes`: `must be at least 8 bytes` |
| `v.minBytes(2)` | `"é"` (2 bytes) | passes |
| `v.minBytes(2)` | `"\xff"` | `validation.min_bytes`: one byte, never decoded |
| `v.minBytes(3)` | `"\xed\xa0\x80"` | passes: 3 bytes, though not valid UTF-8 |

## v.maxBytes(max)

A string has at most `max` bytes.

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `max`, a `usize` known at compile time, at least 1. For no
  bytes use `v.empty`.
- **Passes when:** `value.len <= max`, without decoding.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.max_bytes`.
- **Default message:** `must be at most {max} bytes`; for `max` 1
  `must be at most 1 byte`.
- **Placeholders:** `{max}`: the count, in decimal.
- **Predicate:** none.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** [D23](class_validator.md#deviations-from-validatorjs), [D61](class_validator.md#deviations-from-validatorjs).

Put first in a tuple, it caps the work of the rules after it:
`.{ v.maxBytes(1024), v.maxLength(256) }`. The byte length of class-validator,
`IsByteLength(min, max)`, is `.{ v.minBytes(min), v.maxBytes(max) }`.

Compile errors:

```text
validator: maxBytes(0): max must be at least 1; use v.empty
validator: <Type>.field_rules.<field>: max_bytes expects a string, field is []const []const u8; use v.each(v.maxBytes(255))
validator: <Type>.field_rules.<field>: maxBytes must be called, e.g. v.maxBytes(100)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.maxBytes(8)` | `"日本語"` (9 bytes) | `validation.max_bytes`: `must be at most 8 bytes` |
| `v.maxBytes(9)` | `"日本語"` | passes |
| `v.maxBytes(3)` | `"\xff\xff\xff"` | passes: bytes are not decoded |
| `.{ v.maxBytes(2), v.minLength(1) }` | `"\xff\xff\xff"` | `validation.max_bytes`: the first rule fails first |

## v.utf8

A string is valid UTF-8.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** `std.unicode.utf8ValidateSlice(value)`: well-formed UTF-8
  (RFC 3629). The bytes C0, C1 and F5-FF, a continuation byte without a lead,
  a truncated sequence, an overlong form, a surrogate (`ED A0-BF ..`) and a code
  point above U+10FFFF fail; NUL, U+FEFF, U+FFFE and U+FFFF pass.
- **`""`:** passes.
- **Precondition:** none: this is the rule whose code the precondition shares.
  Its failure is its own check, so `.withMessage` applies, and put first in a
  tuple it words invalid UTF-8 for the rules after it:
  `.{ v.utf8.withMessage("the name must be UTF-8"), v.maxLength(64) }`.
- **Code:** `validation.utf8`.
- **Default message:** `must be valid UTF-8`.
- **Placeholders:** none.
- **Predicate:** `v.isUtf8(s)`.
- **Complexity:** O(n), one pass; allocates nothing.
- **Deviations:** none.

A string that `std.json` decoded is always valid UTF-8: the decoder rejects
invalid bytes and lone surrogates.

Compile errors:

```text
validator: <Type>.field_rules.<field>: utf8 expects a string, field is u32
validator: <Type>.field_rules.<field>: utf8 expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: utf8 expects a string, field is []const []const u8; use v.each(v.utf8)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.utf8` | `"Zefir 🌬"` | passes |
| `v.utf8` | `"\xc0\xaf"` | `validation.utf8`: an overlong `/` |
| `v.utf8` | `"\xed\xa0\x80"` | `validation.utf8`: a surrogate |
| `v.utf8.withMessage("bad text")` | `"\xff"` | `validation.utf8` / `bad text` |

## v.notBlank

A string has at least one code point outside Unicode White_Space.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** some code point is not one of the 25 of White_Space: TAB, LF,
  VT, FF, CR, space, U+0085, U+00A0, U+1680, U+2000-200A, U+2028, U+2029,
  U+202F, U+205F and U+3000. Format characters and fillers are content and pass:
  U+200B, U+FEFF, U+2060, U+180E, U+00AD, U+3164, U+2800.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked on the whole value before the search:
  `"a\xff"` fails with `validation.utf8`.
- **Code:** `validation.not_blank`.
- **Default message:** `must not be blank`.
- **Placeholders:** none.
- **Predicate:** `v.isNotBlank(s)`: `false` on invalid UTF-8, on `""` and on
  White_Space alone.
- **Complexity:** O(n): a validation pass and a search that stops at the first
  content; allocates nothing.
- **Deviations:** [D13](class_validator.md#deviations-from-validatorjs).

[v.notEmpty](common.md#vnotempty) counts bytes, so `" "` passes it; for text a
user must fill in, use `v.notBlank`.

Compile errors:

```text
validator: <Type>.field_rules.<field>: not_blank expects a string, field is u32
validator: <Type>.field_rules.<field>: not_blank expects a string, field is []const []const u8; use v.each(v.notBlank)
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.notBlank` | `" \t\n"` | `validation.not_blank`: `must not be blank` |
| `v.notBlank` | `"\u{3000}"` | `validation.not_blank`: the ideographic space |
| `v.notBlank` | `" a "` | passes |
| `v.notBlank` | `"\u{200B}"` | passes: a zero-width space is not White_Space |
| `v.notBlank` | `""` | `validation.not_blank` |

## v.ascii

Every byte of a string is ASCII (0x00-0x7F).

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** every byte is at most 0x7F; control bytes, NUL and DEL pass. A
  byte of 0x80 or more fails, valid UTF-8 or not.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.ascii`.
- **Default message:** `must contain only ASCII characters`.
- **Placeholders:** none.
- **Predicate:** `v.isAscii(s)`.
- **Complexity:** O(n) bytes, stops at the first byte outside; allocates nothing.
- **Deviations:** [D11](class_validator.md#deviations-from-validatorjs).

Examples: `"abc\x00"` passes; `"café"` fails with `validation.ascii`.

## v.printableAscii

Every byte of a string is printable ASCII (0x20-0x7E).

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** every byte is from 0x20 (space) to 0x7E (`~`). TAB, LF, CR,
  other control bytes, DEL and every byte of 0x80 or more fail.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.printable_ascii`.
- **Default message:** `must contain only printable ASCII characters`.
- **Placeholders:** none.
- **Predicate:** `v.isPrintableAscii(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** none (a zefir rule).

Examples: `"a b~"` passes; `"a\tb"` fails with `validation.printable_ascii`.

## v.alphanumeric

Every byte of a string is an ASCII letter or digit.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** every byte is `0-9`, `A-Z` or `a-z` (en-US only). `_`, `-`, a
  space, and letters or digits outside ASCII (`á`, `１２３`, `٣`) fail.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.alphanumeric`.
- **Default message:** `must contain only ASCII letters and digits`.
- **Placeholders:** none.
- **Predicate:** `v.isAlphanumeric(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** [D11](class_validator.md#deviations-from-validatorjs).

Examples: `"user42"` passes; `"user_42"` fails with `validation.alphanumeric`.

## v.alpha

Every byte of a string is an ASCII letter.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** every byte is `A-Z` or `a-z` (en-US only, no locales). Digits,
  a space, `-`, `_` and letters outside ASCII fail.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.alpha`.
- **Default message:** `must contain only ASCII letters`.
- **Placeholders:** none.
- **Predicate:** `v.isAlpha(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** [D11](class_validator.md#deviations-from-validatorjs).

Examples: `"Zefir"` passes; `"Zefir1"` and `"Émile"` fail with
`validation.alpha`.

## v.digits

Every byte of a string is an ASCII digit.

- **Field types:** a string; `?T` and `??T` of it. On an integer or float field
  it is a compile error: the field is already a number.
- **Passes when:** every byte is `0-9`: no sign, point, exponent, space, group
  separator, or digits outside ASCII (`１`, `٣`). It checks the form, not a
  number: leading zeros stay, and the size is not bounded (bound the length with
  `v.length`), so it fits codes and PINs.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.digits`.
- **Default message:** `must contain only ASCII digits`.
- **Placeholders:** none.
- **Predicate:** `v.isDigits(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** [D11](class_validator.md#deviations-from-validatorjs).

Compile errors:

```text
validator: <Type>.field_rules.<field>: digits expects a string, field is u32; the field is already a number: use v.min, v.max or v.range
validator: <Type>.field_rules.<field>: digits expects a string, field is bool
```

Examples: `"000123"` passes; `"-1"`, `"1.5"` and `"1 000"` fail with
`validation.digits`; `.{ v.length(4, 4), v.digits }` is a four-digit PIN.

## v.lowercase

A string has no uppercase ASCII letter.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** no byte is `A-Z`. Only ASCII letters are inspected: the
  standard library has no case tables, so `"Émile"` and `"ПРИВЕТ"` pass. Digits,
  punctuation and other bytes pass.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.lowercase`.
- **Default message:** `must be lowercase`.
- **Placeholders:** none.
- **Predicate:** `v.isLowercase(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** [D30](class_validator.md#deviations-from-validatorjs).

Examples: `"user-42"` passes; `"User"` fails with `validation.lowercase`.

## v.uppercase

A string has no lowercase ASCII letter.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** no byte is `a-z`; only ASCII letters are inspected, so
  `"STRAßE"` passes.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.uppercase`.
- **Default message:** `must be uppercase`.
- **Placeholders:** none.
- **Predicate:** `v.isUppercase(s)`.
- **Complexity:** O(n) bytes, with an early exit; allocates nothing.
- **Deviations:** [D30](class_validator.md#deviations-from-validatorjs).

Examples: `"EUR-42"` passes; `"Eur"` fails with `validation.uppercase`.

## v.multibyte

A string has at least one byte outside ASCII.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** some byte is 0x80 or more. It does not decode, so invalid
  UTF-8 passes; on every input it is the opposite of `v.ascii`.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.multibyte`.
- **Default message:** `must contain at least one non-ASCII character`.
- **Placeholders:** none.
- **Predicate:** `v.isMultibyte(s)`.
- **Complexity:** O(n) bytes, stops at the first byte of 0x80 or more; allocates
  nothing.
- **Deviations:** none.

Examples: `"café"` passes; `"cafe"` fails with `validation.multibyte`.

## v.fullWidth

A string has a character outside the half-width class of validator.js.

The three width rules keep the character classes of validator.js for parity;
they are not Unicode East Asian Width. "Half-width" is the class H: printable
ASCII U+0020-007E and the half-width forms U+FF61-FFDC and U+FFE8-FFEE (226
code points). "Full-width" is every other code point, so control characters,
Latin-1 (`é`), Cyrillic and emoji count as full-width: `"привет"` and `"café"`
pass `v.fullWidth`, and `"abc\n"` passes `v.variableWidth`.

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** some code point is outside H.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first.
- **Code:** `validation.full_width`.
- **Default message:** `must contain at least one full-width character`.
- **Placeholders:** none.
- **Predicate:** `v.isFullWidth(s)`.
- **Complexity:** O(n): a validation pass and a search that stops when the
  answer is known; allocates nothing.
- **Deviations:** [D13](class_validator.md#deviations-from-validatorjs).

Examples: `"ひらがな"` passes; `"ｱｲｳ"` (half-width katakana) fails with
`validation.full_width`; `"\xff"` fails with `validation.utf8`.

## v.halfWidth

A string has a character in the half-width class of validator.js (see
[v.fullWidth](#vfullwidth)).

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** some code point is in H.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first.
- **Code:** `validation.half_width`.
- **Default message:** `must contain at least one half-width character`.
- **Placeholders:** none.
- **Predicate:** `v.isHalfWidth(s)`.
- **Complexity:** as `v.fullWidth`.
- **Deviations:** [D13](class_validator.md#deviations-from-validatorjs).

Examples: `"ｱｲｳ"` and `"abc"` pass; `"ひらがな"` fails with
`validation.half_width`.

## v.variableWidth

A string has characters both in and outside the half-width class of validator.js
(see [v.fullWidth](#vfullwidth)).

- **Field types:** a string; `?T` and `??T` of it.
- **Passes when:** some code point is in H and some is outside it; one code
  point is never both.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first.
- **Code:** `validation.variable_width`.
- **Default message:** `must contain both full-width and half-width characters`.
- **Placeholders:** none.
- **Predicate:** `v.isVariableWidth(s)`.
- **Complexity:** as `v.fullWidth`.
- **Deviations:** [D13](class_validator.md#deviations-from-validatorjs).

Examples: `"ひらがなabc"`, `"ｱア"` and `"café"` pass; `"abc"` and `"\t\n"` fail
with `validation.variable_width`.

## v.contains(seed)

A string contains `seed`.

- **Field types:** a string; `?T` and `??T` of it. On a list of strings the
  compile error offers `v.each(v.contains(...))` to search inside each item or
  `v.containsAll(.{ ... })` to require whole items.
- **Parameters:** `seed`, a `[]const u8` known at compile time: at least one
  byte, valid UTF-8, of any length.
- **Passes when:** `seed` occurs in the value as a contiguous run of bytes:
  case-sensitive, without decoding, case folding or Unicode normalization (`ï`
  U+00EF is not `i` and U+0308, `Ａ` is not `A`). For valid UTF-8 this is the
  same as comparing code points.
- **`""`:** fails.
- **Precondition:** none: invalid UTF-8 in the value is not checked.
- **Code:** `validation.contains`.
- **Default message:** `must contain "{seed}"`, the seed escaped as in Zig
  source (`\n`, `\"`, `\xff`); `must contain the required text` when that would
  be longer than 512 bytes ([Fallback messages](README.md#fallback-messages)).
- **Placeholders:** `{seed}`: the escaped seed, without the quotes.
- **Predicate:** none.
- **Complexity:** O(n) whatever the length of the seed: a linear scan whose
  table the compiler builds (the seed's bytes and one small integer per byte);
  allocates nothing.
- **Deviations:** [D29](class_validator.md#deviations-from-validatorjs).

Searching without case and counting occurrences are not in v1.

Compile errors:

```text
validator: contains(""): an empty seed is vacuous: every string contains ""
validator: contains("\xff"): the seed must be valid UTF-8
validator: <Type>.field_rules.<field>: contains expects a string, field is []const []const u8; use v.each(v.contains("@")) to search inside each item, or v.containsAll(.{ ... }) to require whole items
validator: <Type>.field_rules.<field>: contains expects a string, field is []const u32; use v.containsAll(.{ ... }) to require list items
validator: <Type>.field_rules.<field>: contains must be called, e.g. v.contains("@")
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.contains("@")` | `"ann@example.com"` | passes |
| `v.contains("@")` | `"ann"` | `validation.contains`: `must contain "@"` |
| `v.contains("Hello")` | `"hello"` | `validation.contains`: case-sensitive |
| `v.contains("\n")` | `"one line"` | `validation.contains`: `must contain "\n"` |
| `v.contains("\u{FFFD}")` | `"a\xffb"` | `validation.contains`: bytes are compared, nothing is decoded |

## v.notContains(seed)

A string does not contain `seed`.

- **Field types:** a string; `?T` and `??T` of it. On a list of strings the
  compile error offers `v.each(v.notContains(...))` or
  `v.containsNone(.{ ... })`.
- **Parameters:** `seed`, as for `v.contains`.
- **Passes when:** `seed` does not occur in the value as a contiguous run of
  bytes; the comparison is that of `v.contains`. An overlong encoding is not the
  character it would decode to: `"x\xc0\xafy"` passes `v.notContains("/")`. When
  a lenient decoder reads the value later, put `v.utf8` first:
  `.{ v.utf8, v.notContains("/") }`.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.not_contains`.
- **Default message:** `must not contain "{seed}"`;
  `must not contain the forbidden text` when that would be longer than 512 bytes.
- **Placeholders:** `{seed}`: the escaped seed, without the quotes.
- **Predicate:** none.
- **Complexity:** as `v.contains`.
- **Deviations:** [D29](class_validator.md#deviations-from-validatorjs).

Compile errors:

```text
validator: notContains(""): an empty seed is unsatisfiable: every string contains ""
validator: notContains("\xc0\xaf"): the seed must be valid UTF-8
validator: <Type>.field_rules.<field>: not_contains expects a string, field is []const Role; use v.containsNone(.{ ... }) to forbid list items
validator: <Type>.field_rules.<field>: notContains must be called, e.g. v.notContains(" ")
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.notContains(" ")` | `"a b"` | `validation.not_contains`: `must not contain " "` |
| `v.notContains(" ")` | `""` | passes |
| `v.notContains("\n").withMessage("one line, no {seed}")` | `"a\nb"` | `validation.not_contains` / `one line, no \n` |

## v.strongPassword(options)

A password is long enough and mixes the classes of characters that `options`
asks for.

```zig
pub const StrongPasswordOptions = struct {
    min_length: usize = 8,
    min_lowercase: usize = 1,
    min_uppercase: usize = 1,
    min_numbers: usize = 1,
    min_symbols: usize = 1,
};
```

- **Field types:** a string; `?T` and `??T` of it.
- **Parameters:** `options`, a `v.StrongPasswordOptions` literal known at compile
  time: `.{}` takes the defaults of validator.js, and fields left out keep
  theirs. Not every minimum may be 0, and `min_length` is at least the sum of the
  four class minima.
- **Passes when:** the value has at least `min_length` code points, at least
  `min_lowercase` letters `a-z`, `min_uppercase` letters `A-Z`, `min_numbers`
  digits `0-9` and `min_symbols` symbols. A symbol is a space, one of the 32
  ASCII punctuation characters ``!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`` or `£` (34
  in all, the set of validator.js). Occurrences count, not distinct characters;
  any other code point (TAB, NBSP, `€`, `é`, an emoji) counts toward the length
  only. There is no score mode.
- **`""`:** fails.
- **Precondition:** valid UTF-8, checked first.
- **Code:** `validation.strong_password`.
- **Default message:**
  `must be at least {min_length} characters and contain at least {min_lowercase} lowercase letters, {min_uppercase} uppercase letters, {min_numbers} digits and {min_symbols} symbols`,
  built at compile time: a class
  whose minimum is 0 is left out (with all four 0 the message ends after
  `characters`), the parts are joined by `, ` with ` and ` before the last, and a
  noun is singular for 1. With `.{}`:
  `must be at least 8 characters and contain at least 1 lowercase letter, 1 uppercase letter, 1 digit and 1 symbol`.
- **Placeholders:** `{min_length}`, `{min_lowercase}`, `{min_uppercase}`,
  `{min_numbers}` and `{min_symbols}`, in decimal; all five are there also when
  0.
- **Predicate:** `v.isStrongPassword(s, options)`: the options may be run-time
  values and are applied as they are, so with every minimum 0 any valid UTF-8
  string passes, `""` included; `false` on invalid UTF-8.
- **Complexity:** O(n): a validation pass and a counting pass; allocates
  nothing.
- **Deviations:** [D13](class_validator.md#deviations-from-validatorjs), [D31](class_validator.md#deviations-from-validatorjs).

NIST SP 800-63B counts every code point as a character of a password and
advises against required mixes of classes. For a length rule only, use
`v.minLength(n)` or zero class minima:
`v.strongPassword(.{ .min_length = 12, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 })`
says `must be at least 12 characters`.

Compile errors:

```text
validator: strongPassword(.{...}): every minimum is 0, so every string passes; set at least one minimum
validator: strongPassword(.{...}): min_length = 3 is less than the 4 characters the other minima already require; set min_length to at least 4
validator: <Type>.field_rules.<field>: strong_password expects a string, field is []const []const u8; use v.each(v.strongPassword(.{...}))
validator: <Type>.field_rules.<field>: strongPassword must be called, e.g. v.strongPassword(.{})
```

An option the struct does not have, such as validator.js's `minLength`, is Zig's
own error: `no field named 'minLength' in struct 'strings.StrongPasswordOptions'`.

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.strongPassword(.{})` | `"Abcdef1!"` | passes |
| `v.strongPassword(.{})` | `"abcdefgh"` | `validation.strong_password`: the default message |
| `v.strongPassword(.{})` | `"Ab1!😀😀"` | `validation.strong_password`: 6 code points |
| `v.strongPassword(.{})` | `"Abcdef1£"` | passes: `£` is a symbol |
| `v.strongPassword(.{ .min_uppercase = 2 })` | `"AAbcde1!"` | passes: occurrences count |
| `v.strongPassword(.{ .min_length = 4, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 4, .min_symbols = 0 })` | `"123a"` | `must be at least 4 characters and contain at least 4 digits` |
| `v.strongPassword(.{})` | `"Ab1!\xff\xff\xff\xff"` | `validation.utf8` |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
