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
| `@IsLatLong` | `v.latLong` | v1 | Strings only; on a number field it is a compile error: use two float fields with `v.latitude` and `v.longitude`. `checkDMS` is not offered. Deviation D26. |
| `@IsLatitude` | `v.latitude` | v1 | String or float field. An integer field is a compile error with a hint for scaled (E6, E7) coordinates, while class-validator accepts any JavaScript number. Deviations D16, D25, D27, D62. |
| `@IsLongitude` | `v.longitude` | v1 | As `v.latitude`. Deviations D16, D25, D27, D62. |
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
| `@IsDivisibleBy` | `v.divisibleBy(divisor)` | v1 | Integer and float fields; the divisor is a positive integer known at compile time. `v.divisibleBy(1)` on a float field means "a whole number". Deviations D16, D18, D19. |
| `@IsNegative` | `v.negative` | v1 | Signed integers and floats; on an unsigned field it is a compile error (always false). Deviations D16, D61. |
| `@IsPositive` | `v.positive` | v1 | Integers and floats. Deviation D16. |
| `@Max` | `v.max(max)` | v1 | The bound is converted to the field type at compile time; a bound outside the type or `v.max(maxInt(T))` is a compile error. zefir also adds `v.range`, `v.nonNegative` and `v.nonPositive`. Deviations D16, D58, D61. |
| `@Min` | `v.min(min)` | v1 | As `v.max`; `v.min(minInt(T))` is vacuous. Deviations D16, D58, D61. |
| `@IsInstance` | a static field type | not needed | The type of a field is fixed at compile time. |
| `@IsNotEmptyObject` | struct fields are fixed; maps are not walked | not needed | A struct always has its fields. Containers that hide their item type (`std.HashMap` and similar) are not walked; use `v.custom` on such a field. |
| `@IsBooleanString` | `v.booleanString` | v1 | Exactly `true`, `false`, `1` or `0`, case-sensitive. On a `bool` field it is a compile error: the field is already a boolean. |
| `@IsCurrency` | `v.custom(code, message, f)` | out | Locale-specific money formats: write `v.custom` with your own format. |
| `@IsDecimal` | `v.decimal(.{ ... })` | v1 | `decimal_digits: 'a,b'` becomes `.min_decimal_digits = a, .max_decimal_digits = b`; `'a,'` sets the minimum only; `'a'` sets both to `a`; `force_decimal` becomes `.force_decimal`. `locale` is out: the decimal mark is `.`. Deviation D28. |
| `@IsEmail` | `v.email` | v1 | The validator.js options are not mapped. The last label of the domain must be a top-level domain, as `isFQDN` requires. Deviations D1, D2, D4. |
| `@IsFQDN` | `v.fqdn(.{ ... })` | v1 | The options `require_tld`, `allow_underscores`, `allow_trailing_dot` and `allow_wildcard` keep their names and defaults; `allow_numeric_tld` and `ignore_max_length` are not offered. Deviations D4, D45. |
| `@IsHexadecimal` | `v.hexadecimal` | v1 | An optional `0x`, `0X`, `0h` or `0H` prefix, as validator.js. |
| `@IsIP` | `v.ip`, `v.ipv4`, `v.ipv6` | v1 | `IsIP()` becomes `v.ip`; `IsIP(4)` or `IsIP('4')` becomes `v.ipv4`; `IsIP(6)` or `IsIP('6')` becomes `v.ipv6`. Deviation D43. |
| `@IsISO31661Alpha2` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list: use a Zig enum field, or `v.oneOf` with your own list. |
| `@IsISO31661Alpha3` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsISO31661Numeric` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list; `v.oneOf` accepts integers. |
| `@IsIdentityCard` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsMACAddress` | `v.macAddress(.{ ... })` | v1 | `IsMACAddress()` becomes `v.macAddress(.{})` (EUI-48 or EUI-64); `{ eui: '48' }` becomes `.eui = .eui48`, `{ eui: '64' }` becomes `.eui = .eui64`; `{ no_separators: true }` (or `no_colons`) becomes `.format = .bare`. Deviation D44. |
| `@IsMobilePhone` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsNumberString` | `v.numberString`, `v.digits` | v1 | `IsNumberString()` becomes `v.numberString`; `IsNumberString({ no_symbols: true })` becomes `v.digits`, which passes `""` (D11); `{ locale }` is out. |
| `@IsOctal` | `v.octal` | v1 | Same as validator.js. |
| `@IsPassportNumber` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPhoneNumber` | `v.custom(code, message, f)` | out | Per-country reference data (libphonenumber). |
| `@IsPort` | `v.port` | v1 | Strings only, as class-validator; for a number use a `u16` field with `v.min(1)`. Deviations D24, D62. |
| `@IsPostalCode` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsSurrogatePair` | `v.custom(code, message, f)` | not needed | A UTF-16 notion; for "contains an astral code point" write `v.custom`. |
| `@IsTimeZone` | `v.custom(code, message, f)` | out | Needs the tz database, which changes between versions. |
| `@IsUrl` | `v.httpUrl` | v1 | `http` and `https` only; the `isURL` options are not mapped. Deviations D6, D7, D8, D9, D10, D59. |
| `@Matches` | `v.custom(code, message, f)` | out | Needs a regular expression engine; the Zig standard library has none. |
| `@IsISO4217CurrencyCode` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsTaxId` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsISO6391` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsArray` | a slice or array field type | not needed | `[]const T` or `[N]T`. |
| `@IsBoolean` | a `bool` field type | not needed | The decoder accepts only `true` and `false` for a `bool` field; for the strings `"true"` and `"false"` use `v.booleanString`. |
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
| D1 | `email` | A quoted local part is rejected. | Quoted local parts are accepted, with spaces and control characters inside the quotes. | `"a b"@example.com` and `"quoted"@example.com`: fail / pass |
| D2 | `email` | ASCII only: no UTF-8 local part (RFC 6531) and no domain in another script; an international domain arrives as `xn--` labels. | `allow_utf8_local_part` is true by default, and `isFQDN` accepts U+00A1-U+FFFF in labels. | `jösé@example.com`, `用户@example.com`, `user@例え.jp`: fail / pass |
| D4 | `email`, `fqdn` | Invalid UTF-8 fails the rule under its own code; `v.httpUrl` rejects it too (D9). | A JavaScript server decodes invalid UTF-8 to U+FFFD before validation, and `isFQDN` accepts U+FFFD in labels. | `user@ex\xffample.com`; `ex\xffample.com` with `v.fqdn(.{})`: fail / pass |
| D6 | `httpUrl` | The scheme is required: `http` or `https` in any case, followed by `//`. | `require_protocol` is false, `ftp` is allowed, and `http:example.com` is accepted. | `example.com`, `ftp://example.com`, `http:example.com`: fail / pass |
| D7 | `httpUrl` | A host of one label and a trailing dot are accepted. | `require_tld` rejects hosts of one label; `allow_trailing_dot` is false. | `http://localhost:8080/a?b#c`, `http://api:8080`, `https://example.com./`: pass / fail |
| D8 | `httpUrl` | Userinfo, an empty port and a port longer than 5 digits are rejected. | Userinfo is accepted (`disallow_auth` is false); an empty port is accepted; any digit string with a value from 1 to 65535 is accepted. | `https://user@example.com`, `https://example.com@evil.example`, `http://example.com:`, `http://example.com:000080`: fail / pass |
| D9 | `httpUrl` | Non-ASCII bytes are rejected anywhere in the URL (an international host arrives as `xn--` labels), and so are IPv6 zone ids; the path, query and fragment allow only printable ASCII from 0x21 to 0x7E except `"`, `<`, `>` and `\`, `%` must be followed by 2 hex digits, and there is at most one `#`. | Only whitespace, `<` and `>` are rejected anywhere in the URL; the path, query and fragment are otherwise unchecked; `isIP` accepts zone ids. | `https://münchen.de/`, `http://example.com/%zz`, `http://example.com/a#b#c`, `http://example.com/a"b`, `http://[fe80::1%25eth0]/`: fail / pass |
| D10 | `httpUrl` | The length is not limited inside the rule: add a length rule. | `max_allowed_length` is 2084 UTF-16 code units. | `http://example.com/aaa…` of 2085 bytes: passes / fails |
| D14 | `notEmpty` | A `null` `?T` skips the rule; one rule for strings and lists. | `IsNotEmpty` fails `null` unless `@IsOptional` is present; `isNotEmpty([])` is true (lists need `ArrayNotEmpty`). | `null` on `?[]const u32`: passes / fails; `[]` with `IsNotEmpty`: fails / passes |
| D15 | `oneOf`, `noneOf` | The values are strings, enum tags or integers; an empty, duplicate, mixed or invalid-UTF-8 list is a compile error, and so is a `v.noneOf` list that contains `""` or excludes every tag of an exhaustive enum or every value of an integer type. | Any values compared with `===`; `IsIn([])` never passes, `IsNotIn([])` always passes; duplicates are accepted. | `v.oneOf(.{})`: compile error / `IsIn([])`: always fails |
| D16 | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `divisibleBy`, `equals`, `notEquals`, `latitude`, `longitude` | On a float field NaN, `+inf` and `-inf` fail the precondition `validation.finite` / `must be a finite number`, which `.withMessage` does not change. | class-validator compares JavaScript numbers: `+inf` passes `Min` and `IsPositive`, `-inf` passes `Max` and `IsNegative` (and `Max(0)`), NaN fails them; `IsDivisibleBy`, `Equals`, `IsLatitude` and `IsLongitude` reject NaN and infinities too (same result, no separate code); `NotEquals`: D20. | `+inf` with `v.min(0)` or `v.positive`: fails / passes; `-inf` with `v.negative`: fails / passes |
| D18 | `divisibleBy` | Integer fields are exact at every width. | JavaScript numbers round above 2^53. | `u64` `9007199254740993` with `v.divisibleBy(3)`: passes / fails |
| D19 | `divisibleBy` | The divisor must be a positive integer that fits the field: `v.divisibleBy(0)`, negative and fractional divisors, `v.divisibleBy(1)` on an integer field and divisors beyond the type are compile errors. | `toFloat(v) % parseInt(n)`: 1.5 acts as 1, 0.5 and 0 never pass, -5 acts as 5. | `v.divisibleBy(0.5)`: compile error / never passes |
| D20 | `equals`, `notEquals` | Integers are exact at every width; a float parameter is rounded to the field type at compile time; NaN and infinities fail with `validation.finite` (so `v.notEquals(0)` fails on them); degenerate parameters are compile errors. | `===` on doubles; `notEquals(NaN, 0)` and `notEquals(+inf, 0)` are true. | `f32` field `0.10000000149011612` with `v.equals(0.1)`: passes / fails; `u64` `9007199254740992` with `v.equals(9007199254740993)`: fails / passes; NaN with `v.notEquals(0)`: fails / passes |
| D21 | `empty` | An empty slice passes. | `isEmpty([])` is false (`IsEmpty` knows only `''`, `null` and `undefined`). | `[]` with `v.empty`: passes / fails |
| D24 | `port` | A sign is rejected. | `isInt` coercion lets `+80`, `+0` and `-0` pass. | `+80`, `-0`: fail / pass |
| D25 | `latitude`, `longitude` | On a string field a comma is rejected, and `longitude` rejects leading whitespace. | class-validator builds `${v},0` and `0,${v}` for `isLatLong`, so `1,2` passes; the longitude may follow one whitespace character. | `1,2`: fails / passes; ` 45` with `v.longitude`: fails / passes |
| D26 | `latLong` | Exactly one comma, and at most one space (the byte 0x20) after it. | Everything after a second comma is ignored, and any one whitespace character may follow the comma. | `1,2,garbage`, `40.7128,\t-74.0060`: fail / pass |
| D27 | `latitude`, `longitude` | On a float field, a range check only. | class-validator turns the number into a string, so a value below 1e-6 in magnitude, written as `1e-7`, is rejected. | `1e-7`: passes / fails |
| D28 | `decimal` | `.min_decimal_digits = 0` and a maximum below the minimum are compile errors. | `decimal_digits: '0,'` accepts `1.` and `.`; `'2,1'` throws a `SyntaxError` at run time. | `v.decimal(.{ .min_decimal_digits = 0 })`: compile error / `1.` passes |
| D43 | `ip`, `ipv6` | IPv6 zone ids are rejected. | A `%` followed by letters, digits and dots is accepted after every IPv6 form. | `fe80::1%eth0`: fails / passes |
| D44 | `macAddress` | Only the byte 0x20 is a space separator. | Any whitespace character separates (tab, line feed, no-break space and others). | `00\t00\t5e\t00\t53\t01`: fails / passes |
| D45 | `fqdn` | ASCII only, and at most 253 bytes (254 with an allowed trailing dot). | Labels may hold U+00A1-U+FFFF except the fullwidth forms U+FF01-U+FF5E; the total length is not checked. | `münchen.de`, a name of 254 bytes: fail / pass |
| D58 | `min`, `max`, `range`, `oneOf`, `noneOf` | Integers are compared exactly in the field type at every width (`u64`, `i128`, …). | JavaScript numbers lose precision above 2^53: a decoded 9007199254740993 equals 9007199254740992. | `u64` `9007199254740992` with `v.min(9007199254740993)`: fails / passes; `9007199254740992` with `v.oneOf(.{9007199254740993})`: fails / passes |
| D59 | `httpUrl` | The host is at most 253 bytes (254 with a trailing dot). | The host length is not checked: only its labels (up to 63 bytes) and the 2084-unit total. | `http://` + a host of 254 bytes + `/`: fails / passes |
| D61 | `notEmpty`, `empty`, `minItems`, `maxItems`, `min`, `max`, `range`, `nonNegative`, `negative`, `nonPositive`, `finite` | A rule that could never fail or never pass is a compile error: `v.notEmpty`, `v.empty`, `v.minItems` and `v.maxItems` on a fixed-length array `[N]T`; `v.minItems(0)` and `v.maxItems(0)` (use `v.empty`); `v.min(minInt(T))`, `v.max(maxInt(T))` and `v.range(minInt(T), maxInt(T))`; a bound outside the field type; `v.nonNegative`, `v.negative` and `v.nonPositive` on an unsigned field; `v.finite` on an integer field. | Accepted; the decorator is then always true or always false at run time. | `v.notEmpty` on a `[3]u32` field: compile error / `ArrayNotEmpty` on an array that always has 3 items: always passes; `v.maxItems(0)`: compile error / `ArrayMaxSize(0)`: only `[]` passes |
| D62 | all | A rule on a field type it does not support is a compile error, for example `v.positive` on a string, `v.latitude` on an integer field, `v.port` on a `u16`, or `v.notEmpty` on `[N]u8` used as a string. | Decorators accept any value and fail at run time (`isPositive("5")` is false); `IsLatitude` and `IsLongitude` also accept JavaScript numbers, so an integer 45 passes. | `v.positive` on a `[]const u8` field: compile error / `IsPositive` on a string property: always fails |
| D63 | `each` | `null` items of `[]const ?T` are skipped; item rules never see `null` (use `[]const T` to forbid nulls). | `{ each: true }` validates every item, `null` included, so most decorators fail a `null` item even with `@IsOptional` on the property. | `[1, null]` with `v.each(v.positive)`: passes / fails |
| D64 | all | The first failing rule is a value's only violation, and nothing inside a value whose rules failed is visited. | All decorators of a property run, and `ValidationError.constraints` lists every failure (unless `stopAtFirstError`); nested objects are validated regardless. | `.{ v.positive, v.custom("numbers.even", "must be even", isEven) }` on `-3`: 1 violation (`validation.positive`) / 2 constraints |

See also: [the overview](README.md) · [Common](common.md) · [Numbers](numbers.md) · [Formats](formats.md) · [Lists](lists.md)
