# Coming from class-validator

For developers who know class-validator 0.15.1 and NestJS: how its ideas and
decorators map to zefir-validator, and where zefir deliberately behaves
differently from class-validator and validator.js 13.15.35.

## Contents

- [Concepts](#concepts)
- [Decorators](#decorators)
- [Deviations from validator.js](#deviations-from-validatorjs)

## Concepts

| class-validator | zefir |
| --- | --- |
| a property decorator | an entry in `field_rules`: `.name = v.notEmpty` |
| several decorators on a property | a tuple: `.{ v.positive, v.custom(...) }`, run left to right; the first failure is the property's only violation (D64) |
| `@ValidateNested()` and `@Type()` | not needed: struct, slice, array and optional fields are walked automatically |
| `@IsOptional()` | `?T`: `null` skips the field's rules |
| `@IsDefined()` | a non-optional field type |
| `@ValidateIf()` | `validateSelf` |
| `{ each: true }` | `v.each(rule)` or `v.each(.{ rules })`, last in the tuple; slices and arrays only; `null` items are skipped (D63) |
| `{ message: "…" }` | `.withMessage("…")` with placeholders `{name}`, as in `v.range(18, 120).withMessage("age must be from {min} to {max}")`; no message functions and no `$value`, `$property`, `$target` or `$constraintN` ([Messages](README.md#messages)) |
| `@Validate()` with a constraint class | `v.custom(code, message, f)` for one field, `validateSelf` with `v.fail` across fields |
| `validate(object)` | `v.check(&value, &path_buf)` for the first violation, `v.checkAll(gpa, &value)` for all of them |
| `stopAtFirstError` | `v.check` stops at the first violation; `v.checkAll` reports at most one violation per value and at most 100 in all |
| `skipMissingProperties`, `skipNullProperties`, `skipUndefinedProperties` | not needed: presence is the field type, and `null` in a `?T` skips the field's rules |
| `whitelist`, `forbidNonWhitelisted`, `forbidUnknownValues` | options of the decoder (`ignore_unknown_fields` in `std.json`) |
| `ValidationError` | `v.Violation`: `code`, `message` and `field`, the path of the value |
| `ValidationError.target`, `.value` | none: a violation never contains the value or the object, as long as a hand-built `validateSelf` result has static `code` and `message` strings (`v.fail` guarantees them) |
| the keys of `ValidationError.constraints` (`isNotEmpty`) | `Violation.code` (`validation.not_empty`); the message has no property name, the path is in `field` |
| groups, `always`, `context` | not in v1 |

## Decorators

Status: **v1** — a zefir rule; **not needed** — the field type, the decoder or
the walk already does it; **out** — outside the library: write `v.custom`, or
use a Zig enum or `v.oneOf`, with your own data.

| Decorator | zefir | Status | Notes |
| --- | --- | --- | --- |
| `@ArrayMaxSize` | `v.maxItems(max)` | v1 | Slices only (a fixed-length array `[N]T` is a compile error). `max` is at least 1: `ArrayMaxSize(0)` becomes `v.empty`. `null` items count. Deviations D61, D62. |
| `@ArrayMinSize` | `v.minItems(min)` | v1 | Slices only. `min` is at least 1 (`ArrayMinSize(0)` is always true: a compile error). `null` items count. Deviations D61, D62. |
| `@ArrayNotEmpty` | `v.notEmpty` | v1 | One rule for strings and lists; a fixed-length array `[N]T` is a compile error. A `null` `?[]T` skips the rule. Deviation D14. |
| `@Allow` | unknown fields are an option of the decoder | not needed | `@Allow` only matters with `whitelist` or `forbidNonWhitelisted`. In Zig the decoder decides what an unknown JSON field does (`ignore_unknown_fields` in `std.json.ParseOptions`). |
| `@Equals` | `v.equals(expected)` | v1 | Integer, float, `bool`, enum or string fields; strings compare bytes. `v.equals("")` is a compile error (use `v.empty`). Exact at every integer width. Deviations D16, D20. |
| `@IsDefined` | a non-optional field type | not needed | Presence is the job of the field type: the decoder rejects a missing non-optional field. There is no `required` rule. |
| `@IsEmpty` | `v.empty` | v1 | Strings and slices with `len == 0`; a fixed-length array `[N]T` is a compile error. class-validator also accepts `null` and `undefined`: in zefir a `null` `?T` skips every rule. Deviations D21, D62. |
| `@IsIn` | `v.oneOf(.{ ... })` | v1 | Strings, enum tags or integers. An empty, duplicate, mixed or invalid-UTF-8 list is a compile error; listing every enum tag is allowed. Deviations D15, D58. |
| `@IsNotEmpty` | `v.notEmpty` | v1 | Strings (bytes; a string of spaces passes, so use `v.notBlank` for text) and lists. On other field types presence is the type itself. Deviation D14. |
| `@IsNotIn` | `v.noneOf(.{ ... })` | v1 | As `v.oneOf`, integers included. `""` cannot be listed (use `v.notEmpty`); excluding every tag of an exhaustive enum is a compile error. Deviations D15, D58. |
| `@IsOptional` | `?T` | not needed | A `null` optional skips its rules, `v.each` and nested validation. |
| `@NotEquals` | `v.notEquals(forbidden)` | v1 | `v.notEquals("")` is a compile error (use `v.notEmpty`). On floats NaN and infinities fail with `validation.finite`. Deviations D16, D20. |
| `@Validate` | `v.custom(code, message, f)` or `validateSelf` | not needed | A constraint class becomes `v.custom(code, message, f)` for one field, or `validateSelf` with `v.fail` for checks across fields. No async constraints, no constraint arguments, no context. |
| `@ValidatorConstraint` | `v.custom(code, message, f)` | not needed | Exported together with `@Validate`. In zefir the function passed to `v.custom` is the constraint; there is no registry. |
| `@ValidateBy` | `v.custom(code, message, f)` | not needed | `ValidateBy({ name, validator })` is `v.custom`; the name becomes a code (segments `[a-z][a-z0-9_]*`, not `validation.` or `rpc.`). |
| `@ValidateIf` | `validateSelf` | not needed | Conditional rules are not in v1: write the condition in `validateSelf`. |
| `@ValidateNested` | nested structs are walked automatically | not needed | Every struct, optional, slice and array field is walked; no `@Type` from class-transformer is needed. |
| `@ValidatePromise` | none: Zig has no promises | not needed | Rules are synchronous and pure. |
| `@IsDivisibleBy` | `v.divisibleBy(divisor)` | v1 | Integer and float fields; the divisor is a positive integer known at compile time. `v.divisibleBy(1)` on a float field means "a whole number". Deviations D16, D18, D19. |
| `@IsNegative` | `v.negative` | v1 | Signed integers and floats; on an unsigned field it is a compile error (always false). Deviations D16, D61. |
| `@IsPositive` | `v.positive` | v1 | Integers and floats. Deviation D16. |
| `@Max` | `v.max(max)` | v1 | The bound is converted to the field type at compile time; a bound outside the type or `v.max(maxInt(T))` is a compile error. zefir also adds `v.range`, `v.nonNegative` and `v.nonPositive`. Deviations D16, D58, D61. |
| `@Min` | `v.min(min)` | v1 | As `v.max`; `v.min(minInt(T))` is vacuous. Deviations D16, D58, D61. |
| `@IsInstance` | a static field type | not needed | The type of a field is fixed at compile time. |
| `@IsNotEmptyObject` | struct fields are fixed; maps are not walked | not needed | A struct always has its fields. Containers that hide their item type (`std.HashMap` and similar) are not walked; use `v.custom` on such a field. |
| `@Contains` | `v.contains(seed)` | v1 | A substring of bytes, case-sensitive; `v.contains("")` is a compile error. On a list field the compile error suggests `v.each(v.contains(...))` or `v.containsAll(.{ ... })`. Deviation D29. |
| `@IsAlpha` | `v.alpha` | v1 | ASCII letters `A-Za-z` only; `IsAlpha(locale)` for other locales is out. `""` passes (combine with `v.notEmpty`). Deviation D11. |
| `@IsAlphanumeric` | `v.alphanumeric` | v1 | ASCII letters and digits only; locale variants are out. `""` passes. Deviation D11. |
| `@IsAscii` | `v.ascii` | v1 | `""` passes. zefir also adds `v.printableAscii` (bytes 0x20-0x7E). Deviation D11. |
| `@IsByteLength` | `v.minBytes(min)` and `v.maxBytes(max)` | v1 | `IsByteLength(min, max)` becomes `.{ v.minBytes(min), v.maxBytes(max) }`, `IsByteLength(min)` becomes `v.minBytes(min)`, `IsByteLength(0, max)` becomes `v.maxBytes(max)` (`v.minBytes(0)` is a compile error). Raw bytes. Deviations D23, D61. |
| `@IsCurrency` | `v.custom(code, message, f)` | out | Locale-specific money formats: write `v.custom` with your own format. |
| `@IsFullWidth` | `v.fullWidth` | v1 | The character class of validator.js, kept for parity; it is not Unicode East Asian Width. Invalid UTF-8 fails with `validation.utf8`. Deviation D13. |
| `@IsHalfWidth` | `v.halfWidth` | v1 | As `v.fullWidth`. Deviation D13. |
| `@IsISO31661Alpha2` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list: use a Zig enum field, or `v.oneOf` with your own list. |
| `@IsISO31661Alpha3` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsISO31661Numeric` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list; `v.oneOf` accepts integers. |
| `@IsIdentityCard` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsLowercase` | `v.lowercase` | v1 | ASCII letters only. Deviation D30. |
| `@IsMobilePhone` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsMultibyte` | `v.multibyte` | v1 | As validator.js. |
| `@IsNumberString` | `v.digits` or `v.numberString` | v1 | `IsNumberString({ no_symbols: true })` becomes `v.digits` (`""` passes, D11); `IsNumberString()` becomes `v.numberString`; `{ locale }` is out. |
| `@IsPassportNumber` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPhoneNumber` | `v.custom(code, message, f)` | out | Per-country reference data (libphonenumber). |
| `@IsPostalCode` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsStrongPassword` | `v.strongPassword(.{ ... })` | v1 | `minLength`, `minLowercase`, `minUppercase`, `minNumbers` and `minSymbols` become `.min_length`, `.min_lowercase`, `.min_uppercase`, `.min_numbers` and `.min_symbols`, with the same defaults. No score mode. Deviations D13, D31. |
| `@IsSurrogatePair` | `v.custom(code, message, f)` | not needed | A UTF-16 notion; for "contains an astral code point" write `v.custom`. |
| `@IsTimeZone` | `v.custom(code, message, f)` | out | Needs the tz database, which changes between versions. |
| `@IsUppercase` | `v.uppercase` | v1 | ASCII letters only. Deviation D30. |
| `@IsVariableWidth` | `v.variableWidth` | v1 | As `v.fullWidth`. Deviation D13. |
| `@Length` | `v.length(min, max)` | v1 | `Length(min, max)` becomes `v.length(min, max)`, `Length(min)` becomes `v.minLength(min)`, `Length(0, max)` becomes `v.maxLength(max)` (`v.length(0, n)` is a compile error). Counts code points. Deviations D12, D13, D61. |
| `@Matches` | `v.custom(code, message, f)` | out | Needs a regular expression engine; the Zig standard library has none. |
| `@MaxLength` | `v.maxLength(max)` | v1 | Code points. `MaxLength(0)` becomes `v.empty`. Deviations D12, D13, D61. |
| `@MinLength` | `v.minLength(min)` | v1 | Code points. `MinLength(0)` is always true: a compile error. zefir also adds `v.notBlank` and `v.utf8`. Deviations D12, D13, D61. |
| `@NotContains` | `v.notContains(seed)` | v1 | `v.notContains("")` is a compile error. Deviation D29. |
| `@IsISO4217CurrencyCode` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsTaxId` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsISO6391` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsArray` | a slice or array field type | not needed | `[]const T` or `[N]T`. |
| `@IsBoolean` | a `bool` field type | not needed | The decoder accepts only `true` and `false` for a `bool` field. |
| `@IsEnum` | an enum field type | not needed | The decoder rejects unknown tags; `v.oneOf(.{ ... })` restricts a field to a subset of tags. |
| `@IsInt` | an integer field type | not needed | The type of the field is an integer type. On a float field use `v.divisibleBy(1)`. |
| `@IsNumber` | `v.finite` | v1 | On float fields NaN and infinities fail (`IsNumber`'s defaults); on integer fields it is always true: a compile error. `allowNaN` and `allowInfinity`: leave `v.finite` out, but the other number rules still reject non-finite values (D16). `maxDecimalPlaces` is not offered. Deviations D16, D61. |
| `@IsObject` | a struct field type | not needed | A struct field; maps and other containers that hide their item type are not walked (use `v.custom`). |
| `@IsString` | a string field type | not needed | `[]const u8`, `[]u8` or `[:0]const u8`; `[N]u8` is an array of numbers, not a string. |

## Deviations from validator.js

Where zefir deliberately differs from validator.js 13.15.35 or class-validator
0.15.1. The numbers are stable: a deviation keeps its number in every release.

| # | Rules | zefir | validator.js or class-validator | Example (zefir / class-validator) |
| --- | --- | --- | --- | --- |
| D11 | `ascii`, `alphanumeric`, `alpha`, `digits` | `""` passes: these are character classes. | `isAscii`, `isAlphanumeric`, `isAlpha` and `isNumeric({ no_symbols: true })` reject `""`. | `""` with `v.ascii`: passes / fails (combine with `v.notEmpty`) |
| D12 | `minLength`, `maxLength`, `length` | Every code point counts, variation selectors U+FE0E and U+FE0F included. | `isLength` does not count a U+FE0E or U+FE0F that follows a character. | `"❤\u{FE0F}"`: 2 characters / 1 |
| D13 | `minLength`, `maxLength`, `length`, `notBlank`, `fullWidth`, `halfWidth`, `variableWidth`, `strongPassword` | Invalid UTF-8 fails with the precondition `validation.utf8` / `must be valid UTF-8`, which `.withMessage` does not change. | A JavaScript server sees U+FFFD in place of invalid bytes and counts or classifies it. | `"\xff"` with `v.fullWidth`: `validation.utf8` / passes; `"Ab1!\xff\xff\xff\xff"` with `v.strongPassword(.{})`: `validation.utf8` / passes |
| D14 | `notEmpty` | A `null` `?T` skips the rule; one rule for strings and lists. | `IsNotEmpty` fails `null` unless `@IsOptional` is present; `isNotEmpty([])` is true (lists need `ArrayNotEmpty`). | `null` on `?[]const u32`: passes / fails; `[]` with `IsNotEmpty`: fails / passes |
| D15 | `oneOf`, `noneOf` | The values are strings, enum tags or integers; an empty, duplicate, mixed or invalid-UTF-8 list is a compile error, and so is a `v.noneOf` list that contains `""` or excludes every tag of an exhaustive enum or every value of an integer type. | Any values compared with `===`; `IsIn([])` never passes, `IsNotIn([])` always passes; duplicates are accepted. | `v.oneOf(.{})`: compile error / `IsIn([])`: always fails |
| D16 | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `divisibleBy`, `equals`, `notEquals` | On a float field NaN, `+inf` and `-inf` fail the precondition `validation.finite` / `must be a finite number`, which `.withMessage` does not change. | class-validator compares JavaScript numbers: `+inf` passes `Min` and `IsPositive`, `-inf` passes `Max` and `IsNegative` (and `Max(0)`), NaN fails them; `IsDivisibleBy` and `Equals` reject NaN and infinities too (same result, no separate code); `NotEquals`: D20. | `+inf` with `v.min(0)` or `v.positive`: fails / passes; `-inf` with `v.negative`: fails / passes |
| D18 | `divisibleBy` | Integer fields are exact at every width. | JavaScript numbers round above 2^53. | `u64` `9007199254740993` with `v.divisibleBy(3)`: passes / fails |
| D19 | `divisibleBy` | The divisor must be a positive integer that fits the field: `v.divisibleBy(0)`, negative and fractional divisors, `v.divisibleBy(1)` on an integer field and divisors beyond the type are compile errors. | `toFloat(v) % parseInt(n)`: 1.5 acts as 1, 0.5 and 0 never pass, -5 acts as 5. | `v.divisibleBy(0.5)`: compile error / never passes |
| D20 | `equals`, `notEquals` | Integers are exact at every width; a float parameter is rounded to the field type at compile time; NaN and infinities fail with `validation.finite` (so `v.notEquals(0)` fails on them); degenerate parameters are compile errors. | `===` on doubles; `notEquals(NaN, 0)` and `notEquals(+inf, 0)` are true. | `f32` field `0.10000000149011612` with `v.equals(0.1)`: passes / fails; `u64` `9007199254740992` with `v.equals(9007199254740993)`: fails / passes; NaN with `v.notEquals(0)`: fails / passes |
| D21 | `empty` | An empty slice passes. | `isEmpty([])` is false (`IsEmpty` knows only `''`, `null` and `undefined`). | `[]` with `v.empty`: passes / fails |
| D23 | `minBytes`, `maxBytes` | The raw length in bytes. | `isByteLength` counts the UTF-8 length of the decoded string (U+FFFD counts 3) and throws on a lone surrogate. | `"\xff"` with `v.minBytes(2)`: fails / passes |
| D29 | `contains`, `notContains` | `v.contains("")` and `v.notContains("")` are compile errors; bytes are compared, so a U+FFFD seed does not match invalid bytes. | An empty seed passes only strings of at least 2 UTF-16 units; a U+FFFD seed matches decoded invalid bytes. | `v.contains("\u{FFFD}")` on `"a\xffb"`: fails / passes |
| D30 | `lowercase`, `uppercase` | Only ASCII letters are inspected. | Unicode case mapping: `str === str.toLowerCase()`. | `"Émile"` with `v.lowercase`: passes / fails; `"STRAßE"` with `v.uppercase`: passes / fails |
| D31 | `strongPassword` | The length counts code points; all minima 0, and a `min_length` below the sum of the class minima, are compile errors; no score mode. | The length counts UTF-16 units; all-zero options accept every string, `""` included. | `"Ab1!😀😀"` with the defaults: fails (6 code points) / passes (8 units) |
| D58 | `min`, `max`, `range`, `oneOf`, `noneOf` | Integers are compared exactly in the field type at every width (`u64`, `i128`, …). | JavaScript numbers lose precision above 2^53: a decoded 9007199254740993 equals 9007199254740992. | `u64` `9007199254740992` with `v.min(9007199254740993)`: fails / passes; `9007199254740992` with `v.oneOf(.{9007199254740993})`: fails / passes |
| D61 | `notEmpty`, `empty`, `minItems`, `maxItems`, `minLength`, `maxLength`, `length`, `minBytes`, `maxBytes`, `min`, `max`, `range`, `nonNegative`, `negative`, `nonPositive`, `finite` | A rule that could never fail or never pass is a compile error: `v.notEmpty`, `v.empty`, `v.minItems` and `v.maxItems` on a fixed-length array `[N]T`; `v.minItems(0)`, `v.minLength(0)` and `v.minBytes(0)`; `v.maxItems(0)`, `v.maxLength(0)` and `v.maxBytes(0)` (use `v.empty`); `v.length(0, n)` (use `v.maxLength(n)`); `v.min(minInt(T))`, `v.max(maxInt(T))` and `v.range(minInt(T), maxInt(T))`; a bound outside the field type; `v.nonNegative`, `v.negative` and `v.nonPositive` on an unsigned field; `v.finite` on an integer field. | Accepted; the decorator is then always true or always false at run time. | `v.notEmpty` on a `[3]u32` field: compile error / `ArrayNotEmpty` on an array that always has 3 items: always passes; `v.maxItems(0)`: compile error / `ArrayMaxSize(0)`: only `[]` passes |
| D62 | all | A rule on a field type it does not support is a compile error, for example `v.positive` on a string, or `v.notEmpty` on `[N]u8` used as a string. | Decorators accept any value and fail at run time (`isPositive("5")` is false). | `v.positive` on a `[]const u8` field: compile error / `IsPositive` on a string property: always fails |
| D63 | `each` | `null` items of `[]const ?T` are skipped; item rules never see `null` (use `[]const T` to forbid nulls). | `{ each: true }` validates every item, `null` included, so most decorators fail a `null` item even with `@IsOptional` on the property. | `[1, null]` with `v.each(v.positive)`: passes / fails |
| D64 | all | The first failing rule is a value's only violation, and nothing inside a value whose rules failed is visited. | All decorators of a property run, and `ValidationError.constraints` lists every failure (unless `stopAtFirstError`); nested objects are validated regardless. | `.{ v.positive, v.custom("numbers.even", "must be even", isEven) }` on `-3`: 1 violation (`validation.positive`) / 2 constraints |

See also: [the overview](README.md) · [Common](common.md) · [Numbers](numbers.md) · [Strings](strings.md) · [Lists](lists.md)
