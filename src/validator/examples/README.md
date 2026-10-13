# validator

**Validation rules declared on your structs.** Write the rules of each field
next to the struct, check a value with one call, and get the first violation —
its code, message and path — without allocating. A rule that does not fit its
field is a compile error, not a surprise at run time.

```zig
const std = @import("std");
const v = @import("validator");

const SignUp = struct {
    name: []const u8,
    age: u8,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .name = v.notEmpty,
        .age = v.positive,
        .tags = v.each(v.notEmpty),
    };
};

var path_buf: [256]u8 = undefined;
if (v.check(&request, &path_buf)) |violation| {
    // violation.field: "tags[1]", violation.code: "validation.not_empty",
    // violation.message: "must not be empty"
    std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
}
```

## Contents

- [How it works](#how-it-works)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Declaring rules](#declaring-rules)
- [validateSelf and v.fail](#validateself-and-vfail)
- [v.custom](#vcustom)
- [Messages](#messages)
- [Checking values](#checking-values)
- [Testing a DTO package](#testing-a-dto-package)
- [Compile errors](#compile-errors)
- [Limits](#limits)
- [Compatibility](#compatibility)
- [All rules](#all-rules)

Rules by category: [Common](common.md) · [Numbers](numbers.md) · [Strings](strings.md) ·
[Formats](formats.md) · [Encodings](encodings.md) · [Identifiers](identifiers.md) ·
[Dates](dates.md) · [Lists](lists.md) ·
[Coming from class-validator](class_validator.md)

Examples that `zig build test` compiles and runs:
[Getting started](getting_started.zig) · [validateSelf](validate_self.zig) · [withMessage](with_message.zig) · [DTO package test](dto_test.zig)

## How it works

```mermaid
flowchart LR
    dto["struct with field_rules<br/>and validateSelf"] --> build{"zig build"}
    build -->|"a declaration is wrong"| err(["compile error<br/>validator: ..."])
    build -->|"every rule fits"| run["v.check or v.checkAll"]
    run -->|"valid"| ok(["null, or an empty Report"])
    run -->|"invalid"| violation(["a Violation, or a Report of them:<br/>code, message, field"])
```

1. **Declare.** A struct lists the rules of its fields in `pub const field_rules`
   and checks across fields in `pub fn validateSelf`. Rules are values the
   compiler builds: `v.notEmpty`, `v.positive`, `v.each(...)`, `v.custom(...)`.
2. **Compile.** When a program calls `v.check` or `v.checkAll` for a type, or a
   test calls `comptime v.assertRules(T)`, the compiler checks the declarations
   of that type and of every type below it: each rule against its field's type,
   the keys of `field_rules`, the signature of `validateSelf`, field types the
   walk cannot enter. A mistake is a compile error that starts with `validator: `.
3. **Check.** `v.check(&value, &path_buf)` walks the value depth-first — fields
   in declaration order, items by index — and returns the first violation or
   `null`, allocating nothing. `v.checkAll(gpa, &value)` collects every
   violation, at most 100.

A value has at most one violation: its rules run left to right, the first one
that fails is its violation, and nothing inside it is checked after that.

> [!NOTE]
> confy does not run `field_rules`; to apply rules to a configuration, call
> `v.check` on it after `confy.load`.

## Installation

> **Unreleased: ships in v0.4.0.** Until then zefir-validator is on the `dev`
> branch; add Zefir from it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

Then import the `zefir-validator` module in `build.zig`:

```zig
const zefir = b.dependency("zefir", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "validator", .module = zefir.module("zefir-validator") },
        },
    }),
});
```

> [!TIP]
> validator is also part of the umbrella module: with `zefir.module("zefir")`
> imported as `zefir`, it is `@import("zefir").validator`. Both are the same module.

## Getting started

Declare a struct with rules and check a value:

**`src/main.zig`**

```zig
const std = @import("std");
const v = @import("validator");

const SignUp = struct {
    name: []const u8,
    age: u8,
    tags: []const []const u8 = &.{},
    nickname: ?[]const u8 = null,

    pub const field_rules = .{
        .name = v.notEmpty, // one rule
        .age = v.positive,
        .tags = .{ v.notEmpty, v.each(v.notEmpty) }, // the list, then each item
        .nickname = v.notEmpty, // null skips the rule
    };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const request: SignUp = .{ .name = "Ada", .age = 36, .tags = &.{ "admin", "" } };

    var path_buf: [256]u8 = undefined;
    if (v.check(&request, &path_buf)) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    } else {
        try out.print("valid\n", .{});
    }
}
```

It prints the first violation — the second tag is empty:

```text
tags[1]: must not be empty (validation.not_empty)
```

- `field` is the path of the value: field names joined by `.`, item indexes in
  brackets. `message` is a fragment without the field name or the value, and
  `code` names the rule, for clients that branch on it or translate it.
- `nickname` is `null`, so its rule is skipped; `""` would fail it.
- Fix the tag and `v.check` returns `null`.

## Declaring rules

### field_rules

`field_rules` maps field names to rules: one rule, or a tuple of rules that run
left to right.

```zig
const Order = struct {
    id: []const u8,
    quantity: u32,
    tags: []const []const u8,
    note: ?[]const u8 = null,

    pub const field_rules = .{
        .id = v.notEmpty, // one rule
        .quantity = .{ v.positive, v.max(1000) }, // a tuple
        .tags = .{ v.notEmpty, v.each(v.notEmpty) },
        .note = v.notEmpty, // null skips the rule; "" fails it
    };
};
```

- A key names a field of the struct. A misspelled key is a compile error with a
  suggestion: `validator: orders.Order.field_rules.quantiy: no such field; did you mean "quantity"?`.
- Fields are checked in declaration order, whatever the order of the keys.
- The first rule that fails is the field's only violation; the rules after it
  do not run.
- A field without a key has no rules of its own, but the walk still enters it
  when there are rules inside it. An empty `pub const field_rules = .{}` is
  allowed; an entry with an empty tuple, `.x = .{}`, is a compile error
  (`the list is empty`).
- Comptime fields are never checked; a key that names one is a compile error.

### Optional fields

A `null` in a `?T` field skips the field's rules and everything inside it; a
value is checked like a `T`. Presence is the job of the field type: a field that
must be present is not optional, and there is no `required` rule. `""` is a
value: `v.notEmpty` fails it.

### Nested structs and lists

Struct fields, slices and arrays are walked automatically when there are rules
inside them:

```zig
const Item = struct {
    sku: []const u8,
    qty: u32,
    pub const field_rules = .{ .sku = v.notEmpty, .qty = v.positive };
};

fn inStock(item: *const Item) bool {
    return item.qty <= 500;
}

const Cart = struct {
    items: []const Item,
    pub const field_rules = .{
        // the list as a whole, then each item; Item's own rules check its fields
        .items = .{ v.notEmpty, v.each(v.custom("orders.out_of_stock", "must be in stock", inStock)) },
    };
};
```

With items `{ "a", 1 }, { "b", 0 }` the violation is `items[1].qty`
(`validation.positive`); with one item `{ "a", 600 }` it is `items[0]`
(`orders.out_of_stock`).

- Rules of the list itself (`v.notEmpty`) come first; the rules of its items go
  into one `v.each(...)`, the last rule of the tuple.
- When a rule of the list fails, no item is checked. When an item's rule fails,
  that item is not entered; the other items are checked.
- Each item is walked once: first the `v.each` rules, then the rules of the
  item's own type.
- `v.each(v.each(rule))` applies `rule` to every item of every inner list of
  `[][]T`.
- `null` items of `[]const ?T` are skipped, and the indexes of the others stay
  as they are.
- The rules of an item struct's fields live in the item type: a parent cannot
  declare them. `v.each(v.custom(...))` checks an item as a whole.
- A rule declared on a struct field (such as `v.custom`) runs before anything
  inside that struct.

Unions, enums, opaque types, pointers, tuples, error unions and vectors are not
walked, and neither are slices with `volatile`, `allowzero` or an alignment
below that of their items. When one of them contains a type with rules, that is
a compile error naming the field: nothing is skipped silently. `field_rules` and
`validateSelf` belong on structs: on an enum, a union or an opaque type that the
walk reaches, they are a compile error too.

> [!NOTE]
> Containers that hide their item type — `std.HashMapUnmanaged`,
> `std.MultiArrayList` and similar — are not walked, and there is no error. Use
> slices in DTOs, or check such items in `validateSelf`. `std.ArrayList(T)` is a
> struct with `items: []T`, so its items are walked (`list.items[0].name`).

### Reusing rules

Rules are compile-time values, so a project declares its own once:

```zig
// rules.zig
const v = @import("validator");

pub const quantity = .{ v.positive, v.max(1000) }; // a tuple
pub const sku: v.Rule = v.notEmpty; // one rule
```

```zig
const v = @import("validator");
const rules = @import("rules.zig");

pub const Line = struct {
    sku: []const u8,
    qty: u32,
    pack: u32,
    pub const field_rules = .{
        .sku = rules.sku,
        .qty = rules.quantity, // the tuple is the whole entry
        .pack = rules.quantity ++ .{v.divisibleBy(2)}, // ++ joins tuples
    };
};
```

A tuple inside a tuple is not flattened: `.pack = .{ rules.quantity, v.divisibleBy(2) }`
is a compile error (`item 0 of the tuple is a tuple; tuples are not flattened: join them with ++, e.g. name_rules ++ .{ v.notEmpty }, or use the tuple as the whole entry`).
Use a tuple as the whole entry, or join tuples with `++`.

A `v.Rule` exists only at compile time: keep rules in `const` declarations, or
return them from functions that take `comptime` parameters. A `var` or a struct
field that exists at run time cannot hold one.

> [!IMPORTANT]
> `field_rules` and `validateSelf` must be `pub`, with exactly these names. The
> validator finds them with `@hasDecl`, which sees only public declarations: a
> private `field_rules` is silently never checked, and neither `v.check` nor
> `v.assertRules` can tell. Other names are ignored the same way: `rules`,
> `fieldRules` and `validate_self`. A `pub fn validate` is left to confy,
> except one shaped like `validateSelf` (one `self` parameter, returning
> `?v.Violation`): that one is a compile error that tells you to rename it.
> Give every DTO a test with a value that must fail
> ([Testing a DTO package](#testing-a-dto-package)): it catches the rest.

## validateSelf and v.fail

A check across fields goes into `pub fn validateSelf(self: *const T) ?v.Violation`:

```zig
const std = @import("std");
const v = @import("validator");

const Booking = struct {
    start_day: u32,
    end_day: u32,
    guests: u8,

    pub const field_rules = .{ .guests = v.positive };

    pub fn validateSelf(self: *const Booking) ?v.Violation {
        if (self.end_day < self.start_day)
            return v.fail(@This(), .end_day, "bookings.end_before_start", "must not be before the start day");
        if (self.end_day - self.start_day > 30)
            return v.fail(@This(), null, "bookings.too_long", "must not be longer than 30 days");
        return null;
    }
};

const Trip = struct {
    bookings: []const Booking,

    pub const field_rules = .{ .bookings = v.notEmpty };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const trip: Trip = .{
        .bookings = &.{
            .{ .start_day = 1, .end_day = 40, .guests = 2 }, // too long: the booking itself
            .{ .start_day = 5, .end_day = 3, .guests = 2 }, // ends before it starts: end_day
            .{ .start_day = 9, .end_day = 7, .guests = 0 }, // guests fails, so validateSelf does not run
        },
    };

    const report = try v.checkAll(init.gpa, &trip);
    defer report.deinit();
    for (report.violations) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    }
}
```

It prints:

```text
bookings[0]: must not be longer than 30 days (bookings.too_long)
bookings[1].end_day: must not be before the start day (bookings.end_before_start)
bookings[2].guests: must be greater than 0 (validation.positive)
```

- `validateSelf` runs after all fields of its struct, and only when none of
  them, at any depth, had a violation in this call; nested structs run theirs
  first. The third booking ends before it starts too, but its `guests` field
  fails, so its `validateSelf` does not run.
- It returns one violation, or `null` when the value is valid. An `inline fn` is
  accepted; any other signature is a compile error that shows the expected one.
- `v.fail(@This(), .field, code, message)` builds the violation and checks it at
  compile time: the field must be a non-comptime field of the struct, the code
  follows the [custom code grammar](#vcustom), and the message is 1-512 bytes of
  valid UTF-8. A misspelled field is Zig's own error at your line, such as
  `enum 'meta.FieldEnum(bookings.Booking)' has no member named 'ned'` for
  `Booking` in `bookings.zig`.
- The walk appends the field to the struct's path: `bookings[1].end_day`. A
  `null` field gives the struct's own path, `bookings[0]`, and `field = null`
  for the root.
- `validateSelf` must be pure: no I/O, no global state, no allocation, the same
  answer every time. `check` and `checkAll` may call it a different number of
  times.
- Conditional rules (class-validator's `@ValidateIf`) are code in `validateSelf`.

A violation built by hand, `.{ .code = ..., .message = ..., .field = "end_day" }`,
compiles too, but nothing checks it at compile time. So the walk checks every
result of `validateSelf` at run time — the code grammar, the message, the field
name — and a malformed one is a programmer error:

| Build mode | A malformed result |
| --- | --- |
| Debug | panics: `validator: <Type>.validateSelf returned a malformed violation: …` |
| ReleaseSafe, ReleaseFast, ReleaseSmall | becomes `validation.invalid` / `is invalid` at the struct's path |

> [!WARNING]
> The `code` and `message` of a hand-built violation must be static strings:
> literals or comptime values. The violation outlives the call — `check` returns
> it, a `Report` keeps it — so a string built from `self` would put data from the
> value into logs and responses, or dangle. `v.fail` guarantees static strings;
> when the field is chosen at run time, `switch` over it with one `v.fail` per
> field.

## v.custom

```zig
pub fn custom(comptime code: []const u8, comptime message: []const u8, comptime f: anytype) v.Rule
```

A rule with your own predicate: it passes when `f` returns `true`; otherwise the
violation has your code and message.

```zig
fn startsWithAt(s: []const u8) bool {
    return s.len > 0 and s[0] == '@';
}

fn isEven(n: u64) bool {
    return n % 2 == 0;
}

const Profile = struct {
    handle: [:0]const u8,
    seats: u16,
    pub const field_rules = .{
        .handle = v.custom("profiles.handle_format", "must start with @", startsWithAt),
        .seats = .{ v.positive, v.custom("profiles.odd_seats", "must be even", isEven) },
    };
};
```

**The function** is the function itself (not a pointer to it) with one parameter
and a `bool` result. `T` below is the field type without `?` (inside `v.each`,
the item type); the parameter must be a type that `T` converts to without loss:

| Parameter of `f` | Accepted when | Example |
| --- | --- | --- |
| `T` | always | `fn (u32) bool` on `u32` |
| an integer `P` | the same signedness and `P` at least as wide, or `T` unsigned and `P` signed and wider | `fn (u64) bool` on `u8`, `u16`, `u32`; `fn (i64) bool` on `u32` |
| a float `P` | `P` at least as wide as `T` | `fn (f64) bool` on `f32` |
| a slice or a pointer `P` | the same kind and item type, adding `const` or dropping the sentinel | `fn ([]const u8) bool` on `[]u8`, `[:0]const u8`, `[:0]u8`; `fn ([]const Item) bool` on `[]Item` |
| `?Q` | `T` is accepted for `Q` | `fn (?u32) bool` on `u32` |
| `E!Q` | `T` is accepted for `Q` | `fn (anyerror!u32) bool` on `u32` |
| `*const Q` | `T` is accepted for `Q` | `fn (*const Item) bool` on `Item` (a pointer to the field itself); `fn (*const u64) bool` on `u16` (to a converted copy) |

Anything else is a compile error that names what was expected: a narrower
integer, a signed field with an unsigned parameter, an unsigned field with a
signed parameter that is not wider, a pointer or slice with different
`volatile` or `align` attributes, `*T`, an `anytype` or `comptime` parameter,
zero or several parameters, a result other than `bool`. An `inline fn` is
accepted.

```text
validator: users.Account.field_rules.age: custom("users.ok", ...): f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (i8) bool
```

When `f` fits the items of a list field, the error ends with
`; use v.each(v.custom(...))`.

**The code** is ASCII segments `[a-z][a-z0-9_]*` joined by `.`: at least two
segments, at most 128 bytes (`v.max_code_bytes`), not starting with
`validation.` or `rpc.`:

```text
code    = segment 1*("." segment)                 ; at least 2 segments
segment = %x61-7A *(%x61-7A / DIGIT / "_")        ; [a-z][a-z0-9_]*
```

| Code | Compile error |
| --- | --- |
| `users.name_taken`, `orders.v2.limit`, `a.b1_`, `validationx.y`, `x.validation` | none: accepted |
| longer than 128 bytes (checked first) | `is longer than 128 bytes` |
| `users..taken`, `.users`, `users.` | `has an empty segment` |
| `users.Taken`, `users.name-taken`, `users.имя` | `has a character outside [a-z0-9_.]` |
| `users.2fa`, `_a.b` | `has a segment that does not start with a letter` |
| `users` | `needs at least 2 segments` |
| `validation.mine`, `rpc.mine` (checked last) | `uses a reserved prefix (validation., rpc.)` |

`validation.` is reserved for the codes of the built-in rules and `rpc.` for
zefir's RPC module. Start a code with your service or domain:
`users.name_taken`, `orders.end_before_start`. The same grammar applies to
`v.fail` and to every `validateSelf` result.

**The message** is literal: 1-512 bytes (`v.max_message_bytes`) of valid UTF-8,
counted in bytes, so a Cyrillic letter takes two. Braces are plain characters
here; a message given later with `.withMessage` is a template
([Messages](#messages)).

**Behaviour.** There is no precondition: `f` sees NaN, invalid UTF-8 and `""`.
The rule works on a field of any type, unions and structs included, inside
`v.each`, and several times on one field (the first one that fails is
reported). `f` must be pure: no I/O, no global state, no allocation, the same
answer every time, bounded in time; it must not keep a pointer it receives.

## Messages

A built-in rule reports its code and a **default message**: English, a fragment
in lower case that starts with `must` and has no trailing period. It names
neither the field (the path is in `field`) nor the value (a violation never
contains it), and it shows the parameters of the rule, which are known when the
program is compiled: `v.min(18)` says `must be at least 18`. The compiler also
chooses the singular or the plural (`must have at least 1 item`,
`must have at least 2 items`), the variant for one listed value
(`v.oneOf(.{.admin})` says `must be admin`) and the variant for equal bounds
(`v.range(7, 7)` says `must be 7`). The page of each rule lists its messages.

### .withMessage

```zig
pub fn withMessage(comptime rule: v.Rule, comptime template: []const u8) v.Rule
```

`rule.withMessage(template)` returns a copy of the rule with another message;
the code stays. The template must be known at compile time (a literal, a
`const`, or `++` of them): the compiler fills in the placeholders, and the rule
keeps the result as a static string.

```zig
const std = @import("std");
const v = @import("validator");

const Role = enum { admin, editor, viewer };

// A rule with a message is a value: declare it once, use it on any field.
const filled = v.notEmpty.withMessage("заполните поле");

const Profile = struct {
    name: []const u8,
    nickname: []const u8,
    age: u8,
    role: Role,
    tags: []const []const u8,
    height: f64,
    weight: f64,

    pub const field_rules = .{
        .name = filled,
        .nickname = filled,
        .age = v.range(18, 120).withMessage("age must be from {min} to {max}"),
        .role = v.oneOf(.{ .admin, .editor }).withMessage("role must be one of: {values}"),
        .tags = v.maxItems(2).withMessage("не больше {max} тегов"),
        .height = v.positive.withMessage("height must be above zero"), // NaN keeps validation.finite
        .weight = .{ v.finite.withMessage("weight must be a number"), v.positive },
    };
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const profile: Profile = .{
        .name = "",
        .nickname = "ada",
        .age = 17,
        .role = .viewer,
        .tags = &.{ "a", "b", "c" },
        .height = std.math.nan(f64),
        .weight = std.math.nan(f64),
    };

    const report = try v.checkAll(init.gpa, &profile);
    defer report.deinit();
    for (report.violations) |violation| {
        try out.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
    }
}
```

It prints the violation of every field that fails (`nickname` passes). The codes
are the rules' own, and the messages come from the templates, except for
`height`, whose precondition keeps its own:

```text
name: заполните поле (validation.not_empty)
age: age must be from 18 to 120 (validation.range)
role: role must be one of: admin, editor (validation.one_of)
tags: не больше 2 тегов (validation.max_items)
height: must be a finite number (validation.finite)
weight: weight must be a number (validation.finite)
```

- `.withMessage` works on every rule except `v.each`, which has no message of
  its own: put it on the rules inside, `v.each(v.notEmpty.withMessage("..."))`.
- It replaces the message of the rule's own check and never changes the code.
  A violation of a precondition keeps its code and message, as `height` shows
  ([Preconditions](#preconditions)).
- A second `.withMessage` replaces the first:
  `v.minItems(8).withMessage("a {min}").withMessage("b {min}")` says `b 8`. The
  rule that `.withMessage` was called on keeps its message.
- A rule with a message is a value like any rule: `filled` above is declared
  once and used on two fields, and a tuple of rules with messages can be the
  whole entry of a field ([Reusing rules](#reusing-rules)).
- The message of `v.custom` and `v.fail` is literal text, braces included. A
  template given to `.withMessage` on a `v.custom` rule is read like any other,
  and `v.custom` has no placeholders.

### Placeholders

A placeholder is the name of a parameter of the rule in braces. `.withMessage`
replaces it with the parameter as the default message shows it. The names belong
to the contract of a rule, like its code.

| Placeholder | Rules | The parameter | Shown as |
| --- | --- | --- | --- |
| `{expected}` | `v.equals` | the value | a value, as below |
| `{forbidden}` | `v.notEquals` | the value | a value, as below |
| `{values}` | `v.oneOf`, `v.noneOf`, `v.containsAll`, `v.containsNone` | the listed values | each value as below, joined with `, ` |
| `{min}` | `v.min`, `v.range`, `v.minLength`, `v.length`, `v.minBytes`, `v.minDate`, `v.minItems` | the lower bound; the least number of characters, bytes or items; the earliest date | a number as written; a count in decimal; a date bound as written |
| `{max}` | `v.max`, `v.range`, `v.maxLength`, `v.length`, `v.maxBytes`, `v.maxDate`, `v.maxItems` | the upper bound; the largest number of characters, bytes or items; the latest date | as `{min}` |
| `{divisor}` | `v.divisibleBy` | the divisor | an integer in decimal |
| `{seed}` | `v.contains`, `v.notContains` | the substring | a string as below |
| `{min_length}`, `{min_lowercase}`, `{min_uppercase}`, `{min_numbers}`, `{min_symbols}` | `v.strongPassword` | the options of the same names, all five also when 0 | an integer in decimal |
| `{min_decimal_digits}`, `{max_decimal_digits}` | `v.decimal` | the options of the same names; `{max_decimal_digits}` only when the option is set | an integer in decimal |
| `{algorithm}` | `v.hash` | the algorithm | its tag name, without the dot: `sha256` |
| `{network}` | `v.btcAddress` | the network | its tag name, without the dot: `mainnet`, `testnet` or `any` |
| `{key}` | `v.uniqueBy` | the key | the field name, without the dot |

A rule that is not listed has no placeholders, and the page of each rule names
its own. A placeholder that the rule does not have is a compile error that lists
the ones it has.

A parameter is shown the same way in a default message and in a placeholder:

| A value | Shown as | Example |
| --- | --- | --- |
| an integer | decimal | `v.max(255)`: `must be at most 255` |
| a float | decimal digits when 1e-6 ≤ \|x\| < 1e21, scientific notation otherwise; `0.0` and `-0.0` as `0` | `v.min(0.5)`: `must be at least 0.5`; `v.max(1e-7)`: `must be at most 1e-7` |
| a `bool` | `true` or `false` | `v.notEquals(false)`: `must not be equal to false` |
| an enum tag | its name, without the dot | `v.equals(.admin)`: `must be equal to admin` |
| a string | escaped, without quotes; the empty string as `""` | `v.oneOf(.{ "", "x" })`: `must be one of: "", x` |
| a list | its values joined with `, ` | `v.oneOf(.{ 1, 2, 3 })`: `must be one of: 1, 2, 3` |

- A number is shown as written, before it is converted to the field type:
  `v.max(0.1)` on an `f32` field says `must be at most 0.1`, not
  `0.10000000149011612`.
- Escaping is that of `std.zig.fmtString`, so a message stays on one line: `\n`,
  `\r`, `\t`, `\\` and `"` are escaped, and control bytes, invalid UTF-8, U+0085,
  U+2028, U+2029 and U+FEFF are written in hex (`\xe2\x80\xa8`). Cyrillic and other
  valid UTF-8 stays as it is.
- A listed value that contains `, ` itself makes the message ambiguous:
  `v.oneOf(.{ "a, b", "c" })` says `must be one of: a, b, c`. Give such a list a
  message of your own with `.withMessage`.

### Template syntax

| In the template | Result |
| --- | --- |
| `{name}` | the placeholder `name` |
| `{{` | `{` |
| `}}` | `}` |
| a `}` alone | `}` |
| a `{` without a closing `}` | a compile error |

For example, `v.min(18).withMessage("at least {min} years")` says
`at least 18 years`, `v.divisibleBy(5).withMessage("{{divisor}} = {divisor}")`
says `{divisor} = 5`, and `v.negative.withMessage("a } b")` says `a } b`.

There is no `{value}` (a violation never contains the value), no `{field}` (the
path exists only at run time) and no syntax for plurals: the number is known at
compile time, so write the word in the form you need. The template is read from
left to right, and its first unknown or unclosed placeholder is the error.

A mistake in a template is a compile error at the `.withMessage` call. It starts
with the call of the rule and the template, escaped:

```text
validator: divisibleBy(5).withMessage("must be a multiple of {n}"): unknown placeholder {n}; available: {divisor}
validator: negative.withMessage("{value} must be negative"): unknown placeholder {value}; this rule has no placeholders
validator: divisibleBy(5).withMessage("must be divisible by {divisor"): '{' without a closing '}'; write '{{' for a literal '{'
validator: notEmpty.withMessage(""): message must not be empty
validator: maxItems(5).withMessage("<the 513-byte template>"): message is longer than 512 bytes
validator: min(1).withMessage("\xc3"): message must be valid UTF-8
validator: each(...).withMessage("x"): each has no message of its own; put .withMessage on the inner rules
```

Mistakes that Zig itself rejects (no template, a template that is not a string
or not known at compile time) are listed under [Compile errors](#compile-errors).

### Any language, and the 512-byte limit

- Templates of `.withMessage` and messages of `v.custom` and `v.fail` can be in
  any language: any valid UTF-8, 1-512 bytes (`v.max_message_bytes`). Bytes are
  counted, not characters: a Cyrillic letter takes 2, a CJK character 3 and an
  emoji 4, so 512 bytes hold about 250 Cyrillic letters. The limit applies to the
  message after the placeholders are filled in.
- Placeholders work the same in every language. Since the number in a
  placeholder is known at compile time, write the word in the form you need.
- Default messages are English only, and there are no translation catalogs. To
  localize, give the rules messages in your language with `.withMessage`, or
  translate on the client by `code`, which is stable and part of the contract of
  the rule.

### Fallback messages

A default message that shows a list, a string or a number of hundreds of digits
can grow beyond 512 bytes. The rules `v.equals`, `v.notEquals`, `v.oneOf`,
`v.noneOf`, `v.contains`, `v.notContains`, `v.minDate`, `v.maxDate`,
`v.containsAll` and `v.containsNone` then use a general message instead, chosen
at compile time; the code does not change:

| Rule | Fallback message |
| --- | --- |
| `v.equals` | `must be equal to the expected value` |
| `v.notEquals` | `must not be equal to the forbidden value` |
| `v.oneOf` | `must be one of the allowed values` |
| `v.noneOf` | `must not be one of the forbidden values` |
| `v.contains` | `must contain the required text` |
| `v.notContains` | `must not contain the forbidden text` |
| `v.minDate` | `must not be before the minimum date` |
| `v.maxDate` | `must not be after the maximum date` |
| `v.containsAll` | `must contain all of the required values` |
| `v.containsNone` | `must not contain any of the forbidden values` |

A message of exactly 512 bytes stays; one byte more falls back. `.withMessage`
replaces a fallback as it replaces any message, and its placeholders still show
the whole parameter: every listed value, the whole substring or the whole bound
(the result must still fit in 512 bytes).

`v.min`, `v.max`, `v.range` and `v.divisibleBy` have no fallback. Their default
message is longer than 512 bytes only for a bound or a divisor of hundreds of
digits (very wide integer types, `f80` and `f128`), and then the field is a
compile error unless `.withMessage` replaces the message:

```text
validator: <Type>.field_rules.<field>: min(<the 512-digit value of 2^1700>): the default message would be 529 bytes (limit 512); use .withMessage(...)
```

### Preconditions

A precondition is what a rule needs from its input before its own check means
anything. The rules that compare a number need a finite one on a float field:
NaN, `+inf` and `-inf` fail with `validation.finite` /
`must be a finite number`, before the check of the rule runs. The rules with
this precondition are `v.equals`, `v.notEquals`, `v.min`, `v.max`, `v.range`,
`v.positive`, `v.nonNegative`, `v.negative`, `v.nonPositive`, `v.divisibleBy`,
`v.latitude` and `v.longitude`; on integers, `bool`, enums and strings they have
none ([D16](class_validator.md#deviations-from-validatorjs)). The string rules
that read code points need valid UTF-8: invalid UTF-8 fails `v.minLength`,
`v.maxLength`, `v.length`, `v.notBlank`, `v.fullWidth`, `v.halfWidth`,
`v.variableWidth` and `v.strongPassword` with `validation.utf8` /
`must be valid UTF-8` ([D13](class_validator.md#deviations-from-validatorjs)).
`v.minDate` and `v.maxDate` need a value of the form of their bound: with a
date bound, a value that is not a date fails with `validation.date` /
`must be a valid date in YYYY-MM-DD format`; with a date-time bound, a value
that is not an RFC 3339 date-time fails with `validation.rfc3339` /
`must be a valid RFC 3339 date-time` ([Dates](dates.md#vmindatemin)).

- The code and the message of a precondition are fixed: `.withMessage` does not
  change them. `v.positive.withMessage("must be above zero")` reports
  `validation.finite` / `must be a finite number` for NaN and
  `validation.positive` / `must be above zero` for `-1`. A text such as "name is
  too long" for an input of the wrong form would be false.
- A precondition is checked first, even when the check of the rule could decide
  without it. Its violation is the value's only violation, like any other.

To give the precondition a message of your own, put the rule that checks the
same condition first in the tuple, with your message:

```zig
.price = .{ v.finite.withMessage("price must be a number"), v.positive },
.name = .{ v.utf8.withMessage("the name must be UTF-8"), v.maxLength(64) },
```

`v.finite` and `v.utf8` are ordinary rules: their own check reports the same
code as the precondition, so `.withMessage` applies to them. Each stands first,
the first rule that fails is the only violation of the field, and `v.positive`
never sees a NaN, nor `v.maxLength` invalid UTF-8.

## Checking values

### v.check

```zig
pub fn check(value: anytype, path_buf: []u8) ?v.Violation
```

```zig
var path_buf: [256]u8 = undefined;
if (v.check(&request, &path_buf)) |violation| {
    // violation.code, violation.message, violation.field: ?[]const u8
    std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
}
```

- `value` is a pointer to one value: `&request`. Passing the value itself, or a
  slice without `&`, is a compile error. The root can be any type: a struct, a
  slice (`&users`, paths such as `[1].email`), an array, an optional, a scalar.
- The result is the first violation in walk order, or `null`. `check`
  allocates nothing and returns no errors.
- `field` points into `path_buf`: it is valid while the buffer lives and until
  the next call with the same buffer. A path of exactly `path_buf.len` bytes
  fits; a longer one gives `field = null` with the full `code` and `message`.
  The bytes of `path_buf` outside `field` are undefined after the call.
- `path_buf` must not overlap the checked value: the walk writes the path into
  it while it still reads the value. The recommended size is 256 bytes.
- The violation does not point into the checked value: free the value, and the
  violation stays valid.

### v.checkAll and Report

```zig
pub fn checkAll(gpa: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!v.Report
```

```zig
const report = try v.checkAll(gpa, &request);
defer report.deinit();
for (report.violations) |violation| {
    std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
}
if (report.truncated) std.debug.print("more than {d} violations\n", .{v.max_report_violations});
```

- `violations` are in walk order, at most one per value and at most 100
  (`v.max_report_violations`) in all; `truncated` is `true` exactly when there
  was a 101st. The first violation equals the result of `check` (its `field`
  too, when the path fits `path_buf`).
- The report owns its memory, like `std.json.Parsed`: one arena from `gpa`
  holds the list and every path, and paths have no length limit. Call `deinit`
  exactly once after every successful call, even for a valid value. After it
  `violations` and every `field` are gone; `code` and `message` are static
  strings and stay valid.
- The only run-time error is `error.OutOfMemory`; nothing leaks then.

### Threads

`check` and `checkAll` keep no global state, so several threads can check
values at once, the same value included, when:

- calls that run at the same time use different `path_buf`s;
- no thread changes the value during a call;
- a `gpa` shared by `checkAll` calls on several threads is thread-safe;
- `v.custom` functions and `validateSelf` are pure, as they must be anyway.

### Violation

```zig
pub const Violation = struct {
    code: []const u8,
    message: []const u8,
    field: ?[]const u8 = null,
};
```

| Field | Content |
| --- | --- |
| `code` | `validation.<rule>` for a built-in rule (`validation.not_empty`); your code for `v.custom` and `v.fail`; `validation.finite` for NaN or an infinity in a float field; `validation.invalid` for a malformed `validateSelf` result outside Debug |
| `message` | the rule's default message (`must not be empty`) or yours: 1-512 bytes of UTF-8, never containing the value (a default message has no field name either) |
| `field` | the path of the value from the root (`email`, `address.city`, `items[2].name`, `[1].email`); `null` for the root itself |

A violation from a built-in rule, `v.custom` or `v.fail` never contains the
checked value, so it is safe to log and to send to a client as it is. A
hand-built `validateSelf` result is safe only when its `code` and `message` are
static strings (see the warning in [validateSelf and v.fail](#validateself-and-vfail)).

### Paths

| Value | Path |
| --- | --- |
| a field of the root | `email` |
| a field of a nested struct | `address.city` |
| a field of a slice item | `items[2].name` |
| an item of a nested array | `matrix[1][0]` |
| a field of an item of a root slice | `[1].email` |
| a field inside an optional | `billing.city` (an optional adds no segment) |
| `validateSelf` with a field / without | `items[2].end` / `items[2]` |
| the root itself | `field = null` |

The grammar, for clients in other languages:

```text
path  = first *rest
first = name / index
rest  = "." name / index
index = "[" ( "0" / %x31-39 *DIGIT ) "]"   ; decimal from 0, no leading zeros
name  = 1*( any byte except %x00, ".", "[" and "]" )
```

Names are the field names of the types, as declared, non-ASCII ones included; a
field name with `.`, `[` or `]` in a struct the walk enters is a compile error.

> [!NOTE]
> `field = null` from `check` means either the root itself or a path that did
> not fit `path_buf`; the two cannot be told apart. From `checkAll` it always
> means the root.

## Testing a DTO package

Zig compiles only the code that is used. A DTO that nothing in its own package
passes to `v.check` is not checked when the package builds: a mistake in its
`field_rules`, or in a `v.fail` inside its `validateSelf`, shows up later, in
the first service that calls `check`. So every DTO package calls
`comptime v.assertRules(T)` in a test. It runs exactly the compile-time checks
of `v.check` for `T` and every type below it, the bodies of `validateSelf`
included, and does nothing at run time.

```zig
const std = @import("std");
const v = @import("validator");

pub const Role = enum { admin, editor, viewer };

pub const CreateUserRequest = struct {
    name: []const u8,
    age: u8,
    roles: []const Role,
    nickname: ?[]const u8 = null,

    pub const field_rules = .{
        .name = v.notEmpty,
        .age = v.positive,
        .roles = v.notEmpty,
        .nickname = v.notEmpty,
    };
};

test "every DTO of this file passes v.assertRules" {
    comptime v.assertRules(@This()); // the file itself: a DTO when it has top-level fields
    inline for (comptime std.meta.declarations(@This())) |name| {
        const decl = @field(@This(), name);
        if (@TypeOf(decl) == type) comptime v.assertRules(decl);
    }
}

test "CreateUserRequest rejects an empty name" {
    var path_buf: [256]u8 = undefined;
    const bad: CreateUserRequest = .{ .name = "", .age = 30, .roles = &.{.admin} };
    const violation = v.check(&bad, &path_buf) orelse return error.NoViolation;
    try std.testing.expectEqualStrings("validation.not_empty", violation.code);
    try std.testing.expectEqualStrings("name", violation.field.?);
}
```

- The first test checks the file itself, for a file that is a DTO (top-level
  fields, as in `User.zig`), and every `pub` type declared at the top level of
  the file. DTOs in other files get the same test in their file, and the
  package root pulls those tests in with `test { _ = @import("orders.zig"); }`.
- The checks reach types through fields, not declarations: DTOs nested in a
  namespace struct (`pub const users = struct { pub const Create = ... };`)
  are not checked by the first test. List them:
  `inline for (.{ users.Create, users.Update }) |Dto| comptime v.assertRules(Dto);`.
- `assertRules` takes the type itself. A `pub` alias of a pointer type
  (`pub const UserRef = *const User;`) or a `pub` union of DTOs fails the first
  test, because pointers and unions are not walked; list the DTOs instead of
  the loop: `inline for (.{ CreateUserRequest, User }) |Dto| comptime v.assertRules(Dto);`.
- `assertRules` cannot see a private `field_rules` and does not run the rules.
  The second test, a value that must fail, catches both.

## Compile errors

A mistake in a declaration is a compile error whose text starts with
`validator: ` and says where it is:

```text
error: validator: orders.Order.field_rules.id: positive expects a number, field is []const u8
```

`orders.Order` is the type as Zig names it (the struct `Order` in `orders.zig`),
`field_rules.id` the entry. Inside `v.each` the path ends with `[]`:
`orders.Order.field_rules.tags[]`. In hints, rules are written as code you can
paste: `use v.each(v.positive)`.

Errors come from two places, and Zig points to them differently:

| | Rule constructors | Declarations |
| --- | --- | --- |
| What | the arguments of a rule (`v.custom`, `v.each`, `v.min`, `v.oneOf`, …) and the template of `.withMessage`, whatever the field | a rule that does not fit its field, an unknown key, a wrong `validateSelf`, a field type the walk cannot enter |
| Text | the call as written: `validator: custom("Taken", ...): code 'Taken' has a character outside [a-z0-9_.]; ...` | the path: `validator: orders.Order.field_rules.id: ...` |
| Where Zig points | into the library; a `note: called at comptime here` shows your line with the call | into the library. With `v.check` or `v.checkAll`, in a test or a program, the first entry under `referenced by:` is your call and the rest are its callers; with `comptime v.assertRules(T)` there is no such list, and the last `note: called at comptime here` shows your call. Either way Zig shows the call, not the DTO, so the path in the text is your pointer |

For example, a code that breaks the grammar (file and line numbers shortened):

```text
…/validator/core.zig:…: error: validator: custom("Taken", ...): code 'Taken' has a character outside [a-z0-9_.]; use segments of [a-z][a-z0-9_]* joined by '.', e.g. 'users.name_taken'
…/validator/custom.zig:…: note: called at comptime here
accounts.zig:7:48: note: called at comptime here
```

The errors of `v.fail` inside `validateSelf` (a bad code or message, a comptime
field) are reported inside the library as well; your line is in the
`referenced by:` list.

**Errors from Zig itself.** Some mistakes are caught by the compiler before the
library runs. These errors point at your line and do not start with
`validator: `; their wording belongs to Zig and can change with its version:

| You wrote | Zig says |
| --- | --- |
| `v.notEmpty()`: a rule without parameters called like a function | `type 'core.Rule' not a function` |
| `v.fail(@This(), .ned, ...)`: a field the struct does not have | `enum 'meta.FieldEnum(bookings.Booking)' has no member named 'ned'` |
| `v.custom("users.ok", isFree)`: a missing argument | `expected 3 argument(s), found 2` |
| `v.minItems.withMessage("...")`: `.withMessage` on a rule that needs a call | `no field or member function named 'withMessage' in 'fn (comptime usize) core.Rule'` |
| `v.minItems(-1)`: a negative count, or one above `maxInt(usize)` | `type 'usize' cannot represent integer value '-1'` |
| `v.maxItems(1.5)`: a fractional count (`3.0` is accepted) | `fractional component prevents float value '1.5' from coercion to type 'usize'` |
| `v.strongPassword(.{ .minLength = 12 })`: an option the struct does not have | `no field named 'minLength' in struct 'strings.StrongPasswordOptions'` |
| `v.decimal(.{ .decimal_digits = "1,2" })`: an option the rule does not have, such as validator.js's `decimal_digits` | `no field named 'decimal_digits' in struct 'formats.DecimalOptions'` |
| `v.macAddress(.{ .no_separators = true })`: the same for `isMACAddress`'s `no_separators`; write `.format = .bare` | `no field named 'no_separators' in struct 'formats.MacAddressOptions'` |
| `v.macAddress(.{ .eui = .eui32 })`: a tag the option does not have | `enum 'formats.MacAddressOptions.Eui' has no member named 'eui32'` |
| `v.macAddress(.{ .eui = "48" })`: validator.js's string instead of a tag | `expected type 'formats.MacAddressOptions.Eui', found '*const [2:0]u8'` |
| `v.decimal(.{ .max_decimal_digits = -1 })`: an option value of another type, such as a negative count, a string, or `1` for a bool | `expected type '?usize', found 'comptime_int'` |
| `v.fqdn(true)`, `v.decimal(2)`: a value instead of the options struct | `expected type 'formats.FqdnOptions', found 'bool'` |
| `v.macAddress(.eui48)`: a tag instead of the options struct; write `v.macAddress(.{ .eui = .eui48 })` | `struct 'formats.MacAddressOptions' has no member named 'eui48'` |
| `v.fqdn()`: the options left out; write `v.fqdn(.{})` | `expected 1 argument(s), found 0` |
| `v.decimal.withMessage("...")`: `.withMessage` on a rule that needs its options | `no field or member function named 'withMessage' in 'fn (comptime formats.DecimalOptions) core.Rule'` |
| `v.hash(.sha3_256)`, `v.btcAddress(.regtest)`: a tag the selector's enum does not have (tags are lower case: `.sha256`, not `.SHA256`) | `enum 'identifiers.HashAlgorithm' has no member named 'sha3_256'` |
| `v.hash("sha256")`: a string instead of a tag, as in class-validator | `expected type 'identifiers.HashAlgorithm', found '*const [6:0]u8'` |
| `v.hash(@fromBackingInt(14))`: a number that is no tag of the selector's enum | `enum 'identifiers.HashAlgorithm' has no tag with value '14'` |
| `v.notEmpty.withMessage()`: no template, or two | `member function expected 1 argument(s), found 0` |
| `v.notEmpty.withMessage(5)`: a template that is not a string | `expected type '[]const u8', found 'comptime_int'` |
| `v.maxItems(limit)`, `v.hash(alg)`, `.withMessage(text)`: a parameter or a template known only at run time; for an algorithm or a network chosen at run time, call the predicate in `validateSelf`: `v.isHash(s, alg)`, `v.isBtcAddress(s, network)` | `unable to resolve comptime value` (note: `argument to comptime parameter must be comptime-known`) |

**What is not checked at compile time:**

- `field_rules` and `validateSelf` without `pub`, and rules under another name
  (`rules`, `fieldRules`, `validate_self`): they are invisible and do nothing;
- items of containers that hide their item type (`std.HashMapUnmanaged`,
  `std.MultiArrayList`);
- the result of `validateSelf`: it is checked at run time (a panic in Debug,
  `validation.invalid` in the other modes);
- whether `v.custom` functions and `validateSelf` are pure;
- types that no `v.check`, `v.checkAll` or `v.assertRules` reaches
  ([Testing a DTO package](#testing-a-dto-package)).

## Limits

| Limit | Value | What it limits |
| --- | --- | --- |
| `v.max_code_bytes` | 128 | a code: `v.custom`, `v.fail` and `validateSelf` results |
| `v.max_message_bytes` | 512 | a message, in bytes |
| `v.max_report_violations` | 100 | the violations in a `Report` |
| `v.max_unique_items` | 1000 | the items of a list whose integers, strings or non-exhaustive enum tags `v.uniqueItems` and `v.uniqueBy` compare: a slice needs an earlier `v.maxItems(n)` with `n` at most this, `[N]T` an `N` at most this |
| `v.max_json_depth` | 64 | the nesting of a JSON text that `v.json` and `v.isJson` accept |

The limits are `comptime_int` constants and part of the contract (see below).

## Compatibility

- **The behaviour of a rule is a contract** from the first release that ships
  it: what it accepts, its code, its default message and the names of its
  placeholders. So are the walk — which violations `check` and `checkAll`
  return, in which order, with which paths — and the values of the limits.
- Until 1.0, such a change comes only in a minor release, and its release notes
  say so; a patch release never changes a rule.
- **Security fixes** are the exception: a rule that panics on some input, takes
  unbounded time, or accepts an input that its documented specification
  rejects may be tightened in a patch release. A tightened rule can reject
  values that were stored or written into configuration before the fix: check
  such data with the new rule before you upgrade.
- Compile error texts and hints are not part of the contract; a release may
  improve them as long as the same declarations still compile, or still fail.
- **One copy of zefir.** The packages that share DTOs — the DTO package, API
  packages, services and their clients — must resolve the same zefir package:
  the same version and the same `b.dependency` options. Two copies have two
  different `v.Rule` and `v.Violation` types, and their rules do not mix.
- A client and a server that check the same value get the same first violation
  only when the types whose width depends on the target — `usize`, `isize`,
  `c_int`, `c_long`, `c_longdouble` and similar — have the same width on both.
  Fixed-width types such as `u64` avoid the question. For the same `field`
  from `check`, both also need a `path_buf` of the same size: a path that fits
  one buffer may not fit a smaller one.

## All rules

| Rule | Checks | Code | Page |
| --- | --- | --- | --- |
| `v.equals(expected)` | a value is equal to `expected` | `validation.equals` | [common](common.md#vequalsexpected) |
| `v.notEquals(forbidden)` | a value is not equal to `forbidden` | `validation.not_equals` | [common](common.md#vnotequalsforbidden) |
| `v.oneOf(.{ ... })` | a string, an enum tag or an integer is one of the listed values | `validation.one_of` | [common](common.md#voneofvalues) |
| `v.noneOf(.{ ... })` | a string, an enum tag or an integer is none of the listed values | `validation.none_of` | [common](common.md#vnoneofvalues) |
| `v.empty` | a string has no bytes, a slice no items | `validation.empty` | [common](common.md#vempty) |
| `v.notEmpty` | a string has at least 1 byte, a slice at least 1 item | `validation.not_empty` | [common](common.md#vnotempty) |
| `v.min(min)` | a number is at least `min` | `validation.min` | [numbers](numbers.md#vminmin) |
| `v.max(max)` | a number is at most `max` | `validation.max` | [numbers](numbers.md#vmaxmax) |
| `v.range(min, max)` | a number is from `min` to `max` | `validation.range` | [numbers](numbers.md#vrangemin-max) |
| `v.positive` | a number is greater than 0 | `validation.positive` | [numbers](numbers.md#vpositive) |
| `v.nonNegative` | a number is at least 0 | `validation.non_negative` | [numbers](numbers.md#vnonnegative) |
| `v.negative` | a number is less than 0 | `validation.negative` | [numbers](numbers.md#vnegative) |
| `v.nonPositive` | a number is at most 0 | `validation.non_positive` | [numbers](numbers.md#vnonpositive) |
| `v.divisibleBy(divisor)` | a number is a multiple of `divisor` | `validation.divisible_by` | [numbers](numbers.md#vdivisiblebydivisor) |
| `v.finite` | a float is neither NaN nor an infinity | `validation.finite` | [numbers](numbers.md#vfinite) |
| `v.minLength(min)` | a string has at least `min` code points | `validation.min_length` | [strings](strings.md#vminlengthmin) |
| `v.maxLength(max)` | a string has at most `max` code points | `validation.max_length` | [strings](strings.md#vmaxlengthmax) |
| `v.length(min, max)` | a string has from `min` to `max` code points | `validation.length` | [strings](strings.md#vlengthmin-max) |
| `v.minBytes(min)` | a string has at least `min` bytes | `validation.min_bytes` | [strings](strings.md#vminbytesmin) |
| `v.maxBytes(max)` | a string has at most `max` bytes | `validation.max_bytes` | [strings](strings.md#vmaxbytesmax) |
| `v.utf8` | a string is valid UTF-8 | `validation.utf8` | [strings](strings.md#vutf8) |
| `v.notBlank` | a string has a code point outside Unicode White_Space | `validation.not_blank` | [strings](strings.md#vnotblank) |
| `v.ascii` | every byte of a string is ASCII | `validation.ascii` | [strings](strings.md#vascii) |
| `v.printableAscii` | every byte of a string is printable ASCII (0x20-0x7E) | `validation.printable_ascii` | [strings](strings.md#vprintableascii) |
| `v.alphanumeric` | every byte of a string is an ASCII letter or digit | `validation.alphanumeric` | [strings](strings.md#valphanumeric) |
| `v.alpha` | every byte of a string is an ASCII letter | `validation.alpha` | [strings](strings.md#valpha) |
| `v.digits` | every byte of a string is an ASCII digit | `validation.digits` | [strings](strings.md#vdigits) |
| `v.lowercase` | a string has no ASCII uppercase letter | `validation.lowercase` | [strings](strings.md#vlowercase) |
| `v.uppercase` | a string has no ASCII lowercase letter | `validation.uppercase` | [strings](strings.md#vuppercase) |
| `v.multibyte` | a string has a byte outside ASCII | `validation.multibyte` | [strings](strings.md#vmultibyte) |
| `v.fullWidth` | a string has a character outside validator.js's half-width class | `validation.full_width` | [strings](strings.md#vfullwidth) |
| `v.halfWidth` | a string has a character in validator.js's half-width class | `validation.half_width` | [strings](strings.md#vhalfwidth) |
| `v.variableWidth` | a string has characters in and outside that class | `validation.variable_width` | [strings](strings.md#vvariablewidth) |
| `v.contains(seed)` | a string contains `seed` | `validation.contains` | [strings](strings.md#vcontainsseed) |
| `v.notContains(seed)` | a string does not contain `seed` | `validation.not_contains` | [strings](strings.md#vnotcontainsseed) |
| `v.strongPassword(.{ ... })` | a password has the length and the classes of characters that the options ask for | `validation.strong_password` | [strings](strings.md#vstrongpasswordoptions) |
| `v.numberString` | a string is a number in decimal notation | `validation.number_string` | [formats](formats.md#vnumberstring) |
| `v.decimal(.{ ... })` | a string is a decimal number with as many digits after the point as the options allow | `validation.decimal` | [formats](formats.md#vdecimaloptions) |
| `v.booleanString` | a string is `true`, `false`, `1` or `0` | `validation.boolean_string` | [formats](formats.md#vbooleanstring) |
| `v.hexadecimal` | a string is a hexadecimal number | `validation.hexadecimal` | [formats](formats.md#vhexadecimal) |
| `v.octal` | a string is an octal number | `validation.octal` | [formats](formats.md#voctal) |
| `v.port` | a string is a port number from 0 to 65535 | `validation.port` | [formats](formats.md#vport) |
| `v.latitude` | a string or a float is a latitude from -90 to 90 | `validation.latitude` | [formats](formats.md#vlatitude) |
| `v.longitude` | a string or a float is a longitude from -180 to 180 | `validation.longitude` | [formats](formats.md#vlongitude) |
| `v.latLong` | a string is a `latitude,longitude` pair | `validation.lat_long` | [formats](formats.md#vlatlong) |
| `v.email` | a string is an email address | `validation.email` | [formats](formats.md#vemail) |
| `v.httpUrl` | a string is an http or https URL | `validation.http_url` | [formats](formats.md#vhttpurl) |
| `v.fqdn(.{ ... })` | a string is a domain name | `validation.fqdn` | [formats](formats.md#vfqdnoptions) |
| `v.ip` | a string is an IPv4 or an IPv6 address | `validation.ip` | [formats](formats.md#vip) |
| `v.ipv4` | a string is an IPv4 address | `validation.ipv4` | [formats](formats.md#vipv4) |
| `v.ipv6` | a string is an IPv6 address | `validation.ipv6` | [formats](formats.md#vipv6) |
| `v.macAddress(.{ ... })` | a string is a MAC address | `validation.mac_address` | [formats](formats.md#vmacaddressoptions) |
| `v.json` | a string is a JSON object or array, nested at most 64 levels | `validation.json` | [encodings](encodings.md#vjson) |
| `v.jwt` | a string has the shape of a JWT | `validation.jwt` | [encodings](encodings.md#vjwt) |
| `v.base32` | a string is canonical padded base32 | `validation.base32` | [encodings](encodings.md#vbase32) |
| `v.base58` | a string uses the base58 alphabet | `validation.base58` | [encodings](encodings.md#vbase58) |
| `v.base64` | a string is canonical padded base64 | `validation.base64` | [encodings](encodings.md#vbase64) |
| `v.base64Url` | a string is canonical base64url without padding | `validation.base64_url` | [encodings](encodings.md#vbase64url) |
| `v.dataUri` | a string is an RFC 2397 data URL | `validation.data_uri` | [encodings](encodings.md#vdatauri) |
| `v.magnetUri` | a string is a magnet URI with an exact topic | `validation.magnet_uri` | [encodings](encodings.md#vmagneturi) |
| `v.mimeType` | a string is a media type with parameters | `validation.mime_type` | [encodings](encodings.md#vmimetype) |
| `v.locale` | a string is a well-formed BCP 47 language tag | `validation.locale` | [encodings](encodings.md#vlocale) |
| `v.semVer` | a string is a semantic version | `validation.sem_ver` | [encodings](encodings.md#vsemver) |
| `v.hexColor` | a string is a CSS hex color | `validation.hex_color` | [encodings](encodings.md#vhexcolor) |
| `v.rgbColor` | a string is a CSS `rgb()` or `rgba()` color | `validation.rgb_color` | [encodings](encodings.md#vrgbcolor) |
| `v.hslColor` | a string is a CSS `hsl()` or `hsla()` color | `validation.hsl_color` | [encodings](encodings.md#vhslcolor) |
| `v.uuid` | a string is a UUID: 8-4-4-4-12 hex digits | `validation.uuid` | [identifiers](identifiers.md#vuuid) |
| `v.mongoId` | a string is a MongoDB ObjectId: 24 hex digits | `validation.mongo_id` | [identifiers](identifiers.md#vmongoid) |
| `v.firebasePushId` | a string is a Firebase push ID | `validation.firebase_push_id` | [identifiers](identifiers.md#vfirebasepushid) |
| `v.hash(algorithm)` | a string is a hex digest of `algorithm` | `validation.hash` | [identifiers](identifiers.md#vhashalgorithm) |
| `v.creditCard` | a string is a card number with a valid Luhn check digit | `validation.credit_card` | [identifiers](identifiers.md#vcreditcard) |
| `v.isbn` | a string is an ISBN-10 or an ISBN-13 | `validation.isbn` | [identifiers](identifiers.md#visbn) |
| `v.isbn10` | a string is an ISBN-10 | `validation.isbn10` | [identifiers](identifiers.md#visbn10) |
| `v.isbn13` | a string is an ISBN-13 | `validation.isbn13` | [identifiers](identifiers.md#visbn13) |
| `v.issn` | a string is an ISSN, `NNNN-NNNC` | `validation.issn` | [identifiers](identifiers.md#vissn) |
| `v.ean` | a string is an EAN-8, EAN-13 or GTIN-14 | `validation.ean` | [identifiers](identifiers.md#vean) |
| `v.isin` | a string is an ISIN | `validation.isin` | [identifiers](identifiers.md#visin) |
| `v.isrc` | a string is an ISRC | `validation.isrc` | [identifiers](identifiers.md#visrc) |
| `v.bic` | a string is a BIC | `validation.bic` | [identifiers](identifiers.md#vbic) |
| `v.iban` | a string is an IBAN | `validation.iban` | [identifiers](identifiers.md#viban) |
| `v.btcAddress(network)` | a string is a Bitcoin address of `network` | `validation.btc_address` | [identifiers](identifiers.md#vbtcaddressnetwork) |
| `v.ethereumAddress` | a string is an Ethereum address | `validation.ethereum_address` | [identifiers](identifiers.md#vethereumaddress) |
| `v.date` | a string is a date `YYYY-MM-DD` | `validation.date` | [dates](dates.md#vdate) |
| `v.rfc3339` | a string is an RFC 3339 date-time with an offset | `validation.rfc3339` | [dates](dates.md#vrfc3339) |
| `v.iso8601` | a string is an ISO 8601 date or date-time | `validation.iso8601` | [dates](dates.md#viso8601) |
| `v.minDate(min)` | a date or a date-time is not before `min` | `validation.min_date` | [dates](dates.md#vmindatemin) |
| `v.maxDate(max)` | a date or a date-time is not after `max` | `validation.max_date` | [dates](dates.md#vmaxdatemax) |
| `v.militaryTime` | a string is a time `HH:MM` or `HHMM` | `validation.military_time` | [dates](dates.md#vmilitarytime) |
| `v.minItems(min)` | a slice has at least `min` items | `validation.min_items` | [lists](lists.md#vminitemsmin) |
| `v.maxItems(max)` | a slice has at most `max` items | `validation.max_items` | [lists](lists.md#vmaxitemsmax) |
| `v.uniqueItems` | no two items of a slice or an array are equal | `validation.unique_items` | [lists](lists.md#vuniqueitems) |
| `v.uniqueBy(.key)` | no two struct items of a slice or an array have equal values of the field `key` | `validation.unique_items` | [lists](lists.md#vuniquebykey) |
| `v.containsAll(.{ ... })` | every listed value is an item of a slice or an array | `validation.contains_all` | [lists](lists.md#vcontainsallvalues) |
| `v.containsNone(.{ ... })` | no item of a slice or an array is a listed value | `validation.contains_none` | [lists](lists.md#vcontainsnonevalues) |
| `v.each(rules)` | the rules of every item of a slice or an array | the inner rule's code | [lists](lists.md#veachrules) |
| `v.custom(code, message, f)` | your predicate `f` returns `true` | your `code` | [v.custom](#vcustom) |
