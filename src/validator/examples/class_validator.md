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
| `@IsNotEmpty` | `v.notEmpty` | v1 | Strings (bytes; a string of spaces passes) and lists. On other field types presence is the type itself. Deviation D14. |
| `@IsNotIn` | `v.noneOf(.{ ... })` | v1 | As `v.oneOf`, integers included. `""` cannot be listed (use `v.notEmpty`); excluding every tag of an exhaustive enum is a compile error. Deviations D15, D58. |
| `@IsOptional` | `?T` | not needed | A `null` optional skips its rules, `v.each` and nested validation. |
| `@NotEquals` | `v.notEquals(forbidden)` | v1 | `v.notEquals("")` is a compile error (use `v.notEmpty`). On floats NaN and infinities fail with `validation.finite`. Deviations D16, D20. |
| `@Validate` | `v.custom(code, message, f)` or `validateSelf` | not needed | A constraint class becomes `v.custom(code, message, f)` for one field, or `validateSelf` with `v.fail` for checks across fields. No async constraints, no constraint arguments, no context. |
| `@ValidatorConstraint` | `v.custom(code, message, f)` | not needed | Exported together with `@Validate`. In zefir the function passed to `v.custom` is the constraint; there is no registry. |
| `@ValidateBy` | `v.custom(code, message, f)` | not needed | `ValidateBy({ name, validator })` is `v.custom`; the name becomes a code (segments `[a-z][a-z0-9_]*`, not `validation.` or `rpc.`). |
| `@ValidateIf` | `validateSelf` | not needed | Conditional rules are not in v1: write the condition in `validateSelf`. |
| `@ValidateNested` | nested structs are walked automatically | not needed | Every struct, optional, slice and array field is walked; no `@Type` from class-transformer is needed. |
| `@ValidatePromise` | none: Zig has no promises | not needed | Rules are synchronous and pure. |
| `@MaxDate` | `v.maxDate(max)` | v1 | On string fields: the bound is an RFC 3339 full-date or date-time with an offset, fixed at compile time; the value must have the bound's form (otherwise `validation.date` or `validation.rfc3339`). `MaxDate(() => new Date())` ("now") is not supported: compare with the current time in the handler. Deviations D57, D61. |
| `@MinDate` | `v.minDate(min)` | v1 | As `v.maxDate`. Deviations D57, D61. |
| `@IsDivisibleBy` | `v.divisibleBy(divisor)` | v1 | Integer and float fields; the divisor is a positive integer known at compile time. `v.divisibleBy(1)` on a float field means "a whole number". Deviations D16, D18, D19. |
| `@IsNegative` | `v.negative` | v1 | Signed integers and floats; on an unsigned field it is a compile error (always false). Deviations D16, D61. |
| `@IsPositive` | `v.positive` | v1 | Integers and floats. Deviation D16. |
| `@Max` | `v.max(max)` | v1 | The bound is converted to the field type at compile time; a bound outside the type or `v.max(maxInt(T))` is a compile error. zefir also adds `v.range`, `v.nonNegative` and `v.nonPositive`. Deviations D16, D58, D61. |
| `@Min` | `v.min(min)` | v1 | As `v.max`; `v.min(minInt(T))` is vacuous. Deviations D16, D58, D61. |
| `@IsInstance` | a static field type | not needed | The type of a field is fixed at compile time. |
| `@IsNotEmptyObject` | struct fields are fixed; maps are not walked | not needed | A struct always has its fields. Containers that hide their item type (`std.HashMap` and similar) are not walked; use `v.custom` on such a field. |
| `@IsBase32` | `v.base32` | v1 | Canonical RFC 4648; `""` passes. The Crockford option is not offered (class-validator does not expose it). Deviation D32. |
| `@IsBase58` | `v.base58` | v1 | The Bitcoin alphabet, no checksum; as validator.js. |
| `@IsBase64` | `v.base64` or `v.base64Url` | v1 | `IsBase64()` becomes `v.base64` (padded, canonical); `IsBase64({ urlSafe: true })` becomes `v.base64Url` (unpadded, canonical). `{ padding: false }` and `{ urlSafe: true, padding: true }` are not in v1. Deviation D32. |
| `@IsCurrency` | `v.custom(code, message, f)` | out | Locale-specific money formats: write `v.custom` with your own format. |
| `@IsDataURI` | `v.dataUri` | v1 | RFC 2397 with the 11 IANA top-level media types; a base64 payload is checked. Deviation D41. |
| `@IsDateString` | `v.iso8601` | v1 | An alias of `IsISO8601`: `strict` is always on, and `strictSeparator` is not offered. Deviations D54, D55. |
| `@IsHSL` | `v.hslColor` | v1 | Deviation D38. |
| `@IsHexColor` | `v.hexColor` | v1 | `#` is required. Deviation D36. |
| `@IsISO31661Alpha2` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list: use a Zig enum field, or `v.oneOf` with your own list. |
| `@IsISO31661Alpha3` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsISO31661Numeric` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list; `v.oneOf` accepts integers. |
| `@IsISO8601` | `v.iso8601` | v1 | `strict` is always on (the calendar is always checked); `strictSeparator` is not offered. Deviations D54, D55. |
| `@IsIdentityCard` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsJSON` | `v.json` | v1 | The top level must be an object or an array (validator.js's default); nesting at most `v.max_json_depth` (64) levels. Deviation D34. |
| `@IsJWT` | `v.jwt` | v1 | The shape only; nothing is decoded. Deviation D33. |
| `@IsLocale` | `v.locale` | v1 | RFC 5646 syntax only. Deviation D40. |
| `@IsMagnetURI` | `v.magnetUri` | v1 | Deviation D42. |
| `@IsMilitaryTime` | `v.militaryTime` | v1 | `HH:MM` or `HHMM`, as class-validator's own regular expression. |
| `@IsMimeType` | `v.mimeType` | v1 | The 11 IANA top-level types. Deviation D39. |
| `@IsMobilePhone` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPassportNumber` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPhoneNumber` | `v.custom(code, message, f)` | out | Per-country reference data (libphonenumber). |
| `@IsPostalCode` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsRFC3339` | `v.rfc3339` | v1 | zefir also adds `v.date` (an RFC 3339 full-date, `YYYY-MM-DD`). Deviation D56. |
| `@IsRgbColor` | `v.rgbColor` | v1 | Percentages are always allowed; `IsRgbColor(false)` (`includePercentValues: false`) is not offered. Deviation D37. |
| `@IsSemVer` | `v.semVer` | v1 | As validator.js. |
| `@IsSurrogatePair` | `v.custom(code, message, f)` | not needed | A UTF-16 notion; for "contains an astral code point" write `v.custom`. |
| `@IsTimeZone` | `v.custom(code, message, f)` | out | Needs the tz database, which changes between versions. |
| `@Matches` | `v.custom(code, message, f)` | out | Needs a regular expression engine; the Zig standard library has none. |
| `@IsISO4217CurrencyCode` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsTaxId` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsISO6391` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsArray` | a slice or array field type | not needed | `[]const T` or `[N]T`. |
| `@IsBoolean` | a `bool` field type | not needed | The decoder accepts only `true` and `false` for a `bool` field. |
| `@IsDate` | `v.date`, `v.rfc3339` or `v.iso8601` on a string field | not needed | Zig has no `Date` type: a DTO carries the date as the string it arrived as. The predicate `v.isDate` means "a `YYYY-MM-DD` string". |
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
| D14 | `notEmpty` | A `null` `?T` skips the rule; one rule for strings and lists. | `IsNotEmpty` fails `null` unless `@IsOptional` is present; `isNotEmpty([])` is true (lists need `ArrayNotEmpty`). | `null` on `?[]const u32`: passes / fails; `[]` with `IsNotEmpty`: fails / passes |
| D15 | `oneOf`, `noneOf` | The values are strings, enum tags or integers; an empty, duplicate, mixed or invalid-UTF-8 list is a compile error, and so is a `v.noneOf` list that contains `""` or excludes every tag of an exhaustive enum or every value of an integer type. | Any values compared with `===`; `IsIn([])` never passes, `IsNotIn([])` always passes; duplicates are accepted. | `v.oneOf(.{})`: compile error / `IsIn([])`: always fails |
| D16 | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `divisibleBy`, `equals`, `notEquals` | On a float field NaN, `+inf` and `-inf` fail the precondition `validation.finite` / `must be a finite number`, which `.withMessage` does not change. | class-validator compares JavaScript numbers: `+inf` passes `Min` and `IsPositive`, `-inf` passes `Max` and `IsNegative` (and `Max(0)`), NaN fails them; `IsDivisibleBy` and `Equals` reject NaN and infinities too (same result, no separate code); `NotEquals`: D20. | `+inf` with `v.min(0)` or `v.positive`: fails / passes; `-inf` with `v.negative`: fails / passes |
| D18 | `divisibleBy` | Integer fields are exact at every width. | JavaScript numbers round above 2^53. | `u64` `9007199254740993` with `v.divisibleBy(3)`: passes / fails |
| D19 | `divisibleBy` | The divisor must be a positive integer that fits the field: `v.divisibleBy(0)`, negative and fractional divisors, `v.divisibleBy(1)` on an integer field and divisors beyond the type are compile errors. | `toFloat(v) % parseInt(n)`: 1.5 acts as 1, 0.5 and 0 never pass, -5 acts as 5. | `v.divisibleBy(0.5)`: compile error / never passes |
| D20 | `equals`, `notEquals` | Integers are exact at every width; a float parameter is rounded to the field type at compile time; NaN and infinities fail with `validation.finite` (so `v.notEquals(0)` fails on them); degenerate parameters are compile errors. | `===` on doubles; `notEquals(NaN, 0)` and `notEquals(+inf, 0)` are true. | `f32` field `0.10000000149011612` with `v.equals(0.1)`: passes / fails; `u64` `9007199254740992` with `v.equals(9007199254740993)`: fails / passes; NaN with `v.notEquals(0)`: fails / passes |
| D21 | `empty` | An empty slice passes. | `isEmpty([])` is false (`IsEmpty` knows only `''`, `null` and `undefined`). | `[]` with `v.empty`: passes / fails |
| D32 | `base64`, `base64Url`, `base32` | Canonical RFC 4648: non-zero padding bits fail; `v.base64Url` rejects a length of 4n + 1; `v.base32` takes only 0, 1, 3, 4 or 6 padding characters, and `""` passes. | Regular expressions only; `isBase32('')` is false. | `AB==` with `v.base64`: fails / passes; `Z` with `v.base64Url`: fails / passes; `A=======` with `v.base32`: fails / passes; `""` with `v.base32`: passes / fails |
| D33 | `jwt` | An empty header or payload, and segments that are not canonical base64url, fail. | `isBase64('')` is true, so empty segments pass. | `..`: fails / passes; `a.b.c`: fails / passes |
| D34 | `json` | Unpaired surrogate escapes, invalid UTF-8 and nesting deeper than `v.max_json_depth` (64) fail. | `JSON.parse` accepts them (V8 accepted 100,000 levels). | `["\ud800"]`: fails / passes; 65 nested arrays: fails / passes |
| D36 | `hexColor` | `#` is required. | `require_hashtag` is false by default, and class-validator offers no option. | `fff`: fails / passes |
| D37 | `rgbColor` | CSS whitespace between values is allowed; the alpha may have more than 2 decimals, and `1.00` is allowed. | The default rejects spaces; the alpha is `0?.\d\d?`, `1`, `1.0`, `0` or `0.0`. | `rgb(255, 0, 0)`: passes / fails; `rgba(0,0,0,0.004)`: passes / fails |
| D38 | `hslColor` | No trimming; only CSS whitespace (space, tab, LF, CR, FF); optional whitespace on both sides of `/`. | Collapses and trims whitespace; takes JavaScript's `\s` (NBSP, U+FEFF, …); requires whitespace after `/`. | ` hsl(120,100%,50%)`: fails / passes; `hsl(120 100% 50%/0.5)`: passes / fails |
| D39 | `mimeType` | RFC 9110 parameters on any type; the 11 IANA top-level types (`haptics` and `example` included); RFC 6838 subtypes of up to 127 bytes that start with a letter or a digit; empty parameter values and comments fail. | `charset` only on `text/*`, `boundary` and `charset` only on `multipart/*`; 9 top-level types; subtypes of up to 100 characters. | `application/json; charset=utf-8`: passes / fails; `haptics/ivs`: passes / fails; `image/.png`: fails / passes; `text/plain; charset=`: fails / passes |
| D40 | `locale` | `_` fails; the prefixes `x-` and `i-` are case-insensitive; empty subtags fail. | Accepts `en_US`; rejects `X-PRIVATE` and `I-KLINGON`; accepts `de-1---`. | `en_US`: fails / passes; `X-PRIVATE`: passes / fails; `de-1---`: fails / passes |
| D41 | `dataUri` | No whitespace and no trimming; `%` is followed by 2 hex digits; a `;base64` payload must be base64; the top-level type is one of the 11 IANA types; parameter values may contain `. _ ~ ! $ & ' * +`. | Trims the header and allows whitespace in the data; no check of `%HH` or of the payload; any `[a-z]+` type; parameter values only `[a-z0-9-]`. | `data:,%zz`: fails / passes; `data:text/plain;base64,!!!`: fails / passes; `data:foo/bar,x`: fails / passes; `data:application/pdf;name=report.pdf;base64,JVBERi0=`: passes / fails |
| D42 | `magnetUri` | The whole query must be RFC 3986 query characters with valid `%HH`; an empty parameter before `xt` is skipped. | Only the `xt` parameter is checked; an empty parameter right before `xt` fails. | `magnet:?xt=urn:btih:c12f…a88a&dn=a b`: fails / passes; `magnet:?&xt=urn:btih:c12f…a88a`: passes / fails |
| D54 | `iso8601` | Fail, although validator.js accepts them: impossible dates (there is no `strict` option); week 00, and week 53 of a 52-week year; signed years; separators other than `T`, `t` or a space (tab, LF, NBSP); a separator or a zone without a time; a time after a reduced date; mixed basic and extended week dates; `T24` without minutes, `T24:0059` and `T24:00.5`; a bare number after `T`; an offset with a dangling colon. | `isISO8601` with its default options (`IsISO8601`, `IsDateString`) accepts them all. | `2021-02-29`: fails / passes; `2020-W00`: fails / passes; `+2020-05-17`: fails / passes; `2020-05-17T`: fails / passes |
| D55 | `iso8601` | Pass, although validator.js rejects them: a lowercase `t` separator; `24:00:00`; leap seconds at the end of a month; ordinal day 360; the years 0000-0999 (against validator.js's strict mode only). | `isISO8601` rejects them. | `2020-360`: passes / fails; `2020-05-17T24:00:00`: passes / fails; `2016-12-31T23:59:60Z`: passes / fails |
| D56 | `rfc3339` | The day of the month is checked; second 60 passes only as a leap second (23:59:60 UTC on the last day of a month). | Any day 01-31 in every month; second 60 at any time. | `2021-02-29T00:00:00Z`: fails / passes; `2020-05-17T10:30:60Z`: fails / passes |
| D57 | `minDate`, `maxDate` | The bound is an RFC 3339 full-date or date-time-with-offset string fixed at compile time; the value must have the bound's form, otherwise the precondition `validation.date` or `validation.rfc3339`; a date-time without an offset fails; date-times compare exactly as UTC instants, leap seconds included; days never overflow; there is no "now". | `Date` objects (class-transformer's `new Date(value)`): the host's time zone for values without an offset, milliseconds at most, overflowing days roll over (`2020-02-30` becomes `2020-03-01`), `() => Date` for "now", `:60` cannot be parsed. | `2016-12-31T23:59:59.000001Z` with `v.maxDate("2016-12-31T23:59:59Z")`: fails / passes; `2020-02-30` with `v.minDate("2020-01-01")`: `validation.date` / passes |
| D58 | `min`, `max`, `range`, `oneOf`, `noneOf` | Integers are compared exactly in the field type at every width (`u64`, `i128`, …). | JavaScript numbers lose precision above 2^53: a decoded 9007199254740993 equals 9007199254740992. | `u64` `9007199254740992` with `v.min(9007199254740993)`: fails / passes; `9007199254740992` with `v.oneOf(.{9007199254740993})`: fails / passes |
| D61 | `notEmpty`, `empty`, `minItems`, `maxItems`, `min`, `max`, `range`, `nonNegative`, `negative`, `nonPositive`, `finite`, `minDate`, `maxDate` | A rule that could never fail or never pass is a compile error: `v.notEmpty`, `v.empty`, `v.minItems` and `v.maxItems` on a fixed-length array `[N]T`; `v.minItems(0)` and `v.maxItems(0)` (use `v.empty`); `v.min(minInt(T))`, `v.max(maxInt(T))` and `v.range(minInt(T), maxInt(T))`; a bound outside the field type; `v.nonNegative`, `v.negative` and `v.nonPositive` on an unsigned field; `v.finite` on an integer field; `v.minDate("0000-01-01")` and `v.maxDate("9999-12-31")` (use `v.date`) and `v.minDate` at the earliest date-time (use `v.rfc3339`). | Accepted; the decorator is then always true or always false at run time. | `v.notEmpty` on a `[3]u32` field: compile error / `ArrayNotEmpty` on an array that always has 3 items: always passes; `v.maxItems(0)`: compile error / `ArrayMaxSize(0)`: only `[]` passes |
| D62 | all | A rule on a field type it does not support is a compile error, for example `v.positive` on a string, or `v.notEmpty` on `[N]u8` used as a string. | Decorators accept any value and fail at run time (`isPositive("5")` is false). | `v.positive` on a `[]const u8` field: compile error / `IsPositive` on a string property: always fails |
| D63 | `each` | `null` items of `[]const ?T` are skipped; item rules never see `null` (use `[]const T` to forbid nulls). | `{ each: true }` validates every item, `null` included, so most decorators fail a `null` item even with `@IsOptional` on the property. | `[1, null]` with `v.each(v.positive)`: passes / fails |
| D64 | all | The first failing rule is a value's only violation, and nothing inside a value whose rules failed is visited. | All decorators of a property run, and `ValidationError.constraints` lists every failure (unless `stopAtFirstError`); nested objects are validated regardless. | `.{ v.positive, v.custom("numbers.even", "must be even", isEven) }` on `-3`: 1 violation (`validation.positive`) / 2 constraints |

See also: [the overview](README.md) · [Common](common.md) · [Numbers](numbers.md) · [Encodings](encodings.md) · [Dates](dates.md) · [Lists](lists.md)
