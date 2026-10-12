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
the walk already does it; **out** — outside the library: write `v.custom` with
your own data.

| Decorator | zefir | Status | Notes |
| --- | --- | --- | --- |
| `@ArrayNotEmpty` | `v.notEmpty` | v1 | One rule for strings and lists; a fixed-length array `[N]T` is a compile error. A `null` `?[]T` skips the rule. Deviation D14. |
| `@Allow` | unknown fields are an option of the decoder | not needed | `@Allow` only matters with `whitelist` or `forbidNonWhitelisted`. In Zig the decoder decides what an unknown JSON field does (`ignore_unknown_fields` in `std.json.ParseOptions`). |
| `@IsDefined` | a non-optional field type | not needed | Presence is the job of the field type: the decoder rejects a missing non-optional field. There is no `required` rule. |
| `@IsNotEmpty` | `v.notEmpty` | v1 | Strings (bytes; a string of spaces passes) and lists. On other field types presence is the type itself. Deviation D14. |
| `@IsOptional` | `?T` | not needed | A `null` optional skips its rules, `v.each` and nested validation. |
| `@Validate` | `v.custom(code, message, f)` or `validateSelf` | not needed | A constraint class becomes `v.custom(code, message, f)` for one field, or `validateSelf` with `v.fail` for checks across fields. No async constraints, no constraint arguments, no context. |
| `@ValidatorConstraint` | `v.custom(code, message, f)` | not needed | Exported together with `@Validate`. In zefir the function passed to `v.custom` is the constraint; there is no registry. |
| `@ValidateBy` | `v.custom(code, message, f)` | not needed | `ValidateBy({ name, validator })` is `v.custom`; the name becomes a code (segments `[a-z][a-z0-9_]*`, not `validation.` or `rpc.`). |
| `@ValidateIf` | `validateSelf` | not needed | Conditional rules are not in v1: write the condition in `validateSelf`. |
| `@ValidateNested` | nested structs are walked automatically | not needed | Every struct, optional, slice and array field is walked; no `@Type` from class-transformer is needed. |
| `@ValidatePromise` | none: Zig has no promises | not needed | Rules are synchronous and pure. |
| `@IsPositive` | `v.positive` | v1 | Integers and floats. Deviation D16. |
| `@IsInstance` | a static field type | not needed | The type of a field is fixed at compile time. |
| `@IsNotEmptyObject` | struct fields are fixed; maps are not walked | not needed | A struct always has its fields. Containers that hide their item type (`std.HashMap` and similar) are not walked; use `v.custom` on such a field. |
| `@IsCurrency` | `v.custom(code, message, f)` | out | Locale-specific money formats: write `v.custom` with your own format. |
| `@IsIdentityCard` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsMobilePhone` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPassportNumber` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPhoneNumber` | `v.custom(code, message, f)` | out | Per-country reference data (libphonenumber). |
| `@IsPostalCode` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsSurrogatePair` | `v.custom(code, message, f)` | not needed | A UTF-16 notion; for "contains an astral code point" write `v.custom`. |
| `@IsTimeZone` | `v.custom(code, message, f)` | out | Needs the tz database, which changes between versions. |
| `@Matches` | `v.custom(code, message, f)` | out | Needs a regular expression engine; the Zig standard library has none. |
| `@IsTaxId` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsArray` | a slice or array field type | not needed | `[]const T` or `[N]T`. |
| `@IsBoolean` | a `bool` field type | not needed | The decoder accepts only `true` and `false` for a `bool` field. |
| `@IsEnum` | an enum field type | not needed | The decoder rejects unknown tags. |
| `@IsInt` | an integer field type | not needed | The type of the field is an integer type. |
| `@IsObject` | a struct field type | not needed | A struct field; maps and other containers that hide their item type are not walked (use `v.custom`). |
| `@IsString` | a string field type | not needed | `[]const u8`, `[]u8` or `[:0]const u8`; `[N]u8` is an array of numbers, not a string. |

## Deviations from validator.js

Where zefir deliberately differs from validator.js 13.15.35 or class-validator
0.15.1. The numbers are stable: a deviation keeps its number in every release.

| # | Rules | zefir | validator.js or class-validator | Example (zefir / class-validator) |
| --- | --- | --- | --- | --- |
| D14 | `notEmpty` | A `null` `?T` skips the rule; one rule for strings and lists. | `IsNotEmpty` fails `null` unless `@IsOptional` is present; `isNotEmpty([])` is true (lists need `ArrayNotEmpty`). | `null` on `?[]const u32`: passes / fails; `[]` with `IsNotEmpty`: fails / passes |
| D16 | `positive` | On a float field NaN, `+inf` and `-inf` fail the precondition `validation.finite` / `must be a finite number`. | class-validator compares JavaScript numbers: `+inf` passes `IsPositive`, NaN fails it. | `+inf` with `v.positive`: fails / passes |
| D61 | `notEmpty` | A rule that could never fail or never pass is a compile error: `v.notEmpty` on a fixed-length array `[N]T`. | Accepted; the decorator is then always true or always false at run time. | `v.notEmpty` on a `[3]u32` field: compile error / `ArrayNotEmpty` on an array that always has 3 items: always passes |
| D62 | all | A rule on a field type it does not support is a compile error, for example `v.positive` on a string, or `v.notEmpty` on `[N]u8` used as a string. | Decorators accept any value and fail at run time (`isPositive("5")` is false). | `v.positive` on a `[]const u8` field: compile error / `IsPositive` on a string property: always fails |
| D63 | `each` | `null` items of `[]const ?T` are skipped; item rules never see `null` (use `[]const T` to forbid nulls). | `{ each: true }` validates every item, `null` included, so most decorators fail a `null` item even with `@IsOptional` on the property. | `[1, null]` with `v.each(v.positive)`: passes / fails |
| D64 | all | The first failing rule is a value's only violation, and nothing inside a value whose rules failed is visited. | All decorators of a property run, and `ValidationError.constraints` lists every failure (unless `stopAtFirstError`); nested objects are validated regardless. | `.{ v.positive, v.custom("numbers.even", "must be even", isEven) }` on `-3`: 1 violation (`validation.positive`) / 2 constraints |

See also: [the overview](README.md) · [Common](common.md) · [Numbers](numbers.md) · [Lists](lists.md)
