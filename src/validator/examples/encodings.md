# Encodings and other formats

Rules for strings that carry encoded data or a standard format: `v.json`,
`v.jwt`, `v.base32`, `v.base58`, `v.base64` and `v.base64Url` check encodings,
`v.dataUri` and `v.magnetUri` URIs, `v.mimeType` media types, `v.locale`
language tags, `v.semVer` versions, and `v.hexColor`, `v.rgbColor` and
`v.hslColor` CSS colors. Each rule has a predicate with the same answer for
code outside `field_rules`: `v.isJson(s)`, `v.isBase64(s)`, …

> [!NOTE]
> These rules ship in v0.4.0; until then they are on the `dev` branch
> ([Installation](README.md#installation)).

```zig
const Upload = struct {
    metadata: []const u8,
    content: []const u8,
    content_type: []const u8,
    language: ?[]const u8 = null,
    tags: []const []const u8,

    pub const field_rules = .{
        .metadata = v.json,
        .content = .{ v.notEmpty, v.base64 }, // "" is valid base64: require content first
        .content_type = v.mimeType,
        .language = v.locale, // null skips the rule
        .tags = v.each(v.hexColor),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.json](#vjson)
- [v.jwt](#vjwt)
- [v.base32](#vbase32)
- [v.base58](#vbase58)
- [v.base64](#vbase64)
- [v.base64Url](#vbase64url)
- [v.dataUri](#vdatauri)
- [v.magnetUri](#vmagneturi)
- [v.mimeType](#vmimetype)
- [v.locale](#vlocale)
- [v.semVer](#vsemver)
- [v.hexColor](#vhexcolor)
- [v.rgbColor](#vrgbcolor)
- [v.hslColor](#vhslcolor)

## Common to all rules on this page

- **Field types:** a string — `[]const u8`, `[]u8`, `[:0]const u8` or `[:0]u8` —
  and `?T` and `??T` of these: `null` skips the rule. `[N]u8` is an array of
  numbers, not a string, and a list of strings needs `v.each(...)`: both are
  compile errors with that hint. Any other type is a compile error.
- Every rule is a value without parameters or placeholders (`v.json`, not
  `v.json()`), and it has no precondition: its own check decides, under its
  own code.
- Nothing is trimmed and nothing is decoded into memory. A byte of 0x80 or
  above fails every rule but `v.json`, which takes valid UTF-8 inside its
  strings, so invalid UTF-8 fails under the rule's own code.
- `""` passes the pure encodings `v.base32`, `v.base58`, `v.base64` and
  `v.base64Url` (the encoding of no bytes) and fails the other 10 rules. To
  require content, put `v.notEmpty` first: `.{ v.notEmpty, v.base64 }`.
- **Predicates:** `v.isJson(s)`, `v.isJwt(s)`, `v.isBase32(s)`, `v.isBase58(s)`,
  `v.isBase64(s)`, `v.isBase64Url(s)`, `v.isDataUri(s)`, `v.isMagnetUri(s)`,
  `v.isMimeType(s)`, `v.isLocale(s)`, `v.isSemVer(s)`, `v.isHexColor(s)`,
  `v.isRgbColor(s)` and `v.isHslColor(s)`, each `fn (s: []const u8) bool`, give
  the answer of their rule on any bytes. Use them in `validateSelf`, services
  and tests; in `field_rules` use the rule.
- The rules take time linear in the input, never backtrack and allocate
  nothing (`v.json` keeps its nesting stack in a buffer on the stack, whose
  size follows the target's cache line: 141 bytes on x86_64 and aarch64).
- Combinations that no value passes, such as `.{ v.empty, v.json }` or
  `.{ v.hexColor, v.rgbColor }`, are not compile errors.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: json expects a string, field is u32
validator: <Type>.field_rules.<field>: base64 expects a string, field is [24]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: locale expects a string, field is []const []const u8; use v.each(v.locale)
validator: <Type>.field_rules.<field>: expected a rule, got the predicate isJson; use the rule v.json
```

## v.json

A JSON object or array: RFC 8259 text whose top-level value is `{...}` or
`[...]`, nested at most `v.max_json_depth` (64) levels.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `std.json.Scanner` reads the whole string as one JSON value
  with only whitespace around it, the value is an object or an array, and no
  `[` or `{` opens a level deeper than 64, the top level included (`[]` is 1
  level). The scanner decides the grammar: strings are valid UTF-8 with
  escaped control characters and paired `\u` surrogates (`\u` takes hex
  digits in any case); whitespace is space, tab, LF and CR; there is no BOM.
  Numbers are checked by their syntax only (`1e400` passes), and duplicate
  keys pass.
- **`""`:** fails.
- **Precondition:** none; invalid UTF-8 inside a string fails as
  `validation.json`.
- **Code:** `validation.json`.
- **Default message:** `must be a valid JSON object or array`.
- **Placeholders:** none.
- **Predicate:** `v.isJson(s)`.
- **Complexity:** O(n); a buffer on the stack (141 bytes on x86_64 and
  aarch64), no recursion: a document of any depth fails at level 65.
- **Deviations:** [D34](class_validator.md#deviations-from-validatorjs)
  (unpaired surrogates, invalid UTF-8 and nesting deeper than 64 fail).

What the rule accepts is what `std.json.Scanner` of Zig 0.17 accepts: a
release of Zig that changes the scanner may change it. `v.max_json_depth`
limits a JSON text inside a string field; it is not the nesting limit of a
request body that a decoder reads.

Examples:

| Value | Result |
| --- | --- |
| `{}` | passes |
| ` [1, {"a": null}] ` | passes: whitespace around the value |
| `{"a":1,"a":2}` | passes: duplicate keys |
| `[1e400,-0.0e+0]` | passes: numbers by syntax |
| `["😀"]` | passes: a surrogate pair |
| `1`, `"text"`, `true`, `null` | `validation.json`: not an object or an array |
| `{"a":1,}`, `{'a':1}`, `[01]`, `[NaN]` | `validation.json` |
| `[1] [2]` | `validation.json`: two values |
| `["\ud800"]` | `validation.json`: an unpaired surrogate |
| `[` × 64 then `]` × 64 | passes |
| `[` × 65 then `]` × 65 | `validation.json`: 65 levels |
| `""` | `validation.json` |

## v.jwt

The shape of a JSON Web Token in JWS compact serialization: three
base64url segments separated by dots.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` splits on `.` into exactly 3 segments (header,
  payload, signature); the header and the payload are not empty; each
  segment passes `v.isBase64Url` (canonical base64url without padding). An
  empty signature passes: an Unsecured JWT (RFC 7519 §6). Only the shape is
  checked: nothing is decoded, and the claims and the signature are yours to
  verify.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.jwt`.
- **Default message:** `must be a valid JWT`.
- **Placeholders:** none.
- **Predicate:** `v.isJwt(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D33](class_validator.md#deviations-from-validatorjs)
  (empty and non-canonical segments fail).

Examples:

| Value | Result |
| --- | --- |
| `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl` | passes |
| `eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.` | passes: an empty signature |
| `e30.e30.e30` | passes: nothing is decoded |
| `e30.e30` | `validation.jwt`: 2 segments |
| `a.b.c.d.e` | `validation.jwt`: a JWE has 5 segments |
| `..`, `.e30.` | `validation.jwt`: an empty header or payload |
| `e30=.e30.e30` | `validation.jwt`: `=` is not base64url |
| `Bearer e30.e30.e30` | `validation.jwt`: nothing is trimmed |

## v.base32

RFC 4648 base32 with padding, in its canonical form.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** the length is a multiple of 8; the data is uppercase
  `A-Z` and `2-7`; it ends with 0, 1, 3, 4 or 6 `=`; and the bits that the
  padding leaves unused in the last symbol are zero (RFC 4648 §3.5). Not
  Crockford's base32, not the unpadded variant.
- **`""`:** passes: the encoding of no bytes.
- **Precondition:** none.
- **Code:** `validation.base32`.
- **Default message:** `must be valid base32`.
- **Placeholders:** none.
- **Predicate:** `v.isBase32(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D32](class_validator.md#deviations-from-validatorjs)
  (canonical form; `""` passes).

Examples:

| Value | Result |
| --- | --- |
| `MZXW6YTBOI======` | passes |
| `MY======` | passes |
| `""` | passes |
| `MZXW6YTBOI` | `validation.base32`: no padding |
| `my======` | `validation.base32`: lowercase |
| `A=======` | `validation.base32`: 7 `=` |
| `MZ======` | `validation.base32`: unused bits are not zero |

## v.base58

Bitcoin's base58 alphabet.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** every byte is in `1-9 A-H J-N P-Z a-k m-z` (no `0`, `O`,
  `I` or `l`). Every such string is the canonical encoding of some bytes, so
  nothing else is checked: no Base58Check checksum, no length. For Bitcoin
  addresses use `v.btcAddress`.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.base58`.
- **Default message:** `must be valid base58`.
- **Placeholders:** none.
- **Predicate:** `v.isBase58(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** none.

Examples:

| Value | Result |
| --- | --- |
| `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa` | passes |
| `1` | passes: one zero byte |
| `0OIl` | `validation.base58` |

## v.base64

RFC 4648 base64 with padding, in its canonical form: exactly what
`std.base64.standard.Decoder` decodes.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** the length is a multiple of 4; the data is
  `A-Z a-z 0-9 + /`; one or two `=` may end it; and the bits that the padding
  leaves unused are zero (RFC 4648 §3.5). No line breaks, no whitespace, no
  URL-safe alphabet and no missing padding.
- **`""`:** passes: the encoding of no bytes.
- **Precondition:** none.
- **Code:** `validation.base64`.
- **Default message:** `must be valid base64`.
- **Placeholders:** none.
- **Predicate:** `v.isBase64(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D32](class_validator.md#deviations-from-validatorjs)
  (non-zero padding bits fail).

Examples:

| Value | Result |
| --- | --- |
| `Zm9vYmFy` | passes |
| `Zg==` | passes |
| `""` | passes |
| `Zh==` | `validation.base64`: `Zg==` is the canonical form |
| `Zg` | `validation.base64`: no padding |
| `-_-_` | `validation.base64`: the URL-safe alphabet; use `v.base64Url` |
| `Zm9v\nYmFy` | `validation.base64`: a line break |

## v.base64Url

RFC 4648 base64url without padding, as JWT segments use it, in its
canonical form: exactly what `std.base64.url_safe_no_pad.Decoder` decodes.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** the data is `A-Z a-z 0-9 - _`, without `=`; the length is
  not 1 more than a multiple of 4; and the unused bits of the last symbol are
  zero.
- **`""`:** passes.
- **Precondition:** none.
- **Code:** `validation.base64_url`.
- **Default message:** `must be valid base64url`.
- **Placeholders:** none.
- **Predicate:** `v.isBase64Url(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D32](class_validator.md#deviations-from-validatorjs)
  (a length of 4n + 1 and non-zero padding bits fail).

Examples:

| Value | Result |
| --- | --- |
| `Zm9vYg` | passes |
| `-_-_` | passes |
| `Zg==` | `validation.base64_url`: padding |
| `Zm9vY` | `validation.base64_url`: a length of 4n + 1 |
| `Zh` | `validation.base64_url`: `Zg` is the canonical form |

## v.dataUri

An RFC 2397 data URL:
`data:[<type>/<subtype>][;<attribute>=<value>]*[;base64],<data>`.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` starts with lowercase `data:` and has a `,`; the media
  type before the first `;`, if any, passes the type check of `v.mimeType`
  without `#` and `^`; each `attribute=value` has both sides non-empty, made
  of `A-Z a-z 0-9 - . _ ~ ! $ & ' * +` or `%HH`; `;base64` (in any case) comes
  last, and then the data after the first `,` must pass `v.isBase64`;
  otherwise every byte of the data is an RFC 2396 URI character or starts a
  `%HH` escape. No whitespace; nothing is decoded.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.data_uri`.
- **Default message:** `must be a valid data URI`.
- **Placeholders:** none.
- **Predicate:** `v.isDataUri(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D41](class_validator.md#deviations-from-validatorjs)
  (no whitespace, valid `%HH`, a checked base64 payload, the 11 IANA types).

Examples:

| Value | Result |
| --- | --- |
| `data:,A%20brief%20note` | passes |
| `data:text/plain;BASE64,SGVsbG8=` | passes |
| `data:application/pdf;name=report.pdf;base64,JVBERi0=` | passes |
| `data:;base64,` | passes: the base64 of no bytes |
| `DATA:,x` | `validation.data_uri`: the scheme is lowercase |
| `data:,a b` | `validation.data_uri`: a space |
| `data:,%zz` | `validation.data_uri`: not an escape |
| `data:text/plain;base64,SGVsbG8` | `validation.data_uri`: not base64 |
| `data:foo/bar,x` | `validation.data_uri`: not an IANA type |
| `data:image/png;base64;charset=utf-8,AAAA` | `validation.data_uri`: `;base64` is not last |

## v.magnetUri

A magnet URI that names its content with an exact topic.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` starts with lowercase `magnet:?`; the rest is RFC 3986
  query characters and valid `%HH` escapes (no spaces, no `#`); and among the
  `&`-separated parameters, an `xt` or `xt.1` (in any case) has as its raw
  value, in any case, `urn:` and one of `aich`, `bitprint`, `btih`, `ed2k`,
  `ed2khash`, `kzhash`, `md5`, `sha1`, `tree:tiger`, then `:` and 32 or 40
  letters and digits, or `urn:btmh:1220` and 64 letters and digits.
  Parameters without `=` and empty ones are skipped; `xt.2` and later do not
  count.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.magnet_uri`.
- **Default message:** `must be a valid magnet URI`.
- **Placeholders:** none.
- **Predicate:** `v.isMagnetUri(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D42](class_validator.md#deviations-from-validatorjs)
  (the whole query is checked).

Examples:

| Value | Result |
| --- | --- |
| `magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a` | passes |
| `magnet:?XT=URN:BTIH:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A` | passes |
| `magnet:?&xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a` | passes: the empty parameter is skipped |
| `magnet:?` | `validation.magnet_uri`: no exact topic |
| `MAGNET:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a` | `validation.magnet_uri`: the scheme is lowercase |
| `magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=a b` | `validation.magnet_uri`: a space |

## v.mimeType

A media type as `Content-Type` carries it: `type/subtype` and parameters.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** the type is one of the 11 top-level types of the IANA
  registry — `application`, `audio`, `example`, `font`, `haptics`, `image`,
  `message`, `model`, `multipart`, `text`, `video` — in any case; the subtype
  is an RFC 6838 name of 1-127 bytes that starts with a letter or a digit and
  uses `A-Z a-z 0-9 ! # $ & - ^ _ . +`; then each parameter is optional
  spaces or tabs, `;`, optional spaces or tabs and `name=value`, the name a
  token and the value a token or a quoted string (RFC 9110). A `;` needs a
  parameter after it; no spaces around `=` and none at the end. Subtypes are
  not looked up in the registry.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.mime_type`.
- **Default message:** `must be a valid MIME type`.
- **Placeholders:** none.
- **Predicate:** `v.isMimeType(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D39](class_validator.md#deviations-from-validatorjs)
  (parameters on any type, 11 top-level types, RFC 6838 subtypes).

Examples:

| Value | Result |
| --- | --- |
| `application/json; charset=utf-8` | passes |
| `text/plain ;charset=utf-8` | passes: spaces before `;` |
| `text/plain; charset=""` | passes: an empty quoted string |
| `haptics/ivs` | passes |
| `image/png;` | `validation.mime_type`: no parameter after `;` |
| `text/plain; charset=` | `validation.mime_type`: an empty value |
| `text/plain; charset = utf-8` | `validation.mime_type`: spaces around `=` |
| `foo/bar` | `validation.mime_type`: not an IANA type |
| `image/.png` | `validation.mime_type`: a subtype starts with a letter or a digit |

## v.locale

A well-formed BCP 47 language tag (RFC 5646), checked by its syntax.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** in any case, `s` is one of the 17 irregular grandfathered
  tags (`i-klingon`, `en-GB-oed`, …); or a private-use tag, `x-` and subtags
  of 1-8 letters and digits; or a language of 2-3 or 5-8 letters, then up to
  3 extlangs of 3 letters (after a language of 2-3 letters), an optional
  script of 4 letters, an optional region of 2 letters or 3 digits, variants
  of 5-8 letters and digits or of 4 starting with a digit, extensions (a
  letter or digit other than `x` and subtags of 2-8), and an optional
  private-use part. Only `-` separates subtags. A language of 4 letters
  fails, as in validator.js. Nothing is looked up in the registry: `english`
  passes.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.locale`.
- **Default message:** `must be a valid locale`.
- **Placeholders:** none.
- **Predicate:** `v.isLocale(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D40](class_validator.md#deviations-from-validatorjs)
  (`_` fails; `x-` and `i-` in any case; empty subtags fail).

Examples:

| Value | Result |
| --- | --- |
| `en-US` | passes |
| `zh-Hant-TW` | passes |
| `de-CH-1901` | passes |
| `X-PRIVATE` | passes |
| `en_US` | `validation.locale`: `_` |
| `abcd` | `validation.locale`: a 4-letter language |
| `de-1---` | `validation.locale`: empty subtags |

## v.semVer

A version by the grammar of Semantic Versioning 2.0.0.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `MAJOR.MINOR.PATCH` are three numbers without leading
  zeros, of any size; then an optional pre-release after `-` and optional
  build metadata after `+`, each made of non-empty dot-separated identifiers
  of `0-9 A-Z a-z -`; in a pre-release an identifier of digits only has no
  leading zero. No `v` prefix and no whitespace.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.sem_ver`.
- **Default message:** `must be a valid semantic version`.
- **Placeholders:** none.
- **Predicate:** `v.isSemVer(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** none.

Examples:

| Value | Result |
| --- | --- |
| `1.2.3` | passes |
| `1.0.0-alpha.1+build.5` | passes |
| `1.0.0+001` | passes: leading zeros in build metadata |
| `99999999999999999999999.0.0` | passes: numbers of any size |
| `v1.2.3` | `validation.sem_ver` |
| `1.2` | `validation.sem_ver` |
| `1.2.3-01` | `validation.sem_ver`: a leading zero |
| `1.0.0+a+b` | `validation.sem_ver` |

## v.hexColor

A CSS hex color: `#` and 3, 4, 6 or 8 hex digits.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s[0]` is `#` and the rest is 3, 4, 6 or 8 hex digits in
  any case. The `#` is required, so words such as `cafe` are not colors.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.hex_color`.
- **Default message:** `must be a valid hex color`.
- **Placeholders:** none.
- **Predicate:** `v.isHexColor(s)`.
- **Complexity:** O(1) after the length check; allocates nothing.
- **Deviations:** [D36](class_validator.md#deviations-from-validatorjs)
  (`#` is required).

Examples:

| Value | Result |
| --- | --- |
| `#fff` | passes |
| `#FF000080` | passes |
| `fff` | `validation.hex_color`: no `#` |
| `#fffff` | `validation.hex_color`: 5 digits |

## v.rgbColor

A CSS `rgb()` or `rgba()` color in the legacy comma syntax.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` is `rgb(R, G, B)` or `rgba(R, G, B, A)` with the name
  in lowercase; R, G and B are all integers from 0 to 255 or all percentages
  from 0% to 100%, without leading zeros; A is `0`, `1` or a decimal from 0 to
  1 (`0.5`, `.5`, `1.00`); CSS whitespace (space, tab, LF, CR, FF) may surround
  each value. `rgb` takes no alpha and `rgba` needs one. The space-separated
  syntax fails (`v.hslColor` takes it).
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.rgb_color`.
- **Default message:** `must be a valid RGB color`.
- **Placeholders:** none.
- **Predicate:** `v.isRgbColor(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D37](class_validator.md#deviations-from-validatorjs)
  (whitespace between values; alpha with any number of decimals).

Examples:

| Value | Result |
| --- | --- |
| `rgb(255, 0, 0)` | passes |
| `rgb(100%,0%,50%)` | passes |
| `rgba(0, 0, 0, 0.004)` | passes |
| `rgb(256,0,0)` | `validation.rgb_color`: above 255 |
| `rgb(255,0%,0)` | `validation.rgb_color`: integers and percentages mixed |
| `rgb(255 0 0)` | `validation.rgb_color`: the space-separated syntax |
| `rgba(255,0,0)` | `validation.rgb_color`: no alpha |
| `RGB(255,0,0)` | `validation.rgb_color`: the name is lowercase |

## v.hslColor

A CSS `hsl()` or `hsla()` color, in the legacy or the modern syntax.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` is `hsl(` or `hsla(` in any case, then either
  `H, S%, L%` with an optional `, A`, or `H S% L%` with an optional `/ A`, then
  `)`. H is a number with an optional unit `deg`, `grad`, `rad` or `turn`; S
  and L are numbers with `%`; A is a number with an optional `%`; a number is
  `[+-](digits[.digits] | .digits)[(e | E)[+-]digits]`. Either name takes an alpha
  or none. Ranges are not checked: CSS clamps them. CSS whitespace (space,
  tab, LF, CR, FF) inside the parentheses only.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.hsl_color`.
- **Default message:** `must be a valid HSL color`.
- **Placeholders:** none.
- **Predicate:** `v.isHslColor(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D38](class_validator.md#deviations-from-validatorjs)
  (no trimming; CSS whitespace only; optional spaces around `/`).

Examples:

| Value | Result |
| --- | --- |
| `hsl(120, 100%, 50%)` | passes |
| `hsl(120deg 100% 50% / 0.5)` | passes |
| `HSLA(120 100% 50%)` | passes: any case, no alpha |
| `hsl(-120, 200%, -5%)` | passes: ranges are not checked |
| ` hsl(120,100%,50%)` | `validation.hsl_color`: nothing is trimmed |
| `hsl(120,100,50%)` | `validation.hsl_color`: no `%` |
| `hsl(120 100% 50% 0.5)` | `validation.hsl_color`: no `/` before the alpha |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
