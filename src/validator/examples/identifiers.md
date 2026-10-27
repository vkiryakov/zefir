# Identifiers

Rules for strings that hold an identifier defined by a standard or a protocol:
`v.uuid`, `v.mongoId`, `v.firebasePushId` and `v.hash` for IDs and digests;
`v.creditCard`, `v.isin`, `v.bic` and `v.iban` for payments and banking;
`v.isbn`, `v.isbn10`, `v.isbn13`, `v.issn`, `v.ean` and `v.isrc` for books,
periodicals, products and recordings; `v.btcAddress` and `v.ethereumAddress`
for crypto addresses. Each rule has a predicate with the same verdict,
`v.isUuid` … `v.isEthereumAddress`, for code outside `field_rules`.

```zig
const v = @import("validator");

const Payout = struct {
    request_id: []const u8,
    iban: []const u8,
    bic: ?[]const u8 = null,
    wallet: ?[]const u8 = null,
    receipt_digest: []const u8,
    isbns: []const []const u8,

    pub const field_rules = .{
        .request_id = v.uuid,
        .iban = v.iban, // upper case, no spaces: normalize before the check
        .bic = v.bic, // null skips the rule
        .wallet = v.btcAddress(.mainnet),
        .receipt_digest = v.hash(.sha256),
        .isbns = v.each(v.isbn),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [Predicates](#predicates)
- [v.uuid](#vuuid)
- [v.mongoId](#vmongoid)
- [v.firebasePushId](#vfirebasepushid)
- [v.hash(algorithm)](#vhashalgorithm)
- [v.creditCard](#vcreditcard)
- [v.isbn](#visbn)
- [v.isbn10](#visbn10)
- [v.isbn13](#visbn13)
- [v.issn](#vissn)
- [v.ean](#vean)
- [v.isin](#visin)
- [v.isrc](#visrc)
- [v.bic](#vbic)
- [v.iban](#viban)
- [v.btcAddress(network)](#vbtcaddressnetwork)
- [v.ethereumAddress](#vethereumaddress)

## Common to all rules on this page

- **Field types:** a string: `[]const u8`, `[]u8`, `[:0]const u8`, `[:0]u8` or
  another slice of `u8` that is neither `volatile` nor `allowzero`; `?T` and
  `??T` of these, where `null` skips the rule; and the items of a list through
  `v.each`. `[N]u8` is an array of
  numbers, not a string, and a list of strings needs `v.each`: both are
  compile errors with a hint.
- **ASCII only, no precondition.** The rules read bytes, not code points: a
  byte outside the rule's alphabet, invalid UTF-8 included, fails with the
  rule's own code, so `.withMessage` changes that message too.
- **`""` fails every rule:** it is no identifier. To allow "no value", make the
  field optional.
- **Canonical form only.** Nothing is trimmed, case-folded or normalized:
  `978-0-306-40615-7`, `DE89 3704 0044 0532 0130 00`, `deutdeff`, `03178471` and
  `2434-561x` fail. Remove spaces and hyphens and fix the case before the check
  if your input allows them
  ([D47](class_validator.md#deviations-from-validatorjs)).
- **No reference tables.** No rule looks a country, an issuer or a bank up: a
  value of the right shape with a valid checksum passes even with a country that
  does not exist (`XX46370400440532013000` for `v.iban`, `DEUTXXFF` for
  `v.bic`). The rules check the syntax of an identifier, not that the account,
  the card or the bank exists.
- **Built-in data sets** are part of the rules' behaviour, and a change to one
  is a rule change ([Compatibility](README.md#compatibility)):
  - the 13 algorithms and 7 digest lengths of `v.hash`, from validator.js; a new
    tag would also break an exhaustive `switch` on `v.HashAlgorithm`;
  - the 64-character alphabet of `v.firebasePushId`;
  - the constants of `v.btcAddress`: the version bytes 0x00, 0x05, 0x6f and
    0xc4, the prefixes `bc` and `tb`, the Bech32 and Bech32m checksum constants
    and the 5 generators of their checksum, and the Base58 and Bech32 alphabets
    (58 and 32 characters);
  - the ISBN-13 prefixes of `v.isbn` and `v.isbn13`: 978, and 979 followed by
    1-9;
  - the constants of `v.iban`: 15 to 34 bytes, check digits 02 to 98, MOD
    97-10.
- **Complexity:** each rule checks the length first, then makes one or two
  passes over at most 128 bytes (`v.hash(.sha512)`), and allocates nothing. The
  most expensive are `v.btcAddress` (a Bech32 checksum over at most 90 symbols,
  or a Base58 decoding into 25 bytes and two SHA-256 hashes) and
  `v.ethereumAddress` (a Keccak-256 hash of 40 bytes, for mixed case only).

## Predicates

Each rule has a predicate that gives the same verdict, for `validateSelf`, a
service layer or tests: `v.isUuid(s)`, `v.isMongoId(s)`, `v.isFirebasePushId(s)`,
`v.isHash(s, algorithm)`, `v.isCreditCard(s)`, `v.isIsbn(s)`, `v.isIsbn10(s)`,
`v.isIsbn13(s)`, `v.isIssn(s)`, `v.isEan(s)`, `v.isIsin(s)`, `v.isIsrc(s)`,
`v.isBic(s)`, `v.isIban(s)`, `v.isBtcAddress(s, network)` and
`v.isEthereumAddress(s)`. Each takes a `[]const u8` and returns a `bool`; the
algorithm of `v.isHash` and the network of `v.isBtcAddress` may be known at run
time only. A predicate takes any input, invalid UTF-8 included, never panics and
allocates nothing. In `field_rules` use the rule: a predicate there is a compile
error that names the rule.

```zig
const Withdrawal = struct {
    network: v.BtcNetwork, // chosen by the user
    address: []const u8,

    pub fn validateSelf(self: *const Withdrawal) ?v.Violation {
        if (!v.isBtcAddress(self.address, self.network))
            return v.fail(@This(), .address, "withdrawals.bad_address", "must be a Bitcoin address of the chosen network");
        return null;
    }
};
```

## v.uuid

A UUID in the string form of RFC 9562.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 36 bytes, `-` at indexes 8, 13, 18 and 23,
  and hex digits (`0-9`, `a-f`, `A-F`, in any mix of case) elsewhere. The
  version and the variant are not checked, so the Nil (all `0`) and Max (all
  `f`) UUIDs pass. No braces, no `urn:uuid:` prefix, no 32-digit form.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.uuid`.
- **Default message:** `must be a valid UUID`.
- **Placeholders:** none.
- **Predicate:** `v.isUuid(s)`.
- **Complexity:** O(1): at most 36 bytes are read; allocates nothing.
- **Deviations:** [D5](class_validator.md#deviations-from-validatorjs) (the
  version and the variant are not checked).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: uuid expects a string, field is u128
validator: <Type>.field_rules.<field>: uuid expects a string, field is [16]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: uuid expects a string, field is []const []const u8; use v.each(v.uuid)
```

Examples:

| Value | Result |
| --- | --- |
| `f81d4fae-7dec-11d0-a765-00a0c91e6bf6` | passes |
| `F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6` | passes: any case |
| `00000000-0000-0000-0000-000000000000` | passes: the Nil UUID |
| `00000000-0000-0000-c000-000000000046` | passes: the variant is not checked |
| `f81d4fae7dec11d0a76500a0c91e6bf6` | `validation.uuid`: no hyphens |
| `{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}` | `validation.uuid` |
| `""` | `validation.uuid` |

## v.mongoId

A MongoDB ObjectId as text.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is 24 hex digits of any case, as bson's
  `ObjectId.isValid` takes a string. No `0x` or `0h` prefix.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.mongo_id`.
- **Default message:** `must be a valid MongoDB ObjectId`.
- **Placeholders:** none.
- **Predicate:** `v.isMongoId(s)`.
- **Complexity:** O(1): at most 24 bytes are read; allocates nothing.
- **Deviations:** [D35](class_validator.md#deviations-from-validatorjs) (a `0x`
  or `0h` prefix fails).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: mongo_id expects a string, field is u96
validator: <Type>.field_rules.<field>: mongo_id expects a string, field is [12]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: mongo_id expects a string, field is []const []const u8; use v.each(v.mongoId)
```

Examples:

| Value | Result |
| --- | --- |
| `507f1f77bcf86cd799439011` | passes |
| `507F1F77BCF86CD799439011` | passes: any case |
| `507f1f77bcf86cd79943901` | `validation.mongo_id`: 23 digits |
| `0xaaaaaaaaaaaaaaaaaaaaaa` | `validation.mongo_id`: a prefix and 22 digits |

## v.firebasePushId

A Firebase push ID, the key that Firebase's `push()` generates.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is 20 bytes of `-`, `0-9`, `A-Z`, `_` and `a-z`.
  The timestamp in its first 8 characters is not decoded.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.firebase_push_id`.
- **Default message:** `must be a valid Firebase push ID`.
- **Placeholders:** none.
- **Predicate:** `v.isFirebasePushId(s)`.
- **Complexity:** O(1): at most 20 bytes are read; allocates nothing.
- **Deviations:** none.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: firebase_push_id expects a string, field is u64
validator: <Type>.field_rules.<field>: firebase_push_id expects a string, field is [20]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: firebase_push_id expects a string, field is []const []const u8; use v.each(v.firebasePushId)
```

Examples:

| Value | Result |
| --- | --- |
| `-JhLeOlGIEjaIOFHR0xd` | passes |
| `--------------------` | passes |
| `-JhLeOlGIEjaIOFHR0x` | `validation.firebase_push_id`: 19 bytes |
| `-JhLeOlGIEjaIOFHR0x.` | `validation.firebase_push_id`: `.` is not in the alphabet |

## v.hash(algorithm)

A hex digest of a hash algorithm.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** `algorithm`, a tag of `v.HashAlgorithm` known at compile
  time: `.md4`, `.md5`, `.sha1`, `.sha256`, `.sha384`, `.sha512`, `.ripemd128`,
  `.ripemd160`, `.tiger128`, `.tiger160`, `.tiger192`, `.crc32` or `.crc32b`.
- **Passes when:** the string has exactly the number of hex digits of a digest
  of the algorithm, in any case: 8 for `crc32` and `crc32b`; 32 for `md4`,
  `md5`, `ripemd128` and `tiger128`; 40 for `sha1`, `ripemd160` and `tiger160`;
  48 for `tiger192`; 64 for `sha256`; 96 for `sha384`; 128 for `sha512`. No `0x`
  prefix. Nothing is hashed: digests of the same length, such as md4 and md5,
  look alike.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.hash`.
- **Default message:** `must be a valid {algorithm} hash`.
- **Placeholders:** `{algorithm}`: the tag's name, such as `sha256`.
- **Predicate:** `v.isHash(s, algorithm)`; the algorithm may be known at run
  time only.
- **Complexity:** O(1): at most 128 bytes are read, for `.sha512`; allocates
  nothing.
- **Deviations:** none. The 13 algorithms and their lengths are those of
  validator.js; a later release may add tags, which breaks an exhaustive
  `switch` on `v.HashAlgorithm`.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: hash expects a string, field is u256
validator: <Type>.field_rules.<field>: hash expects a string, field is [32]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: hash expects a string, field is []const []const u8; use v.each(v.hash(.sha256))
validator: <Type>.field_rules.<field>: hash must be called, e.g. v.hash(.sha256)
validator: <Type>.field_rules.<field>: expected a rule, got the predicate isHash; use the rule v.hash(.sha256)
```

Errors from Zig itself: `v.hash(.sha3_256)` gives
`enum 'identifiers.HashAlgorithm' has no member named 'sha3_256'`, and
`v.hash("sha256")`, a string as in class-validator, gives
`expected type 'identifiers.HashAlgorithm', found '*const [6:0]u8'`.

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.hash(.sha256)` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | passes |
| `v.hash(.md5)` | `D41D8CD98F00B204E9800998ECF8427E` | passes: any case |
| `v.hash(.sha256)` | `d41d8cd98f00b204e9800998ecf8427e` | `validation.hash`: `must be a valid sha256 hash` |
| `v.hash(.sha256)` | `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=` | `validation.hash`: base64, not hex |
| `v.hash(.crc32b).withMessage("bad {algorithm} checksum")` | `xyz` | `validation.hash` / `bad crc32b checksum` |

## v.creditCard

A payment card number.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is 12 to 19 ASCII digits and its Luhn check digit
  (ISO/IEC 7812-1) holds. There is no table of issuers, so any prefix passes, a
  leading 0 included. Spaces and hyphens fail.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.credit_card`.
- **Default message:** `must be a valid credit card number`.
- **Placeholders:** none.
- **Predicate:** `v.isCreditCard(s)`.
- **Complexity:** O(1): at most 19 bytes are read; allocates nothing.
- **Deviations:** [D46](class_validator.md#deviations-from-validatorjs) (no
  issuer table, 12-19 digits, no separators).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: credit_card expects a string, field is u64
validator: <Type>.field_rules.<field>: credit_card expects a string, field is [16]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: credit_card expects a string, field is []const []const u8; use v.each(v.creditCard)
```

Examples:

| Value | Result |
| --- | --- |
| `4111111111111111` | passes |
| `2200700000000009` | passes: Mir, which validator.js rejects |
| `675900000000` | passes: 12 digits |
| `4111111111111112` | `validation.credit_card`: the check digit is wrong |
| `4111 1111 1111 1111` | `validation.credit_card`: spaces |
| `51000008` | `validation.credit_card`: 8 digits |

## v.isbn

An ISBN-10 or an ISBN-13, as `v.isbn10` and `v.isbn13` define them.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** `v.isbn10` or `v.isbn13` passes the string.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.isbn`.
- **Default message:** `must be a valid ISBN`.
- **Placeholders:** none.
- **Predicate:** `v.isIsbn(s)`.
- **Complexity:** O(1): at most 13 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs) (no
  hyphens or spaces), [D48](class_validator.md#deviations-from-validatorjs)
  (the ISBN-13 prefix).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: isbn expects a string, field is u64
validator: <Type>.field_rules.<field>: isbn expects a string, field is [13]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: isbn expects a string, field is []const []const u8; use v.each(v.isbn)
```

Examples:

| Value | Result |
| --- | --- |
| `9780306406157` | passes: an ISBN-13 |
| `080442957X` | passes: an ISBN-10 |
| `978-0-306-40615-7` | `validation.isbn`: hyphens |
| `4006381333931` | `validation.isbn`: an EAN-13, not an ISBN |

## v.isbn10

An ISBN-10.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is nine digits and a check character, a digit or
  an upper-case `X` for 10, and the sum of each value times its position (1 to
  10) is a multiple of 11. `X` anywhere else fails; no hyphens or spaces.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.isbn10`.
- **Default message:** `must be a valid ISBN-10`.
- **Placeholders:** none.
- **Predicate:** `v.isIsbn10(s)`.
- **Complexity:** O(1): at most 10 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs) (no
  hyphens or spaces, an upper-case `X`).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: isbn10 expects a string, field is u64
validator: <Type>.field_rules.<field>: isbn10 expects a string, field is [10]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: isbn10 expects a string, field is []const []const u8; use v.each(v.isbn10)
```

Examples:

| Value | Result |
| --- | --- |
| `0306406152` | passes |
| `080442957X` | passes |
| `080442957x` | `validation.isbn10`: a lower-case `x` |
| `9780306406157` | `validation.isbn10`: an ISBN-13 |

## v.isbn13

An ISBN-13.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is 13 digits with the GS1 check digit (weights 1
  and 3, alternating from the left), starting with 978, or with 979 and a digit
  other than 0 (979-0 is the range of ISMN, the numbers of printed music). No
  hyphens or spaces.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.isbn13`.
- **Default message:** `must be a valid ISBN-13`.
- **Placeholders:** none.
- **Predicate:** `v.isIsbn13(s)`.
- **Complexity:** O(1): at most 13 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs) (no
  hyphens or spaces), [D48](class_validator.md#deviations-from-validatorjs)
  (the prefix).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: isbn13 expects a string, field is u64
validator: <Type>.field_rules.<field>: isbn13 expects a string, field is [13]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: isbn13 expects a string, field is []const []const u8; use v.each(v.isbn13)
```

Examples:

| Value | Result |
| --- | --- |
| `9780306406157` | passes |
| `9791090636071` | passes |
| `9790060115615` | `validation.isbn13`: an ISMN |
| `0306406152` | `validation.isbn13`: an ISBN-10 |

## v.issn

An ISSN in its printed form `NNNN-NNNC` (ISO 3297).

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 9 bytes: four digits, a hyphen, three digits
  and a check character, a digit or an upper-case `X` for 10; the eight values,
  weighted 8 down to 1, sum to a multiple of 11.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.issn`.
- **Default message:** `must be a valid ISSN`.
- **Placeholders:** none.
- **Predicate:** `v.isIssn(s)`.
- **Complexity:** O(1): at most 9 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs),
  [D49](class_validator.md#deviations-from-validatorjs) (the hyphen is required,
  the `X` is upper case).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: issn expects a string, field is u32
validator: <Type>.field_rules.<field>: issn expects a string, field is [9]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: issn expects a string, field is []const []const u8; use v.each(v.issn)
```

Examples:

| Value | Result |
| --- | --- |
| `0317-8471` | passes |
| `2434-561X` | passes |
| `03178471` | `validation.issn`: no hyphen |
| `2434-561x` | `validation.issn`: a lower-case `x` |

## v.ean

An EAN-8, EAN-13 or GTIN-14 barcode number.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is 8, 13 or 14 digits with the GS1 check digit:
  from the right, the check digit has weight 1, then 3, 1, 3, …, and the sum is
  a multiple of 10. A 12-digit UPC-A (GTIN-12) fails, as in validator.js: write
  it as an EAN-13 with a leading 0.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.ean`.
- **Default message:** `must be a valid EAN`.
- **Placeholders:** none.
- **Predicate:** `v.isEan(s)`.
- **Complexity:** O(1): at most 14 bytes are read; allocates nothing.
- **Deviations:** none.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: ean expects a string, field is u64
validator: <Type>.field_rules.<field>: ean expects a string, field is [13]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: ean expects a string, field is []const []const u8; use v.each(v.ean)
```

Examples:

| Value | Result |
| --- | --- |
| `4006381333931` | passes: EAN-13 |
| `73513537` | passes: EAN-8 |
| `0036000291452` | passes: a UPC-A written as EAN-13 |
| `036000291452` | `validation.ean`: 12 digits |
| `4006381333932` | `validation.ean`: the check digit is wrong |

## v.isin

An ISIN, the identifier of a security (ISO 6166).

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 12 bytes: two upper-case letters, nine
  upper-case letters or digits and a check digit. With each letter written as
  its two-digit value (`A` = 10 … `Z` = 35), the digits pass the Luhn check. The
  prefix is not looked up: `XS` passes.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.isin`.
- **Default message:** `must be a valid ISIN`.
- **Placeholders:** none.
- **Predicate:** `v.isIsin(s)`.
- **Complexity:** O(1): at most 12 bytes are read; allocates nothing.
- **Deviations:** none.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: isin expects a string, field is u64
validator: <Type>.field_rules.<field>: isin expects a string, field is [12]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: isin expects a string, field is []const []const u8; use v.each(v.isin)
```

Examples:

| Value | Result |
| --- | --- |
| `US0378331005` | passes |
| `AU0000XVGZA3` | passes: letters inside |
| `US0378331006` | `validation.isin`: the check digit is wrong |
| `us0378331005` | `validation.isin`: lower case |

## v.isrc

An ISRC, the code of a sound or video recording (ISO 3901).

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 12 bytes: two upper-case letters for the
  country, three upper-case letters or digits for the registrant, then seven
  digits for the year and the recording. The country is not looked up (`QM`
  passes); an ISRC has no check digit. The printed form with hyphens fails.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.isrc`.
- **Default message:** `must be a valid ISRC`.
- **Placeholders:** none.
- **Predicate:** `v.isIsrc(s)`.
- **Complexity:** O(1): at most 12 bytes are read; allocates nothing.
- **Deviations:** none.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: isrc expects a string, field is u64
validator: <Type>.field_rules.<field>: isrc expects a string, field is [12]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: isrc expects a string, field is []const []const u8; use v.each(v.isrc)
```

Examples:

| Value | Result |
| --- | --- |
| `USRC17607839` | passes |
| `QMDA71418090` | passes |
| `US-RC1-76-07839` | `validation.isrc`: hyphens |
| `USRC1X607839` | `validation.isrc`: a letter in the year |

## v.bic

A BIC, the code of a bank (ISO 9362).

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 8 or 11 bytes: four upper-case letters for the
  institution, two for the country, two upper-case letters or digits for the
  location and, in 11 bytes, three more for the branch. The country is not looked
  up. Upper case only, no separators.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.bic`.
- **Default message:** `must be a valid BIC`.
- **Placeholders:** none.
- **Predicate:** `v.isBic(s)`.
- **Complexity:** O(1): at most 11 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs) (upper
  case only), [D50](class_validator.md#deviations-from-validatorjs) (the country
  is not looked up).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: bic expects a string, field is u64
validator: <Type>.field_rules.<field>: bic expects a string, field is [11]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: bic expects a string, field is []const []const u8; use v.each(v.bic)
```

Examples:

| Value | Result |
| --- | --- |
| `DEUTDEFF` | passes |
| `DEUTDEFF500` | passes: with a branch |
| `DEUTXXFF` | passes: the country is not looked up |
| `deutdeff` | `validation.bic`: lower case |
| `DEU1DEFF` | `validation.bic`: a digit in the institution |
| `DEUTDEFF500X` | `validation.bic`: 12 bytes |

## v.iban

An IBAN in its electronic form (ISO 13616).

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string has 15 to 34 bytes: two upper-case letters for the
  country, two check digits from 02 to 98, then upper-case letters and digits;
  and with the first four bytes moved to the end and each letter written as its
  value (`A` = 10 … `Z` = 35), the number leaves 1 modulo 97 (ISO 7064 MOD
  97-10). Check digits 00, 01 and 99 fail: they equal 97, 98 and 02 and would
  give an account a second spelling. The country is not looked up and the length
  is not checked per country. Upper case only, no spaces.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.iban`.
- **Default message:** `must be a valid IBAN`.
- **Placeholders:** none.
- **Predicate:** `v.isIban(s)`.
- **Complexity:** O(1): at most 34 bytes are read; allocates nothing.
- **Deviations:** [D47](class_validator.md#deviations-from-validatorjs) (upper
  case, no spaces), [D51](class_validator.md#deviations-from-validatorjs) (no
  country table, check digits 02-98).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: iban expects a string, field is u128
validator: <Type>.field_rules.<field>: iban expects a string, field is [34]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: iban expects a string, field is []const []const u8; use v.each(v.iban)
```

Examples:

| Value | Result |
| --- | --- |
| `DE89370400440532013000` | passes |
| `NO9386011117947` | passes: 15 bytes |
| `RU0304452522540817810538091310419` | passes: no country table |
| `DE89 3704 0044 0532 0130 00` | `validation.iban`: spaces |
| `DE01370400441000000008` | `validation.iban`: check digits 01 |
| `DE89370400440532013001` | `validation.iban`: MOD 97-10 fails |

## v.btcAddress(network)

A Bitcoin address of a network, with its checksum verified.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** `network`, a tag of `v.BtcNetwork` known at compile time:
  `.mainnet`, `.testnet` or `.any` (mainnet or testnet). `.testnet` also takes
  the Base58 addresses of signet and regtest, which share its version bytes, and
  signet's segwit addresses, which share its `tb1` prefix; regtest's `bcrt1`
  addresses pass no network.
- **Passes when:** the string is one of two forms:
  - a segwit address (BIP-173, BIP-350) in lower case: 10 to 90 bytes, `bc1` on
    mainnet or `tb1` on testnet, then Bech32 symbols: the witness version 0 to
    16, the witness program and a checksum, Bech32 for version 0 and Bech32m
    for the others. The program decodes to 2 to 40 bytes, 20 or 32 for version
    0, with at most 4 padding bits, all zero. Upper case fails.
  - a Base58Check address (P2PKH, P2SH): 1 to 35 bytes of the Base58 alphabet
    that decode to exactly 25 bytes, whose last 4 bytes are the first 4 of
    SHA-256(SHA-256(the first 21)), and whose first byte, the version, is 0x00
    or 0x05 on mainnet and 0x6f or 0xc4 on testnet.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.btc_address`.
- **Default message:** `must be a valid Bitcoin address`; for `.testnet`
  `must be a valid Bitcoin testnet address`.
- **Placeholders:** `{network}`: the tag's name, `mainnet`, `testnet` or `any`.
- **Predicate:** `v.isBtcAddress(s, network)`; the network may be known at run
  time only.
- **Complexity:** O(1): a segwit address, at most 90 bytes, takes one Bech32
  checksum; a Base58 address, at most 35 bytes, is decoded into 25 bytes and
  hashed twice with SHA-256. Allocates nothing.
- **Deviations:** [D52](class_validator.md#deviations-from-validatorjs)
  (checksums are verified, the network is a parameter).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: btc_address expects a string, field is u160
validator: <Type>.field_rules.<field>: btc_address expects a string, field is [25]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: btc_address expects a string, field is []const []const u8; use v.each(v.btcAddress(.mainnet))
validator: <Type>.field_rules.<field>: btcAddress must be called, e.g. v.btcAddress(.mainnet)
validator: <Type>.field_rules.<field>: expected a rule, got the predicate isBtcAddress; use the rule v.btcAddress(.mainnet)
```

Errors from Zig itself: `v.btcAddress(.regtest)` gives
`enum 'identifiers.BtcNetwork' has no member named 'regtest'`.

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.btcAddress(.mainnet)` | `bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4` | passes: P2WPKH |
| `v.btcAddress(.mainnet)` | `bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0` | passes: Taproot, Bech32m |
| `v.btcAddress(.mainnet)` | `1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2` | passes: P2PKH |
| `v.btcAddress(.mainnet)` | `tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx` | `validation.btc_address`: a testnet address |
| `v.btcAddress(.testnet)` | `2NC2hEhe28ULKAJkW5MjZ3jtTMJdvXmByvK` | passes: P2SH |
| `v.btcAddress(.testnet)` | `3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy` | `validation.btc_address`: `must be a valid Bitcoin testnet address` |
| `v.btcAddress(.any)` | `bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5` | `validation.btc_address`: the checksum is wrong |
| `v.btcAddress(.any)` | `BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4` | `validation.btc_address`: upper case |

## v.ethereumAddress

An Ethereum address.

- **Field types:** a string; `?T` and `??T` of these.
- **Parameters:** none.
- **Passes when:** the string is `0x` (with a lower-case `x`) and 40 hex digits.
  Digits whose letters are all lower case or all upper case carry no checksum
  and pass. In mixed case they follow the EIP-55 checksum: a letter is upper
  case exactly when the matching hex digit of the Keccak-256 hash of the 40
  digits in lower case is 8 or more.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.ethereum_address`.
- **Default message:** `must be a valid Ethereum address`.
- **Placeholders:** none.
- **Predicate:** `v.isEthereumAddress(s)`.
- **Complexity:** O(1): at most 42 bytes are read, and the 40 digits are
  hashed with Keccak-256 when their letters mix upper and lower case.
  Allocates nothing.
- **Deviations:** [D53](class_validator.md#deviations-from-validatorjs) (the
  checksum is verified, `0X` fails).

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: ethereum_address expects a string, field is u160
validator: <Type>.field_rules.<field>: ethereum_address expects a string, field is [20]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: ethereum_address expects a string, field is []const []const u8; use v.each(v.ethereumAddress)
```

Examples:

| Value | Result |
| --- | --- |
| `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed` | passes: a valid checksum |
| `0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed` | passes: lower case, no checksum |
| `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD` | `validation.ethereum_address`: the checksum is wrong |
| `0X5aaeb6053f3e94c9b9a09f33669435e7ef1beaed` | `validation.ethereum_address`: `0X` |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
