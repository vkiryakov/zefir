# zefir-validator: coming from class-validator

For developers who know class-validator 0.15.1 and NestJS: how its ideas and
decorators map to zefir-validator, and where zefir deliberately behaves
differently from class-validator and validator.js 13.15.35.

A DTO of class-validator, in the comment, and the same DTO in zefir:

```zig
const v = @import("validator");

// class CreateUserDto {
//   @Expose({ name: "userName" })
//   @Transform(({ value }) => value.trim())
//   @IsNotEmpty()
//   @MaxLength(64)
//   user_name: string;
//
//   @IsEmail()
//   email: string;
//
//   @IsOptional()
//   @IsInt()
//   @Min(18)
//   age?: number;
//
//   @ArrayMaxSize(5)
//   @IsNotEmpty({ each: true })
//   tags: string[];
// }
const CreateUserDto = struct {
    user_name: []const u8,
    email: []const u8,
    age: ?u8 = null, // @IsOptional and @IsInt: an optional integer
    tags: []const []const u8,

    pub const field_rules = .{
        .user_name = .{ v.rename("userName"), v.trim, v.notEmpty, v.maxLength(64) },
        .email = v.email,
        .age = v.min(18), // null skips the rule
        .tags = .{ v.maxItems(5), v.each(v.notEmpty) },
    };
};
```

The decorators of a property become one entry of `field_rules`: the outside
name first, then the transforms, then the rules, which run left to right.
`@IsOptional` and `@IsInt` are the field type, `?u8`, and `{ each: true }` is
`v.each(...)`, the last rule of its list. With `.user_name = "   "`,
`.email = "ada.example.com"`, `.age = 17` and `.tags = &.{ "zig", "" }`,
`v.transform` and then `v.checkAll` report `userName` (`validation.not_empty`,
after the trim), `email` (`validation.email`), `age` (`validation.min`) and
`tags[1]` (`validation.not_empty`). [Concepts](#concepts) and
[Decorators](#decorators) map the rest.

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
| class-transformer's `@Expose({ name: "userName" })` | `v.rename("userName")`, first in the entry: `.user_name = .{ v.rename("userName"), v.notBlank }`; the paths of violations use the name, and so does the JSON of zefir-http, whose codec asks `v.fieldNamed` and `v.nameOf` ([Input](../../http/examples/README.md#input)); a codec of your own asks them too ([Reading and writing JSON by outside names](README.md#reading-and-writing-json-by-outside-names)) |
| class-transformer's `@Transform(({ value }) => value.trim())` | a transform before the rules of the entry: `v.trim`, `v.trimStart`, `v.trimEnd`, `v.toLower`, `v.toUpper`, or `v.transformWith(f)` with a function of your own; for the items of a list, inside `v.each`: `v.each(.{ v.trim, v.notEmpty })`; zefir-http runs them on every request and response |
| `plainToInstance()`, then `validate()` | in a zefir-http handler, `ctx.json(T)`, which does all of it and answers 422 with every violation ([Input](../../http/examples/README.md#input)); elsewhere, a codec that reads the outside names ([Reading and writing JSON by outside names](README.md#reading-and-writing-json-by-outside-names)), or `std.json` when no field is renamed, then `v.transform(arena.allocator(), &value)`, then `v.check` or `v.checkAll` |
| `@IsOptional()` | `?T`: `null` skips the field's rules |
| `@IsDefined()` | a non-optional field type |
| `@ValidateIf()` | `validateSelf` |
| `{ each: true }` | `v.each(rule)` or `v.each(.{ rules })`, last in the tuple; slices and arrays only; `null` items are skipped (D63) |
| `{ message: "…" }` | `.withMessage("…")` with placeholders `{name}`, as in `v.range(18, 120).withMessage("age must be from {min} to {max}")`; no message functions and no `$value`, `$property`, `$target` or `$constraintN` ([Messages](README.md#messages)) |
| `@Validate()` with a constraint class | `v.custom(code, message, f)` for one field, `validateSelf` with `v.fail` across fields |
| `validate(object)` | `v.check(&value, &path_buf)` for the first violation, `v.checkAll(gpa, &value)` for all of them |
| `stopAtFirstError` | `v.check` stops at the first violation; `v.checkAll` reports at most one violation per value and at most 100 in all |
| `skipMissingProperties`, `skipNullProperties`, `skipUndefinedProperties` | not needed: presence is the field type, and `null` in a `?T` skips the field's rules |
| `whitelist`, `forbidNonWhitelisted`, `forbidUnknownValues` | options of the decoder: in a zefir-http handler, `ctx.json(T)` refuses unknown keys (`http.unknown_field`) unless the DTO declares `pub const unknown_fields = .ignore;` or the server's option `.unknown_fields` says so ([Input](../../http/examples/README.md#input)); `std.json` has `ignore_unknown_fields` |
| `ValidationError` | `v.Violation`: `code`, `message` and `field`, the path of the value |
| `ValidationError.target`, `.value` | none: a violation never contains the value or the object, as long as a hand-built `validateSelf` result has static `code` and `message` strings (`v.fail` guarantees them) |
| the keys of `ValidationError.constraints` (`isNotEmpty`) | `Violation.code` (`validation.not_empty`); the message has no property name, the path is in `field` |
| groups, `always`, `context` | not yet (TODO) |

## Decorators

Status: **rule** — a rule of zefir-validator; **not needed** — the field
type, the decoder or the walk already does it; **out** — outside the library:
write `v.custom`, or use a Zig enum or `v.oneOf`, with your own data.

| Decorator | zefir | Status | Notes |
| --- | --- | --- | --- |
| `@ArrayContains` | `v.containsAll(.{ ... })` | rule | Renamed: `v.contains` and `v.notContains` are the substring rules. Slices and arrays `[N]T` of `bool`, enum, integer or string items. An empty, duplicate, mixed, float or `""` list is a compile error; on a string field the error points to `v.contains`. Deviations D22, D58. |
| `@ArrayMaxSize` | `v.maxItems(max)` | rule | Slices only (a fixed-length array `[N]T` is a compile error). `max` is at least 1: `ArrayMaxSize(0)` becomes `v.empty`. `null` items count. Deviations D60, D61, D62. |
| `@ArrayMinSize` | `v.minItems(min)` | rule | Slices only. `min` is at least 1 (`ArrayMinSize(0)` is always true: a compile error). `null` items count. Deviations D60, D61, D62. |
| `@ArrayNotContains` | `v.containsNone(.{ ... })` | rule | The values of `v.containsAll`. A list that excludes every possible item (both bools, every tag of an exhaustive enum, every value of an integer type) is a compile error: use `v.empty`. Deviations D22, D58. |
| `@ArrayNotEmpty` | `v.notEmpty` | rule | One rule for strings and lists; a fixed-length array `[N]T` is a compile error. A `null` `?[]T` skips the rule. Deviation D14. |
| `@ArrayUnique` | `v.uniqueItems` or `v.uniqueBy(.key)` | rule | `ArrayUnique()` becomes `v.uniqueItems`; `ArrayUnique(o => o.key)` becomes `v.uniqueBy(.key)`, where `key` is a field of the item struct, not a function. Items or keys: `bool`, enum, integer or string. Integer, string and non-exhaustive enum items need an earlier `v.maxItems(n)` with `n <= 1000` on a slice, or `[N]T` with `N <= 1000`. Both report `validation.unique_items`. Deviations D17, D58, D61. |
| `@Allow` | unknown fields are an option of the decoder | not needed | `@Allow` only matters with `whitelist` or `forbidNonWhitelisted`. In Zig the decoder decides what an unknown JSON field does (`ignore_unknown_fields` in `std.json.ParseOptions`). In a zefir-http handler, `ctx.json(T)` refuses an unknown key unless the DTO or the server says `.ignore`. |
| `@Equals` | `v.equals(expected)` | rule | Integer, float, `bool`, enum or string fields; strings compare bytes. `v.equals("")` is a compile error (use `v.empty`). Exact at every integer width. Deviations D16, D20. |
| `@IsDefined` | a non-optional field type | not needed | Presence is the job of the field type: the decoder rejects a missing non-optional field. There is no `required` rule. |
| `@IsEmpty` | `v.empty` | rule | Strings and slices with `len == 0`; a fixed-length array `[N]T` is a compile error. class-validator also accepts `null` and `undefined`: in zefir a `null` `?T` skips every rule. Deviations D21, D62. |
| `@IsIn` | `v.oneOf(.{ ... })` | rule | Strings, enum tags or integers. An empty, duplicate, mixed or invalid-UTF-8 list is a compile error; listing every enum tag is allowed. Deviations D15, D58. |
| `@IsLatLong` | `v.latLong` | rule | Strings only; on a number field it is a compile error: use two float fields with `v.latitude` and `v.longitude`. `checkDMS` is not offered. Deviation D26. |
| `@IsLatitude` | `v.latitude` | rule | String or float field. An integer field is a compile error with a hint for scaled (E6, E7) coordinates, while class-validator accepts any JavaScript number. Deviations D16, D25, D27, D62. |
| `@IsLongitude` | `v.longitude` | rule | As `v.latitude`. Deviations D16, D25, D27, D62. |
| `@IsNotEmpty` | `v.notEmpty` | rule | Strings (bytes; a string of spaces passes, so use `v.notBlank` for text) and lists. On other field types presence is the type itself. Deviation D14. |
| `@IsNotIn` | `v.noneOf(.{ ... })` | rule | As `v.oneOf`, integers included. `""` cannot be listed (use `v.notEmpty`); excluding every tag of an exhaustive enum is a compile error. Deviations D15, D58. |
| `@IsOptional` | `?T` | not needed | A `null` optional skips its rules, `v.each` and nested validation. |
| `@NotEquals` | `v.notEquals(forbidden)` | rule | `v.notEquals("")` is a compile error (use `v.notEmpty`). On floats NaN and infinities fail with `validation.finite`. Deviations D16, D20. |
| `@Validate` | `v.custom(code, message, f)` or `validateSelf` | not needed | A constraint class becomes `v.custom(code, message, f)` for one field, or `validateSelf` with `v.fail` for checks across fields. No async constraints, no constraint arguments, no context. |
| `@ValidatorConstraint` | `v.custom(code, message, f)` | not needed | Exported together with `@Validate`. In zefir the function passed to `v.custom` is the constraint; there is no registry. |
| `@ValidateBy` | `v.custom(code, message, f)` | not needed | `ValidateBy({ name, validator })` is `v.custom`; the name becomes a code (segments `[a-z][a-z0-9_]*`, not `validation.` or `rpc.`). |
| `@ValidateIf` | `validateSelf` | not needed | Conditional rules are not there yet (TODO): write the condition in `validateSelf`. |
| `@ValidateNested` | nested structs are walked automatically | not needed | Every struct, optional, slice and array field is walked; no `@Type` from class-transformer is needed. |
| `@ValidatePromise` | none: Zig has no promises | not needed | Rules are synchronous and pure. |
| `@MaxDate` | `v.maxDate(max)` | rule | On string fields: the bound is an RFC 3339 full-date or date-time with an offset, fixed at compile time; the value must have the bound's form (otherwise `validation.date` or `validation.rfc3339`). `MaxDate(() => new Date())` ("now") is not supported: compare with the current time in the handler. Deviations D57, D60, D61. |
| `@MinDate` | `v.minDate(min)` | rule | As `v.maxDate`. Deviations D57, D60, D61. |
| `@IsDivisibleBy` | `v.divisibleBy(divisor)` | rule | Integer and float fields; the divisor is a positive integer known at compile time. `v.divisibleBy(1)` on a float field means "a whole number". Deviations D16, D18, D19. |
| `@IsNegative` | `v.negative` | rule | Signed integers and floats; on an unsigned field it is a compile error (always false). Deviations D16, D60, D61. |
| `@IsPositive` | `v.positive` | rule | Integers and floats. Deviations D16, D60. |
| `@Max` | `v.max(max)` | rule | The bound is converted to the field type at compile time; a bound outside the type or `v.max(maxInt(T))` is a compile error. zefir also adds `v.range`, `v.nonNegative` and `v.nonPositive`. Deviations D16, D58, D60, D61. |
| `@Min` | `v.min(min)` | rule | As `v.max`; `v.min(minInt(T))` is vacuous. Deviations D16, D58, D60, D61. |
| `@IsInstance` | a static field type | not needed | The type of a field is fixed at compile time. |
| `@IsNotEmptyObject` | struct fields are fixed; maps are not walked | not needed | A struct always has its fields. Containers that hide their item type (`std.HashMap` and similar) are not walked; use `v.custom` on such a field. |
| `@Contains` | `v.contains(seed)` | rule | A substring of bytes, case-sensitive; `v.contains("")` is a compile error. On a list field the compile error suggests `v.each(v.contains(...))` or `v.containsAll(.{ ... })`. Deviation D29. |
| `@IsAlpha` | `v.alpha` | rule | ASCII letters `A-Za-z` only; `IsAlpha(locale)` for other locales is out. `""` passes (combine with `v.notEmpty`). Deviation D11. |
| `@IsAlphanumeric` | `v.alphanumeric` | rule | ASCII letters and digits only; locale variants are out. `""` passes. Deviation D11. |
| `@IsAscii` | `v.ascii` | rule | `""` passes. zefir also adds `v.printableAscii` (bytes 0x20-0x7E). Deviation D11. |
| `@IsBIC` | `v.bic` | rule | Shape only: the country is not looked up; upper case only. Deviations D47, D50. |
| `@IsBase32` | `v.base32` | rule | Canonical RFC 4648; `""` passes. The Crockford option is not offered (class-validator does not expose it). Deviation D32. |
| `@IsBase58` | `v.base58` | rule | The Bitcoin alphabet, no checksum; as validator.js. |
| `@IsBase64` | `v.base64` or `v.base64Url` | rule | `IsBase64()` becomes `v.base64` (padded, canonical); `IsBase64({ urlSafe: true })` becomes `v.base64Url` (unpadded, canonical). `{ padding: false }` and `{ urlSafe: true, padding: true }` are not supported yet (TODO). Deviation D32. |
| `@IsBooleanString` | `v.booleanString` | rule | Exactly `true`, `false`, `1` or `0`, case-sensitive. On a `bool` field it is a compile error: the field is already a boolean. |
| `@IsBtcAddress` | `v.btcAddress(.any)` | rule | `.mainnet` or `.testnet` restrict the network. Checksums are verified; segwit addresses must be lower case. Deviation D52. |
| `@IsByteLength` | `v.minBytes(min)` and `v.maxBytes(max)` | rule | `IsByteLength(min, max)` becomes `.{ v.minBytes(min), v.maxBytes(max) }`, `IsByteLength(min)` becomes `v.minBytes(min)`, `IsByteLength(0, max)` becomes `v.maxBytes(max)` (`v.minBytes(0)` is a compile error). Raw bytes. Deviations D23, D60, D61. |
| `@IsCreditCard` | `v.creditCard` | rule | 12-19 ASCII digits and the Luhn check; no issuer table and no separators. class-validator does not expose `provider`. Deviation D46. |
| `@IsCurrency` | `v.custom(code, message, f)` | out | Locale-specific money formats: write `v.custom` with your own format. |
| `@IsDataURI` | `v.dataUri` | rule | RFC 2397 with the 11 IANA top-level media types; a base64 payload is checked. Deviation D41. |
| `@IsDateString` | `v.iso8601` | rule | An alias of `IsISO8601`: `strict` is always on, and `strictSeparator` is not offered. Deviations D54, D55. |
| `@IsDecimal` | `v.decimal(.{ ... })` | rule | `decimal_digits: 'a,b'` becomes `.min_decimal_digits = a, .max_decimal_digits = b`; `'a,'` sets the minimum only; `'a'` sets both to `a`; `force_decimal` becomes `.force_decimal`. `locale` is out: the decimal mark is `.`. Deviation D28. |
| `@IsEAN` | `v.ean` | rule | 8, 13 or 14 digits with the GS1 check digit; GTIN-12 fails, as in validator.js. |
| `@IsEmail` | `v.email` | rule | The validator.js options are not mapped. The last label of the domain must be a top-level domain, as `isFQDN` requires. Deviations D1, D2, D4. |
| `@IsEthereumAddress` | `v.ethereumAddress` | rule | The EIP-55 checksum is verified on mixed-case addresses. Deviation D53. |
| `@IsFQDN` | `v.fqdn(.{ ... })` | rule | The options `require_tld`, `allow_underscores`, `allow_trailing_dot` and `allow_wildcard` keep their names and defaults; `allow_numeric_tld` and `ignore_max_length` are not offered. Deviations D4, D45. |
| `@IsFirebasePushId` | `v.firebasePushId` | rule | Same as class-validator: 20 bytes of `-0-9A-Z_a-z`. |
| `@IsFullWidth` | `v.fullWidth` | rule | The character class of validator.js, kept for parity; it is not Unicode East Asian Width. Invalid UTF-8 fails with `validation.utf8`. Deviation D13. |
| `@IsHSL` | `v.hslColor` | rule | Deviation D38. |
| `@IsHalfWidth` | `v.halfWidth` | rule | As `v.fullWidth`. Deviation D13. |
| `@IsHash` | `v.hash(algorithm)` | rule | The algorithm is a `v.HashAlgorithm` tag (validator.js's 13 names); an unknown name is a compile error instead of a string. |
| `@IsHexColor` | `v.hexColor` | rule | `#` is required. Deviation D36. |
| `@IsHexadecimal` | `v.hexadecimal` | rule | An optional `0x`, `0X`, `0h` or `0H` prefix, as validator.js. |
| `@IsIBAN` | `v.iban` | rule | No country table: 2 letters, 15-34 bytes, check digits 02-98, MOD 97-10; canonical form only. `IsIBAN({ whitelist, blacklist })` is not offered. Deviations D47, D51. |
| `@IsIP` | `v.ip`, `v.ipv4`, `v.ipv6` | rule | `IsIP()` becomes `v.ip`; `IsIP(4)` or `IsIP('4')` becomes `v.ipv4`; `IsIP(6)` or `IsIP('6')` becomes `v.ipv6`. Deviation D43. |
| `@IsISBN` | `v.isbn` / `v.isbn10` / `v.isbn13` | rule | `IsISBN()` becomes `v.isbn`, `IsISBN(10)` `v.isbn10` and `IsISBN(13)` `v.isbn13`, each with its own code. Deviations D47, D48. |
| `@IsISIN` | `v.isin` | rule | Same as validator.js; the prefix is not looked up. |
| `@IsISO31661Alpha2` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list: use a Zig enum field, or `v.oneOf` with your own list. |
| `@IsISO31661Alpha3` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsISO31661Numeric` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list; `v.oneOf` accepts integers. |
| `@IsISO8601` | `v.iso8601` | rule | `strict` is always on (the calendar is always checked); `strictSeparator` is not offered. Deviations D54, D55. |
| `@IsISRC` | `v.isrc` | rule | Same as validator.js; the prefix is not looked up. |
| `@IsISSN` | `v.issn` | rule | Equals `IsISSN({ require_hyphen: true, case_sensitive: true })`; other combinations of the options are not offered. Deviations D47, D49. |
| `@IsIdentityCard` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsJSON` | `v.json` | rule | The top level must be an object or an array (validator.js's default); nesting at most `v.max_json_depth` (64) levels. Deviation D34. |
| `@IsJWT` | `v.jwt` | rule | The shape only; nothing is decoded. Deviation D33. |
| `@IsLocale` | `v.locale` | rule | RFC 5646 syntax only. Deviation D40. |
| `@IsLowercase` | `v.lowercase` | rule | ASCII letters only. Deviation D30. |
| `@IsMACAddress` | `v.macAddress(.{ ... })` | rule | `IsMACAddress()` becomes `v.macAddress(.{})` (EUI-48 or EUI-64); `{ eui: '48' }` becomes `.eui = .eui48`, `{ eui: '64' }` becomes `.eui = .eui64`; `{ no_separators: true }` (or `no_colons`) becomes `.format = .bare`. Deviation D44. |
| `@IsMagnetURI` | `v.magnetUri` | rule | Deviation D42. |
| `@IsMilitaryTime` | `v.militaryTime` | rule | `HH:MM` or `HHMM`, as class-validator's own regular expression. |
| `@IsMimeType` | `v.mimeType` | rule | The 11 IANA top-level types. Deviation D39. |
| `@IsMobilePhone` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsMongoId` | `v.mongoId` | rule | Deviation D35. |
| `@IsMultibyte` | `v.multibyte` | rule | As validator.js. |
| `@IsNumberString` | `v.numberString`, `v.digits` | rule | `IsNumberString()` becomes `v.numberString`; `IsNumberString({ no_symbols: true })` becomes `v.digits`, which passes `""` (D11); `{ locale }` is out. |
| `@IsOctal` | `v.octal` | rule | Same as validator.js. |
| `@IsPassportNumber` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsPhoneNumber` | `v.custom(code, message, f)` | out | Per-country reference data (libphonenumber). |
| `@IsPort` | `v.port` | rule | Strings only, as class-validator; for a number use a `u16` field with `v.min(1)`. Deviations D24, D62. |
| `@IsPostalCode` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsRFC3339` | `v.rfc3339` | rule | zefir also adds `v.date` (an RFC 3339 full-date, `YYYY-MM-DD`). Deviation D56. |
| `@IsRgbColor` | `v.rgbColor` | rule | Percentages are always allowed; `IsRgbColor(false)` (`includePercentValues: false`) is not offered. Deviation D37. |
| `@IsSemVer` | `v.semVer` | rule | As validator.js. |
| `@IsStrongPassword` | `v.strongPassword(.{ ... })` | rule | `minLength`, `minLowercase`, `minUppercase`, `minNumbers` and `minSymbols` become `.min_length`, `.min_lowercase`, `.min_uppercase`, `.min_numbers` and `.min_symbols`, with the same defaults. No score mode. Deviations D13, D31. |
| `@IsSurrogatePair` | `v.custom(code, message, f)` | not needed | A UTF-16 notion; for "contains an astral code point" write `v.custom`. |
| `@IsTimeZone` | `v.custom(code, message, f)` | out | Needs the tz database, which changes between versions. |
| `@IsUUID` | `v.uuid` | rule | The format only: the version and the variant are not checked. `IsUUID(version)` has no equivalent yet. Deviation D5. |
| `@IsUppercase` | `v.uppercase` | rule | ASCII letters only. Deviation D30. |
| `@IsUrl` | `v.httpUrl` | rule | `http` and `https` only; the `isURL` options are not mapped. Deviations D6, D7, D8, D9, D10, D59. |
| `@IsVariableWidth` | `v.variableWidth` | rule | As `v.fullWidth`. Deviation D13. |
| `@Length` | `v.length(min, max)` | rule | `Length(min, max)` becomes `v.length(min, max)`, `Length(min)` becomes `v.minLength(min)`, `Length(0, max)` becomes `v.maxLength(max)` (`v.length(0, n)` is a compile error). Counts code points. Deviations D12, D13, D60, D61. |
| `@Matches` | `v.custom(code, message, f)` | out | Needs a regular expression engine; the Zig standard library has none. |
| `@MaxLength` | `v.maxLength(max)` | rule | Code points. `MaxLength(0)` becomes `v.empty`. Deviations D12, D13, D60, D61. |
| `@MinLength` | `v.minLength(min)` | rule | Code points. `MinLength(0)` is always true: a compile error. zefir also adds `v.notBlank` and `v.utf8`. Deviations D12, D13, D60, D61. |
| `@NotContains` | `v.notContains(seed)` | rule | `v.notContains("")` is a compile error. Deviation D29. |
| `@IsISO4217CurrencyCode` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsTaxId` | `v.custom(code, message, f)` | out | Per-country reference data. |
| `@IsISO6391` | an enum field type or `v.oneOf(.{ ... })` | out | A reference code list. |
| `@IsArray` | a slice or array field type | not needed | `[]const T` or `[N]T`. |
| `@IsBoolean` | a `bool` field type | not needed | The decoder accepts only `true` and `false` for a `bool` field; for the strings `"true"` and `"false"` use `v.booleanString`. |
| `@IsDate` | `v.date`, `v.rfc3339` or `v.iso8601` on a string field | not needed | Zig has no `Date` type: a DTO carries the date as the string it arrived as. The predicate `v.isDate` means "a `YYYY-MM-DD` string". |
| `@IsEnum` | an enum field type | not needed | The decoder rejects unknown tags; `v.oneOf(.{ ... })` restricts a field to a subset of tags. |
| `@IsInt` | an integer field type | not needed | The type of the field is an integer type. On a float field use `v.divisibleBy(1)`. |
| `@IsNumber` | `v.finite` | rule | On float fields NaN and infinities fail (`IsNumber`'s defaults); on integer fields it is always true: a compile error. `allowNaN` and `allowInfinity`: leave `v.finite` out, but the other number rules still reject non-finite values (D16). `maxDecimalPlaces` is not offered. Deviations D16, D61. |
| `@IsObject` | a struct field type | not needed | A struct field; maps and other containers that hide their item type are not walked (use `v.custom`). |
| `@IsString` | a string field type | not needed | `[]const u8`, `[]u8` or `[:0]const u8`; `[N]u8` is an array of numbers, not a string. |

## Deviations from validator.js

Where zefir deliberately differs from validator.js 13.15.35 or class-validator
0.15.1. The numbers are stable: a deviation keeps its number in every release.
A long one takes a row for each kind of value, under its one number: D60 and
D61.

| # | Rules | zefir | validator.js or class-validator | Example (zefir / class-validator) |
| --- | --- | --- | --- | --- |
| D1 | `email` | A quoted local part is rejected. | Quoted local parts are accepted, with spaces and control characters inside the quotes. | `"a b"@example.com` and `"quoted"@example.com`: fail / pass |
| D2 | `email` | ASCII only: no UTF-8 local part (RFC 6531) and no domain in another script; an international domain arrives as `xn--` labels. | `allow_utf8_local_part` is true by default, and `isFQDN` accepts U+00A1-U+FFFF in labels. | `jösé@example.com`, `用户@example.com`, `user@例え.jp`: fail / pass |
| D4 | `email`, `fqdn` | Invalid UTF-8 fails the rule under its own code; `v.httpUrl` rejects it too (D9). | A JavaScript server decodes invalid UTF-8 to U+FFFD before validation, and `isFQDN` accepts U+FFFD in labels. | `user@ex\xffample.com`; `ex\xffample.com` with `v.fqdn(.{})`: fail / pass |
| D5 | `uuid` | 8-4-4-4-12 hex digits of any case; the version and the variant are not checked, so the Nil and Max UUIDs pass, as in the grammar of RFC 9562 and JSON Schema's `uuid`. | `isUUID()` (`IsUUID()`) requires version 1-8 at index 14 and variant `10xx` at index 19, besides Nil and Max. | `00000000-0000-0000-c000-000000000046`: passes / fails |
| D6 | `httpUrl` | The scheme is required: `http` or `https` in any case, followed by `//`. | `require_protocol` is false, `ftp` is allowed, and `http:example.com` is accepted. | `example.com`, `ftp://example.com`, `http:example.com`: fail / pass |
| D7 | `httpUrl` | A host of one label and a trailing dot are accepted. | `require_tld` rejects hosts of one label; `allow_trailing_dot` is false. | `http://localhost:8080/a?b#c`, `http://api:8080`, `https://example.com./`: pass / fail |
| D8 | `httpUrl` | Userinfo, an empty port and a port longer than 5 digits are rejected. | Userinfo is accepted (`disallow_auth` is false); an empty port is accepted; any digit string with a value from 1 to 65535 is accepted. | `https://user@example.com`, `https://example.com@evil.example`, `http://example.com:`, `http://example.com:000080`: fail / pass |
| D9 | `httpUrl` | Non-ASCII bytes are rejected anywhere in the URL (an international host arrives as `xn--` labels), and so are IPv6 zone ids; the path, query and fragment allow only printable ASCII from 0x21 to 0x7E except `"`, `<`, `>` and `\`, `%` must be followed by 2 hex digits, and there is at most one `#`. | Only whitespace, `<` and `>` are rejected anywhere in the URL; the path, query and fragment are otherwise unchecked; `isIP` accepts zone ids. | `https://münchen.de/`, `http://example.com/%zz`, `http://example.com/a#b#c`, `http://example.com/a"b`, `http://[fe80::1%25eth0]/`: fail / pass |
| D10 | `httpUrl` | The length is not limited inside the rule: add a length rule. | `max_allowed_length` is 2084 UTF-16 code units. | `http://example.com/aaa…` of 2085 bytes: passes / fails |
| D11 | `ascii`, `alphanumeric`, `alpha`, `digits` | `""` passes: these are character classes. | `isAscii`, `isAlphanumeric`, `isAlpha` and `isNumeric({ no_symbols: true })` reject `""`. | `""` with `v.ascii`: passes / fails (combine with `v.notEmpty`) |
| D12 | `minLength`, `maxLength`, `length` | Every code point counts, variation selectors U+FE0E and U+FE0F included. | `isLength` does not count a U+FE0E or U+FE0F that follows a character. | `"❤\u{FE0F}"`: 2 characters / 1 |
| D13 | `minLength`, `maxLength`, `length`, `notBlank`, `fullWidth`, `halfWidth`, `variableWidth`, `strongPassword` | Invalid UTF-8 fails with the precondition `validation.utf8` / `must be valid UTF-8`, which `.withMessage` does not change. | A JavaScript server sees U+FFFD in place of invalid bytes and counts or classifies it. | `"\xff"` with `v.fullWidth`: `validation.utf8` / passes; `"Ab1!\xff\xff\xff\xff"` with `v.strongPassword(.{})`: `validation.utf8` / passes |
| D14 | `notEmpty` | A `null` `?T` skips the rule; one rule for strings and lists. | `IsNotEmpty` fails `null` unless `@IsOptional` is present; `isNotEmpty([])` is true (lists need `ArrayNotEmpty`). | `null` on `?[]const u32`: passes / fails; `[]` with `IsNotEmpty`: fails / passes |
| D15 | `oneOf`, `noneOf` | The values are strings, enum tags or integers; an empty, duplicate, mixed or invalid-UTF-8 list is a compile error, and so is a `v.noneOf` list that contains `""` or excludes every tag of an exhaustive enum or every value of an integer type. | Any values compared with `===`; `IsIn([])` never passes, `IsNotIn([])` always passes; duplicates are accepted. | `v.oneOf(.{})`: compile error / `IsIn([])`: always fails |
| D16 | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `divisibleBy`, `equals`, `notEquals`, `latitude`, `longitude` | On a float field NaN, `+inf` and `-inf` fail the precondition `validation.finite` / `must be a finite number`, which `.withMessage` does not change. | class-validator compares JavaScript numbers: `+inf` passes `Min` and `IsPositive`, `-inf` passes `Max` and `IsNegative` (and `Max(0)`), NaN fails them; `IsDivisibleBy`, `Equals`, `IsLatitude` and `IsLongitude` reject NaN and infinities too (same result, no separate code); `NotEquals`: D20. | `+inf` with `v.min(0)` or `v.positive`: fails / passes; `-inf` with `v.negative`: fails / passes |
| D17 | `uniqueItems`, `uniqueBy` | Items, or the keys of `v.uniqueBy`, are `bool`, enum, integer or string; float, struct, optional and array items are compile errors. Integer, string and non-exhaustive enum items need an earlier `v.maxItems(n)` with `n <= 1000` on a slice, or `[N]T` with `2 <= N <= 1000`: the check sorts on the stack, without allocating, in bounded time. | `ArrayUnique` compares any items with `===` (objects by reference), at any length. | `v.uniqueItems` on a `[]const f64` field: compile error / accepted |
| D18 | `divisibleBy` | Integer fields are exact at every width. | JavaScript numbers round above 2^53. | `u64` `9007199254740993` with `v.divisibleBy(3)`: passes / fails |
| D19 | `divisibleBy` | The divisor must be a positive integer that fits the field: `v.divisibleBy(0)`, negative and fractional divisors, `v.divisibleBy(1)` on an integer field and divisors beyond the type are compile errors. | `toFloat(v) % parseInt(n)`: 1.5 acts as 1, 0.5 and 0 never pass, -5 acts as 5. | `v.divisibleBy(0.5)`: compile error / never passes |
| D20 | `equals`, `notEquals` | Integers are exact at every width; a float parameter is rounded to the field type at compile time; NaN and infinities fail with `validation.finite` (so `v.notEquals(0)` fails on them); degenerate parameters are compile errors. | `===` on doubles; `notEquals(NaN, 0)` and `notEquals(+inf, 0)` are true. | `f32` field `0.10000000149011612` with `v.equals(0.1)`: passes / fails; `u64` `9007199254740992` with `v.equals(9007199254740993)`: fails / passes; NaN with `v.notEquals(0)`: fails / passes |
| D21 | `empty` | An empty slice passes. | `isEmpty([])` is false (`IsEmpty` knows only `''`, `null` and `undefined`). | `[]` with `v.empty`: passes / fails |
| D22 | `containsAll`, `containsNone` | An empty, duplicate, mixed, float or `""` value list is a compile error, and so are optional and float items and a `v.containsNone` list that excludes every possible item (use `v.empty`); on a string field the error points to `v.contains` or `v.notContains`. | `ArrayContains` and `ArrayNotContains` with an empty list always pass; NaN matches nothing; duplicates are accepted. | `v.containsAll(.{})`: compile error / always passes |
| D23 | `minBytes`, `maxBytes` | The raw length in bytes. | `isByteLength` counts the UTF-8 length of the decoded string (U+FFFD counts 3) and throws on a lone surrogate. | `"\xff"` with `v.minBytes(2)`: fails / passes |
| D24 | `port` | A sign is rejected. | `isInt` coercion lets `+80`, `+0` and `-0` pass. | `+80`, `-0`: fail / pass |
| D25 | `latitude`, `longitude` | On a string field a comma is rejected, and `longitude` rejects leading whitespace. | class-validator builds `${v},0` and `0,${v}` for `isLatLong`, so `1,2` passes; the longitude may follow one whitespace character. | `1,2`: fails / passes; ` 45` with `v.longitude`: fails / passes |
| D26 | `latLong` | Exactly one comma, and at most one space (the byte 0x20) after it. | Everything after a second comma is ignored, and any one whitespace character may follow the comma. | `1,2,garbage`, `40.7128,\t-74.0060`: fail / pass |
| D27 | `latitude`, `longitude` | On a float field, a range check only. | class-validator turns the number into a string, so a value below 1e-6 in magnitude, written as `1e-7`, is rejected. | `1e-7`: passes / fails |
| D28 | `decimal` | `.min_decimal_digits = 0` and a maximum below the minimum are compile errors. | `decimal_digits: '0,'` accepts `1.` and `.`; `'2,1'` throws a `SyntaxError` at run time. | `v.decimal(.{ .min_decimal_digits = 0 })`: compile error / `1.` passes |
| D29 | `contains`, `notContains` | `v.contains("")` and `v.notContains("")` are compile errors; bytes are compared, so a U+FFFD seed does not match invalid bytes. | An empty seed passes only strings of at least 2 UTF-16 units; a U+FFFD seed matches decoded invalid bytes. | `v.contains("\u{FFFD}")` on `"a\xffb"`: fails / passes |
| D30 | `lowercase`, `uppercase` | Only ASCII letters are inspected. | Unicode case mapping: `str === str.toLowerCase()`. | `"Émile"` with `v.lowercase`: passes / fails; `"STRAßE"` with `v.uppercase`: passes / fails |
| D31 | `strongPassword` | The length counts code points; all minima 0, and a `min_length` below the sum of the class minima, are compile errors; no score mode. | The length counts UTF-16 units; all-zero options accept every string, `""` included. | `"Ab1!😀😀"` with the defaults: fails (6 code points) / passes (8 units) |
| D32 | `base64`, `base64Url`, `base32` | Canonical RFC 4648: non-zero padding bits fail; `v.base64Url` rejects a length of 4n + 1; `v.base32` takes only 0, 1, 3, 4 or 6 padding characters, and `""` passes. | Regular expressions only; `isBase32('')` is false. | `AB==` with `v.base64`: fails / passes; `Z` with `v.base64Url`: fails / passes; `A=======` with `v.base32`: fails / passes; `""` with `v.base32`: passes / fails |
| D33 | `jwt` | An empty header or payload, and segments that are not canonical base64url, fail. | `isBase64('')` is true, so empty segments pass. | `..`: fails / passes; `a.b.c`: fails / passes |
| D34 | `json` | Unpaired surrogate escapes, invalid UTF-8 and nesting deeper than `v.max_json_depth` (64) fail. | `JSON.parse` accepts them (V8 accepted 100,000 levels). | `["\ud800"]`: fails / passes; 65 nested arrays: fails / passes |
| D35 | `mongoId` | A `0x` or `0h` prefix fails, as in bson's `ObjectId.isValid`. | `isHexadecimal(s)` and length 24, so a prefix and 22 digits pass. | `0xaaaaaaaaaaaaaaaaaaaaaa`: fails / passes |
| D36 | `hexColor` | `#` is required. | `require_hashtag` is false by default, and class-validator offers no option. | `fff`: fails / passes |
| D37 | `rgbColor` | CSS whitespace between values is allowed; the alpha may have more than 2 decimals, and `1.00` is allowed. | The default rejects spaces; the alpha is `0?.\d\d?`, `1`, `1.0`, `0` or `0.0`. | `rgb(255, 0, 0)`: passes / fails; `rgba(0,0,0,0.004)`: passes / fails |
| D38 | `hslColor` | No trimming; only CSS whitespace (space, tab, LF, CR, FF); optional whitespace on both sides of `/`. | Collapses and trims whitespace; takes JavaScript's `\s` (NBSP, U+FEFF, …); requires whitespace after `/`. | ` hsl(120,100%,50%)`: fails / passes; `hsl(120 100% 50%/0.5)`: passes / fails |
| D39 | `mimeType` | RFC 9110 parameters on any type; the 11 IANA top-level types (`haptics` and `example` included); RFC 6838 subtypes of up to 127 bytes that start with a letter or a digit; empty parameter values and comments fail. | `charset` only on `text/*`, `boundary` and `charset` only on `multipart/*`; 9 top-level types; subtypes of up to 100 characters. | `application/json; charset=utf-8`: passes / fails; `haptics/ivs`: passes / fails; `image/.png`: fails / passes; `text/plain; charset=`: fails / passes |
| D40 | `locale` | `_` fails; the prefixes `x-` and `i-` are case-insensitive; empty subtags fail. | Accepts `en_US`; rejects `X-PRIVATE` and `I-KLINGON`; accepts `de-1---`. | `en_US`: fails / passes; `X-PRIVATE`: passes / fails; `de-1---`: fails / passes |
| D41 | `dataUri` | No whitespace and no trimming; `%` is followed by 2 hex digits; a `;base64` payload must be base64; the top-level type is one of the 11 IANA types; parameter values may contain `. _ ~ ! $ & ' * +`. | Trims the header and allows whitespace in the data; no check of `%HH` or of the payload; any `[a-z]+` type; parameter values only `[a-z0-9-]`. | `data:,%zz`: fails / passes; `data:text/plain;base64,!!!`: fails / passes; `data:foo/bar,x`: fails / passes; `data:application/pdf;name=report.pdf;base64,JVBERi0=`: passes / fails |
| D42 | `magnetUri` | The whole query must be RFC 3986 query characters with valid `%HH`; an empty parameter before `xt` is skipped. | Only the `xt` parameter is checked; an empty parameter right before `xt` fails. | `magnet:?xt=urn:btih:c12f…a88a&dn=a b`: fails / passes; `magnet:?&xt=urn:btih:c12f…a88a`: passes / fails |
| D43 | `ip`, `ipv6` | IPv6 zone ids are rejected. | A `%` followed by letters, digits and dots is accepted after every IPv6 form. | `fe80::1%eth0`: fails / passes |
| D44 | `macAddress` | Only the byte 0x20 is a space separator. | Any whitespace character separates (tab, line feed, no-break space and others). | `00\t00\t5e\t00\t53\t01`: fails / passes |
| D45 | `fqdn` | ASCII only, and at most 253 bytes (254 with an allowed trailing dot). | Labels may hold U+00A1-U+FFFF except the fullwidth forms U+FF01-U+FF5E; the total length is not checked. | `münchen.de`, a name of 254 bytes: fail / pass |
| D46 | `creditCard` | 12-19 ASCII digits and the Luhn check with any prefix, a leading 0 included; no issuer table; no separators; 8-11 digits fail. | Strips spaces and hyphens, then needs one of 7 issuer patterns. They are dated (Mir 2200-2204, 12-digit Maestro, Discover 644-649 and Troy 9792 fail), and the Mastercard pattern has no end anchor, so digit strings that start with 51-55 pass at any length. | `2200700000000009`: passes / fails; `51000008`: fails / passes; `4111 1111 1111 1111`: fails / passes |
| D47 | `isbn`, `isbn10`, `isbn13`, `issn`, `bic`, `iban` | The canonical form only, nothing is normalized: no spaces or hyphens in ISBNs, BICs and IBANs; exactly one hyphen in an ISSN (`NNNN-NNNC`); letter case as each standard writes it (upper case in BICs and IBANs, an upper-case `X` check character in ISBN-10s and ISSNs). Separators in card numbers: D46. | `isISBN` strips spaces and hyphens; `isIBAN` strips them and upper-cases; `isBIC` accepts lower case; `isISSN` makes the hyphen optional and ignores case by default. | `978-0-306-40615-7`: fails / passes; `DE89 3704 0044 0532 0130 00`: fails / passes; `deutdeff`: fails / passes |
| D48 | `isbn`, `isbn13` | An ISBN-13 starts with 978, or with 979 and a digit 1-9: EAN-13 and ISMN numbers are no ISBNs. | No prefix check. | `4006381333931` (an EAN-13): fails / passes; `9790060115615` (an ISMN): fails / passes |
| D49 | `issn` | The hyphen is required and the `X` is upper case: the printed form of ISO 3297. | The hyphen is optional and the `X` may be lower case by default; zefir equals `{ require_hyphen: true, case_sensitive: true }`. | `03178471`: fails / passes; `2434-561x`: fails / passes |
| D50 | `bic` | The shape only: the country code (bytes 5-6) is not looked up. | The country must be an ISO 3166-1 alpha-2 code or `XK`. | `DEUTXXFF`: passes / fails |
| D51 | `iban` | No country table: 2 letters, 15-34 bytes, check digits 02-98, upper-case letters and digits, MOD 97-10. Check digits 00, 01 and 99 equal 97, 98 and 02 and would give an account a second spelling, so they fail. | A regular expression per country for 80 countries (`RU`, `SD`, `YE` and others are missing); check digits 00, 01 and 99 pass. | `RU0304452522540817810538091310419`: passes / fails; `DE01370400441000000008`: fails / passes |
| D52 | `btcAddress` | Checksums are verified (Base58Check, Bech32, Bech32m); P2WSH, witness version 2 and up and testnet `n…` addresses pass; the network is a parameter. | Patterns only: 39-58 Bech32 characters after `bc1` or `tb1`, Base58 addresses that start with 1, 2, 3 or `m`, no network. | `bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5` (a wrong checksum): fails / passes; `bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3` (P2WSH): passes / fails |
| D53 | `ethereumAddress` | The EIP-55 checksum is verified when the hex digits mix cases; the `0X` prefix fails. | No checksum; `0X` passes. | `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD` (a wrong checksum): fails / passes; `0X5aaeb6053f3e94c9b9a09f33669435e7ef1beaed`: fails / passes |
| D54 | `iso8601` | Fail, although validator.js accepts them: impossible dates (there is no `strict` option); week 00, and week 53 of a 52-week year; signed years; separators other than `T`, `t` or a space (tab, LF, NBSP); a separator or a zone without a time; a time after a reduced date; mixed basic and extended week dates; `T24` without minutes, `T24:0059` and `T24:00.5`; a bare number after `T`; an offset with a dangling colon. | `isISO8601` with its default options (`IsISO8601`, `IsDateString`) accepts them all. | `2021-02-29`: fails / passes; `2020-W00`: fails / passes; `+2020-05-17`: fails / passes; `2020-05-17T`: fails / passes |
| D55 | `iso8601` | Pass, although validator.js rejects them: a lowercase `t` separator; `24:00:00`; leap seconds at the end of a month; ordinal day 360; the years 0000-0999 (against validator.js's strict mode only). | `isISO8601` rejects them. | `2020-360`: passes / fails; `2020-05-17T24:00:00`: passes / fails; `2016-12-31T23:59:60Z`: passes / fails |
| D56 | `rfc3339` | The day of the month is checked; second 60 passes only as a leap second (23:59:60 UTC on the last day of a month). | Any day 01-31 in every month; second 60 at any time. | `2021-02-29T00:00:00Z`: fails / passes; `2020-05-17T10:30:60Z`: fails / passes |
| D57 | `minDate`, `maxDate` | The bound is an RFC 3339 full-date or date-time-with-offset string fixed at compile time; the value must have the bound's form, otherwise the precondition `validation.date` or `validation.rfc3339`; a date-time without an offset fails; date-times compare exactly as UTC instants, leap seconds included; days never overflow; there is no "now". | `Date` objects (class-transformer's `new Date(value)`): the host's time zone for values without an offset, milliseconds at most, overflowing days roll over (`2020-02-30` becomes `2020-03-01`), `() => Date` for "now", `:60` cannot be parsed. | `2016-12-31T23:59:59.000001Z` with `v.maxDate("2016-12-31T23:59:59Z")`: fails / passes; `2020-02-30` with `v.minDate("2020-01-01")`: `validation.date` / passes |
| D58 | `min`, `max`, `range`, `oneOf`, `noneOf`, `uniqueItems`, `uniqueBy`, `containsAll`, `containsNone` | Integers are compared exactly in the field type at every width (`u64`, `i128`, …). | JavaScript numbers lose precision above 2^53: a decoded 9007199254740993 equals 9007199254740992. | `u64` `9007199254740992` with `v.min(9007199254740993)`: fails / passes; `9007199254740992` with `v.oneOf(.{9007199254740993})`: fails / passes; `&.{ 9007199254740992, 9007199254740993 }` with `v.uniqueItems`: passes / fails |
| D59 | `httpUrl` | The host is at most 253 bytes (254 with a trailing dot). | The host length is not checked: only its labels (up to 63 bytes) and the 2084-unit total. | `http://` + a host of 254 bytes + `/`: fails / passes |
| D60 | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `minDate`, `maxDate` | Two rules of one tuple whose bounds on the value of a number, or on a date or a date-time, let no value pass are a compile error, inside `v.each` too: `.{ v.min(10), v.max(5) }`, `v.positive` with `v.nonPositive` or `v.max(0)`, `.{ v.minDate("2021-01-01"), v.maxDate("2020-12-31") }`. Equal bounds and redundant rules are fine (`.{ v.min(5), v.max(5) }`). | Any combination of decorators is accepted; every value then fails at run time. | `.{ v.min(10), v.max(5) }`: compile error / every value fails |
| D60 | `empty`, `notEmpty`, `minItems`, `maxItems`, `minLength`, `maxLength`, `length`, `strongPassword`, `minBytes`, `maxBytes` | Two rules of one tuple whose bounds on the items of a slice, or on the code points or the bytes of a string, let no value pass are a compile error, inside `v.each` too: `v.empty` with `v.notEmpty`, `v.minItems(1)` or `v.minBytes(1)`, `.{ v.minItems(5), v.maxItems(3) }`, `.{ v.minLength(10), v.maxLength(5) }`, `v.maxLength(8)` with `v.strongPassword(.{ .min_length = 12 })`. Equal bounds and redundant rules are fine; bounds of different measures are not compared (`.{ v.minLength(10), v.maxBytes(5) }` compiles). | Any combination of decorators is accepted; every value then fails at run time. | `.{ v.minItems(5), v.maxItems(3) }`: compile error / every value fails |
| D61 | `notEmpty`, `empty`, `minItems`, `maxItems`, `uniqueItems`, `uniqueBy`, `minLength`, `maxLength`, `length`, `minBytes`, `maxBytes` | A rule that could never fail or never pass on a list or a string is a compile error: `v.notEmpty`, `v.empty`, `v.minItems` and `v.maxItems` on a fixed-length array `[N]T`; `v.minItems(0)`, `v.minLength(0)` and `v.minBytes(0)`; `v.maxItems(0)`, `v.maxLength(0)` and `v.maxBytes(0)` (use `v.empty`); `v.length(0, n)` (use `v.maxLength(n)`); `v.uniqueItems` and `v.uniqueBy` on `[0]T` or `[1]T` (always true), and on `[N]T` with more items than the item type has values, such as `[3]bool` (always false). | Accepted; the decorator is then always true or always false at run time. | `v.notEmpty` on a `[3]u32` field: compile error / `ArrayNotEmpty` on an array that always has 3 items: always passes; `v.maxItems(0)`: compile error / `ArrayMaxSize(0)`: only `[]` passes |
| D61 | `min`, `max`, `range`, `nonNegative`, `negative`, `nonPositive`, `finite`, `minDate`, `maxDate` | A rule that could never fail or never pass on a number or a date is a compile error: `v.min(minInt(T))`, `v.max(maxInt(T))` and `v.range(minInt(T), maxInt(T))`; a bound outside the field type; `v.nonNegative`, `v.negative` and `v.nonPositive` on an unsigned field; `v.finite` on an integer field; `v.minDate("0000-01-01")` and `v.maxDate("9999-12-31")` (use `v.date`) and `v.minDate` at the earliest date-time (use `v.rfc3339`). | Accepted; the decorator is then always true or always false at run time. | `v.finite` on an `i32` field: compile error / `IsNumber` on an integer: always passes |
| D62 | all | A rule on a field type it does not support is a compile error, for example `v.positive` on a string, `v.latitude` on an integer field, `v.port` on a `u16`, or `v.notEmpty` on `[N]u8` used as a string. | Decorators accept any value and fail at run time (`isPositive("5")` is false); `IsLatitude` and `IsLongitude` also accept JavaScript numbers, so an integer 45 passes. | `v.positive` on a `[]const u8` field: compile error / `IsPositive` on a string property: always fails |
| D63 | `each` | `null` items of `[]const ?T` are skipped; item rules never see `null` (use `[]const T` to forbid nulls). | `{ each: true }` validates every item, `null` included, so most decorators fail a `null` item even with `@IsOptional` on the property. | `[1, null]` with `v.each(v.positive)`: passes / fails |
| D64 | all | The first failing rule is a value's only violation, and nothing inside a value whose rules failed is visited. | All decorators of a property run, and `ValidationError.constraints` lists every failure (unless `stopAtFirstError`); nested objects are validated regardless. | `.{ v.positive, v.custom("numbers.even", "must be even", isEven) }` on `-3`: 1 violation (`validation.positive`) / 2 constraints |

See also: [the overview](README.md) · [Common](common.md) · [Numbers](numbers.md) · [Strings](strings.md) · [Formats](formats.md) · [Encodings](encodings.md) · [Identifiers](identifiers.md) · [Dates](dates.md) · [Lists](lists.md)
