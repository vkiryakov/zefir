# Dates

Rules for dates and times written as strings: Zig has no date type, so a DTO
carries a date as the string it arrived as. `v.date`, `v.rfc3339`, `v.iso8601`
and `v.militaryTime` check a format; `v.minDate` and `v.maxDate` bound a date
or a date-time.

```zig
const v = @import("validator");

const Booking = struct {
    check_in: []const u8,
    created_at: []const u8,
    reminder: ?[]const u8 = null,
    opening_hours: []const []const u8,

    pub const field_rules = .{
        .check_in = .{ v.date.withMessage("use YYYY-MM-DD"), v.minDate("2024-01-01") },
        .created_at = v.maxDate("2100-01-01T00:00:00Z"), // a date-time bound: the value needs an offset
        .reminder = v.rfc3339, // null skips the rule
        .opening_hours = v.each(v.militaryTime),
    };
};
```

## Contents

- [Common to all rules on this page](#common-to-all-rules-on-this-page)
- [v.date](#vdate)
- [v.rfc3339](#vrfc3339)
- [v.iso8601](#viso8601)
- [v.minDate(min)](#vmindatemin)
- [v.maxDate(max)](#vmaxdatemax)
- [v.militaryTime](#vmilitarytime)

## Common to all rules on this page

- **Field types:** a string — `[]const u8`, `[]u8`, `[:0]const u8` or `[:0]u8` —
  and `?T` and `??T` of these: `null` skips the rule. `[N]u8` is an array of
  numbers, not a string, and a list of strings needs `v.each(...)`: both are
  compile errors with that hint. On an integer or float field `v.minDate` and
  `v.maxDate` say `for a numeric timestamp use v.min` (`v.max`): a numeric
  timestamp is a number.
- **Digits** are ASCII `0-9` only; full-width and other Unicode digits fail.
  Nothing is trimmed: a space or a line break at either end fails. `""` fails
  every rule.
- **The calendar** is the proleptic Gregorian one for the years 0000-9999 and
  is always checked: `2020-02-29` exists, `2021-02-29` does not, and
  `1582-10-10` exists. ISO week 1 is the week of 4 January; a year has 53
  weeks when 1 January is a Thursday, or a Wednesday in a leap year.
- **Offsets** are numbers, from `-23:59` to `+23:59`; there is no time zone
  database. A date-time stands for the UTC instant "local time minus the
  offset" (RFC 3339 §4.2), so `Z`, `z`, `+00:00` and `-00:00` are the same.
- **Leap seconds:** second 60 passes only when the time minus the offset is
  23:59:60 UTC on the last day of a month. There is no table of the leap
  seconds that really happened, so `2017-01-31T23:59:60Z` passes in every
  version of zefir.
- **A space** may separate the date and the time in `v.rfc3339`, `v.iso8601`
  and the bounds of `v.minDate` and `v.maxDate`, as RFC 3339 §5.6 allows, and
  so may a lowercase `t`.
- **There is no "now":** rules have no clock. Check "in the future" or "at
  least 18 years old" in the handler, against the current time from
  `std.Io`.
- **Predicates:** `v.isDate(s)`, `v.isRfc3339(s)`, `v.isIso8601(s)` and
  `v.isMilitaryTime(s)`, each `fn (s: []const u8) bool`, give the answer of
  their rule on any bytes; `v.isDate` means "a `YYYY-MM-DD` string". `v.minDate`
  and `v.maxDate` have none: their parameter is the bound.
- The rules allocate nothing and never backtrack: `v.date` and
  `v.militaryTime` read at most 10 and 5 bytes, the others one pass over the
  input.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: <Type>.field_rules.<field>: date expects a string, field is u32
validator: <Type>.field_rules.<field>: rfc3339 expects a string, field is [32]u8; [N]u8 is an array of numbers, not a string: use []const u8
validator: <Type>.field_rules.<field>: iso8601 expects a string, field is []const []const u8; use v.each(v.iso8601)
validator: <Type>.field_rules.<field>: expected a rule, got the predicate isDate; use the rule v.date
```

## v.date

An RFC 3339 full-date, the `date` format of JSON Schema: `YYYY-MM-DD`.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` is exactly 10 bytes `YYYY-MM-DD`: a year 0000-9999, a
  month 01-12 and a day that exists in that month. No sign, no five-digit
  year, no basic form (`20200517`), no week or ordinal date, no time.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.date`.
- **Default message:** `must be a valid date in YYYY-MM-DD format`.
- **Placeholders:** none.
- **Predicate:** `v.isDate(s)`.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** none.

Examples:

| Value | Result |
| --- | --- |
| `2020-02-29` | passes |
| `0000-01-01` | passes |
| `2021-02-29` | `validation.date`: 2021 is not a leap year |
| `2020-04-31` | `validation.date` |
| `20200517` | `validation.date`: the basic form |
| `2020-05-17T00:00:00Z` | `validation.date`: a date-time |
| `2020-05-17 ` | `validation.date`: nothing is trimmed |

## v.rfc3339

An RFC 3339 date-time with an offset.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` is a `v.date`, then `T`, `t` or a space, then
  `HH:MM:SS` (hour 00-23, minute 00-59, second 00-60), an optional `.` and one
  or more fraction digits, and an offset: `Z`, `z` or `±HH:MM` with HH 00-23
  and MM 00-59. Second 60 passes only as a leap second (see above). No
  offset, `+05`, `+0530`, a comma before the fraction and a zone name such as
  `[Europe/Paris]` fail.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.rfc3339`.
- **Default message:** `must be a valid RFC 3339 date-time`.
- **Placeholders:** none.
- **Predicate:** `v.isRfc3339(s)`.
- **Complexity:** O(n): fraction digits have no limit; allocates nothing.
- **Deviations:** [D56](class_validator.md#deviations-from-validatorjs) (the day
  of the month is checked; second 60 only as a leap second).

Examples:

| Value | Result |
| --- | --- |
| `1985-04-12T23:20:50.52Z` | passes |
| `1996-12-19T16:39:57-08:00` | passes |
| `2020-05-17 10:30:00z` | passes: a space and a lowercase `z` |
| `1990-12-31T23:59:60Z` | passes: a leap second |
| `2020-05-17T10:30:60Z` | `validation.rfc3339`: not the end of a month |
| `2020-05-17T10:30:00` | `validation.rfc3339`: no offset |
| `2020-05-17T10:30:00+0530` | `validation.rfc3339`: the offset needs `:` |
| `2021-02-29T00:00:00Z` | `validation.rfc3339` |

## v.iso8601

ISO 8601 dates and date-times as zefir reads them: the grammar of RFC 3339
Appendix A, with the calendar always checked.

| Form | Extended | Basic | A time may follow |
| --- | --- | --- | --- |
| year | `2020` | — | no |
| year and month | `2020-05` | none (`202005` fails) | no |
| calendar date | `2020-05-17` | `20200517` | yes |
| ordinal date | `2020-138` | `2020138` | yes |
| week | `2020-W20` | `2020W20` | no |
| week date | `2020-W20-7` | `2020W207` | yes |
| time | `10`, `10:30`, `10:30:15` | `1030`, `103015` | — |
| fraction | `.5` or `,5` after the last component of the time, any number of digits | | |
| zone | `Z`, `z`, `+05`, `+05:30` | `+0530` | |
| end of the day | `24:00`, `24:00:00` | `2400`, `240000` (a fraction of zeros only) | |

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` has one of the forms above; a time follows `T`, `t` or
  a space after a complete calendar, ordinal or week date only. The basic and
  extended forms may differ between the date, the time and the zone
  (`2020-05-17T103000+0530` passes) but not inside one of them
  (`2020-0517` fails). The hour is 00-23, or 24 only with minutes 00 and zero
  seconds and fraction; the minute 00-59; the second 00-59, or 60 only with a
  zone and as a leap second. Every value that `v.date` or `v.rfc3339` passes
  passes too.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.iso8601`.
- **Default message:** `must be a valid ISO 8601 date`.
- **Placeholders:** none.
- **Predicate:** `v.isIso8601(s)`.
- **Complexity:** O(n); allocates nothing.
- **Deviations:** [D54](class_validator.md#deviations-from-validatorjs) (rejected
  although validator.js accepts: impossible dates, week 00 and 53 of a
  52-week year, signed years, other separators, a time after a reduced date),
  [D55](class_validator.md#deviations-from-validatorjs) (accepted although
  validator.js rejects: `t`, `24:00:00`, leap seconds, ordinal day 360, years
  0000-0999).

Examples:

| Value | Result |
| --- | --- |
| `2020` | passes |
| `2020-W53-4T23:59:60Z` | passes: 2020-12-31, a leap second |
| `2020-05-17T24:00` | passes: the end of the day |
| `2020-05-17T10:30,25` | passes |
| `2020-W00` | `validation.iso8601`: no week 0 |
| `2021-W53` | `validation.iso8601`: 2021 has 52 weeks |
| `2020-05T10:00` | `validation.iso8601`: a time after a reduced date |
| `2020-05-17T` | `validation.iso8601`: a separator without a time |
| `+2020-05-17` | `validation.iso8601`: a signed year |

## v.minDate(min)

A date or a date-time not before `min`.

- **Field types:** a string. On an integer or float field it is a compile error
  with the hint `for a numeric timestamp use v.min`.
- **Parameters:** `min`, a string known at compile time: an RFC 3339
  full-date (`"2020-01-01"`) or an RFC 3339 date-time with an offset
  (`"2020-01-01T00:00:00Z"`, `T`, `t` or a space, any fraction). Not `"now"` or
  `"today"`, and not the earliest value of its form (`"0000-01-01"`, or
  `0000-01-01T00:00:00+23:59` in any spelling), which every value passes.
- **Passes when:** the value has the form of the bound, then is not before
  it (inclusive). Dates compare by the calendar. Date-times compare as exact
  UTC instants: by day, then second, then fraction digit by digit, missing
  digits read as `0` (`.5` equals `.50`); a leap second comes after
  23:59:59.999… and before the next midnight.
- **`""`:** fails the precondition.
- **Precondition:** the form of the bound. With a date bound, a value that
  `v.date` fails reports `validation.date` /
  `must be a valid date in YYYY-MM-DD format`; with a date-time bound, a value
  that `v.rfc3339` fails reports `validation.rfc3339` /
  `must be a valid RFC 3339 date-time`. `.withMessage` does not change them:
  to word them, put the form rule first, as
  `.{ v.date.withMessage("use YYYY-MM-DD"), v.minDate("1900-01-01") }`
  ([Preconditions](README.md#preconditions)).
- **Code:** `validation.min_date`.
- **Default message:** `must not be before {min}`; `must not be before the
  minimum date` when the bound is longer than 493 bytes.
- **Placeholders:** `{min}`: the bound as written.
- **Predicate:** none.
- **Complexity:** O(n); the bound is parsed at compile time; allocates
  nothing.
- **Deviations:** [D57](class_validator.md#deviations-from-validatorjs) (a
  string bound fixed at compile time; the value needs the bound's form; exact
  instants), [D60](class_validator.md#deviations-from-validatorjs)
  (a bound after a `v.maxDate` bound is a compile error),
  [D61](class_validator.md#deviations-from-validatorjs) (`v.minDate("0000-01-01")` is a compile error).

A date-time bound needs date-time values with an offset; the forms do not mix,
since a date has no time zone. Next to `v.rfc3339` a date bound, next to
`v.date` a date-time bound, next to `v.militaryTime` any bound, and a bound of
the other form leave no value that passes: these are compile errors, and so
is `v.iso8601` next to a bound, since most of its values would fail the
bound's form.

Bounds of one form that leave no value are a compile error too
([D60](class_validator.md#deviations-from-validatorjs)): a `v.minDate` bound after a `v.maxDate`
bound of the same form. Every pair is checked, dates by the calendar and
date-times as exact instants, every digit of the fraction included; the error
names the latest `v.minDate` and the earliest `v.maxDate` bound (the earlier
rule on ties), in tuple order. Equal bounds are fine:
`.{ v.minDate("2020-01-01"), v.maxDate("2020-01-01") }` accepts one day.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: minDate("2020-02-30"): the bound must be an RFC 3339 full-date (2020-01-31) or date-time (2020-01-31T00:00:00Z)
validator: minDate("now"): "now" is not supported: rules have no clock; compare with the current time in the handler
validator: minDate("0000-01-01"): accepts every valid date; use v.date
validator: minDate("0000-01-01T00:00:00+23:59"): accepts every valid date-time; use v.rfc3339
validator: <Type>.field_rules.<field>: min_date expects a string, field is i64; for a numeric timestamp use v.min
validator: <Type>.field_rules.<field>: min_date expects a string, field is []const []const u8; use v.each(v.minDate("2020-01-01"))
validator: <Type>.field_rules.<field>: rfc3339 and min_date("2020-01-01") need different forms (date-time vs date); no value can pass
validator: <Type>.field_rules.<field>: min_date("2020-01-01") accepts only the form of its bound, so most iso8601 values would fail it; use v.date instead of v.iso8601
validator: <Type>.field_rules.<field>: minDate must be called, e.g. v.minDate("2020-01-01")
validator: <Type>.field_rules.<field>: min_date("2021-01-01") and max_date("2020-12-31") contradict; no value can pass
validator: <Type>.field_rules.<field>: min_date("2020-01-01T00:00:00+01:00") and max_date("2019-12-31T22:59:59Z") contradict; no value can pass
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.minDate("2020-01-01")` | `2020-01-01` | passes: the bound is inclusive |
| `v.minDate("2020-01-01")` | `2019-12-31` | `validation.min_date`: `must not be before 2020-01-01` |
| `v.minDate("2020-01-01")` | `2020-01-01T00:00:00Z` | `validation.date`: the bound is a date |
| `v.minDate("2020-01-01T00:00:00Z")` | `2019-12-31T19:00:00-05:00` | passes: the same instant |
| `v.minDate("2020-01-01T00:00:00Z")` | `2019-12-31T23:59:59.999999999Z` | `validation.min_date` |
| `v.minDate("2020-01-01T00:00:00Z")` | `2020-01-01` | `validation.rfc3339`: the bound is a date-time |
| `v.minDate("2020-01-01T00:00:00.5Z")` | `2020-01-01T00:00:00.49999Z` | `validation.min_date` |

## v.maxDate(max)

A date or a date-time not after `max`.

- **Field types:** a string. On an integer or float field it is a compile error
  with the hint `for a numeric timestamp use v.max`.
- **Parameters:** `max`, a string known at compile time, as for `v.minDate`.
  Not `"now"` or `"today"`, and not `"9999-12-31"`, which every date passes.
  A date-time bound is never vacuous: fractions have no last digit.
- **Passes when:** the value has the form of the bound, then is not after it
  (inclusive), compared as for `v.minDate`.
- **`""`:** fails the precondition.
- **Precondition:** the form of the bound, as for `v.minDate`.
- **Code:** `validation.max_date`.
- **Default message:** `must not be after {max}`; `must not be after the
  maximum date` when the bound is longer than 494 bytes.
- **Placeholders:** `{max}`: the bound as written.
- **Predicate:** none.
- **Complexity:** O(n); the bound is parsed at compile time; allocates
  nothing.
- **Deviations:** [D57](class_validator.md#deviations-from-validatorjs),
  [D60](class_validator.md#deviations-from-validatorjs) (a bound before a `v.minDate` bound is a
  compile error), [D61](class_validator.md#deviations-from-validatorjs)
  (`v.maxDate("9999-12-31")` is a compile error).

Next to other rules, `v.maxDate` behaves as `v.minDate`: forms do not mix,
`v.iso8601` next to it is a compile error, and so is a bound before a
`v.minDate` bound of the same form.

Compile errors (`<Type>.field_rules.<field>` is the entry of your struct):

```text
validator: maxDate("2020-12-32"): the bound must be an RFC 3339 full-date (2020-01-31) or date-time (2020-01-31T00:00:00Z)
validator: maxDate("today"): "now" is not supported: rules have no clock; compare with the current time in the handler
validator: maxDate("9999-12-31"): accepts every valid date; use v.date
validator: <Type>.field_rules.<field>: max_date expects a string, field is f64; for a numeric timestamp use v.max
validator: <Type>.field_rules.<field>: min_date("2020-01-01") and max_date("2020-12-31T00:00:00Z") need different forms (date vs date-time); no value can pass
validator: <Type>.field_rules.<field>: maxDate must be called, e.g. v.maxDate("2020-12-31")
```

Examples:

| Rule | Value | Result |
| --- | --- | --- |
| `v.maxDate("2020-12-31")` | `2020-12-31` | passes |
| `v.maxDate("2020-12-31")` | `2021-01-01` | `validation.max_date`: `must not be after 2020-12-31` |
| `v.maxDate("2016-12-31T23:59:59Z")` | `2017-01-01T08:59:59+09:00` | passes: the same instant |
| `v.maxDate("2016-12-31T23:59:59Z")` | `2016-12-31T23:59:59.000001Z` | `validation.max_date` |
| `v.maxDate("2016-12-31T23:59:59Z")` | `2016-12-31T23:59:60Z` | `validation.max_date`: the leap second comes after |
| `v.maxDate("2020-12-31")` | `2020-12-31\n` | `validation.date`: nothing is trimmed |

## v.militaryTime

A 24-hour time, as class-validator's `IsMilitaryTime` checks it.

- **Field types:** a string.
- **Parameters:** none.
- **Passes when:** `s` is `HH:MM` or `HHMM` from 00:00 to 23:59. No seconds, no
  `24:00`, no single-digit hour or minute, no zone.
- **`""`:** fails.
- **Precondition:** none.
- **Code:** `validation.military_time`.
- **Default message:** `must be a valid time in 24-hour HH:MM format`; `HHMM`
  passes too.
- **Placeholders:** none.
- **Predicate:** `v.isMilitaryTime(s)`.
- **Complexity:** O(1); allocates nothing.
- **Deviations:** none.

A time of day and a date never match: `v.militaryTime` next to `v.minDate` or
`v.maxDate` is a compile error. A number field has no time rule:
`v.range(0, 2359)` passes 1260, which is not a time.

Examples:

| Value | Result |
| --- | --- |
| `09:30` | passes |
| `2359` | passes |
| `24:00` | `validation.military_time` |
| `9:30` | `validation.military_time`: one digit |
| `09:30:00` | `validation.military_time`: seconds |
| ` 09:30` | `validation.military_time`: nothing is trimmed |

See also: [the overview](README.md) · [Coming from class-validator](class_validator.md)
