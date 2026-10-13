//! The date rules through the public API: on every kind of string field,
//! optional and inside `each`, with their codes and messages; the
//! date-form precondition of `minDate` and `maxDate` and the way to word it;
//! every predicate and bound rule on random bytes (no panic, and each rule
//! agrees with its predicate); `iso8601` passes every value that `date` or
//! `rfc3339` passes.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

/// A rule of this group with its predicate, code, default message, a value
/// it passes and one it fails.
const Case = struct {
    predicate_name: []const u8,
    rule: v.Rule,
    predicate: fn ([]const u8) bool,
    code: []const u8,
    message: []const u8,
    good: []const u8,
    bad: []const u8,
};

const cases = [_]Case{
    .{ .predicate_name = "isDate", .rule = v.date, .predicate = v.isDate, .code = "validation.date", .message = "must be a valid date in YYYY-MM-DD format", .good = "2024-02-29", .bad = "2023-02-29" },
    .{ .predicate_name = "isRfc3339", .rule = v.rfc3339, .predicate = v.isRfc3339, .code = "validation.rfc3339", .message = "must be a valid RFC 3339 date-time", .good = "2016-12-31T23:59:60Z", .bad = "2016-12-30T23:59:60Z" },
    .{ .predicate_name = "isIso8601", .rule = v.iso8601, .predicate = v.isIso8601, .code = "validation.iso8601", .message = "must be a valid ISO 8601 date", .good = "2020-W53-4T10:30+0530", .bad = "2021-W53-4" },
    .{ .predicate_name = "isMilitaryTime", .rule = v.militaryTime, .predicate = v.isMilitaryTime, .code = "validation.military_time", .message = "must be a valid time in 24-hour HH:MM format", .good = "2359", .bad = "2360" },
};

test "every value rule passes and fails a string with its code and default message" {
    inline for (cases) |c| {
        try h.expectRule(c.rule, c.code, c.message);
        try h.expectPass([]const u8, c.rule, c.good);
        try h.expectFail([]const u8, c.rule, c.bad, c.code, c.message);
        try h.expectFail([]const u8, c.rule, "", c.code, c.message);
        try testing.expect(c.predicate(c.good));
        try testing.expect(!c.predicate(c.bad));
    }
}

test "every value rule takes []u8, sentinel-terminated and optional strings, and string items through each" {
    inline for (cases) |c| {
        var good = c.good[0..c.good.len].*;
        var bad = c.bad[0..c.bad.len].*;
        try h.expectPass([]u8, c.rule, &good);
        try h.expectFail([]u8, c.rule, &bad, c.code, c.message);
        try h.expectPass([:0]const u8, c.rule, c.good ++ "");
        try h.expectFail([:0]const u8, c.rule, c.bad ++ "", c.code, c.message);
        try h.expectPass(?[]const u8, c.rule, null);
        try h.expectFail(?[]const u8, c.rule, c.bad, c.code, c.message);
        try h.expectPass(??[]const u8, c.rule, null);
        const List = h.One([]const ?[]const u8, v.each(c.rule));
        try h.expectValid(&List{ .x = &.{ c.good, null } });
        try h.expectAt(&List{ .x = &.{ null, c.bad } }, c.code, c.message, "x[1]");
        try h.expectFail([]const u8, c.rule.withMessage("another message"), c.bad, c.code, "another message");
    }
}

test "minDate and maxDate pass and fail by their bound, on optional fields and items too" {
    const after = v.minDate("2020-01-01");
    try h.expectPass([]const u8, after, "2020-01-01");
    try h.expectFail([]const u8, after, "2019-12-31", "validation.min_date", "must not be before 2020-01-01");
    try h.expectPass(?[]const u8, after, null);
    try h.expectFail(?[]const u8, after, "2019-12-31", "validation.min_date", "must not be before 2020-01-01");
    const before = v.maxDate("2020-12-31T23:59:59+02:00");
    try h.expectPass([:0]const u8, before, "2020-12-31T21:59:59Z");
    try h.expectFail([:0]const u8, before, "2020-12-31T22:00:00Z", "validation.max_date", "must not be after 2020-12-31T23:59:59+02:00");
    const Days = h.One([]const []const u8, v.each(.{ v.minDate("2020-01-01"), v.maxDate("2020-12-31") }));
    try h.expectValid(&Days{ .x = &.{ "2020-01-01", "2020-12-31" } });
    try h.expectAt(&Days{ .x = &.{ "2020-06-01", "2021-01-01" } }, "validation.max_date", "must not be after 2020-12-31", "x[1]");
    try h.expectFail([]const u8, v.minDate("2020-01-01").withMessage("from {min} on"), "2019-01-01", "validation.min_date", "from 2020-01-01 on");
}

test "a value of another form fails the bound with the date-form precondition; the form rule put first words it" {
    try h.expectFail([]const u8, v.minDate("1900-01-01"), "01.01.1990", "validation.date", "must be a valid date in YYYY-MM-DD format");
    try h.expectFail([]const u8, v.minDate("1900-01-01").withMessage("too early"), "01.01.1990", "validation.date", "must be a valid date in YYYY-MM-DD format");
    try h.expectFail([]const u8, .{ v.date.withMessage("use YYYY-MM-DD"), v.minDate("1900-01-01") }, "01.01.1990", "validation.date", "use YYYY-MM-DD");
    try h.expectFail([]const u8, .{ v.date.withMessage("use YYYY-MM-DD"), v.minDate("1900-01-01") }, "1899-12-31", "validation.min_date", "must not be before 1900-01-01");
    try h.expectFail([]const u8, v.maxDate("2030-01-01T00:00:00Z"), "2030-01-01", "validation.rfc3339", "must be a valid RFC 3339 date-time");
    try h.expectFail([]const u8, .{ v.rfc3339.withMessage("a date-time with an offset"), v.maxDate("2030-01-01T00:00:00Z") }, "2030-01-01", "validation.rfc3339", "a date-time with an offset");
}

/// Bytes that dates give a meaning to, so that random strings reach past the
/// first bytes of each parser.
const alphabet = "0123456789000111222599-::.,TtZz+- W\x00\xff\xc3";

/// A random string: from `alphabet` mostly, any byte sometimes, up to 40 bytes.
fn randomString(random: std.Random, buf: *[40]u8) []u8 {
    const len = random.uintLessThan(usize, buf.len + 1);
    for (buf[0..len]) |*c| {
        c.* = if (random.uintLessThan(u8, 10) == 0) random.int(u8) else alphabet[random.uintLessThan(usize, alphabet.len)];
    }
    return buf[0..len];
}

/// A random date-time that keeps the RFC 3339 layout, with random digits.
fn randomDateTime(random: std.Random, buf: *[40]u8) []u8 {
    const layout = "dddd-dd-ddTdd:dd:dd";
    for (buf[0..layout.len], layout) |*c, l| c.* = if (l == 'd') '0' + random.uintLessThan(u8, 10) else l;
    var len: usize = layout.len;
    if (random.boolean()) {
        buf[len] = '.';
        len += 1;
        for (0..random.uintLessThan(usize, 6)) |_| {
            buf[len] = '0' + random.uintLessThan(u8, 10);
            len += 1;
        }
    }
    const zones = [_][]const u8{ "Z", "z", "+00:00", "-23:59", "+14:00", "+24:00", "+05", "+0530", "" };
    const zone = zones[random.uintLessThan(usize, zones.len)];
    @memcpy(buf[len..][0..zone.len], zone);
    return buf[0 .. len + zone.len];
}

/// Whether `v.check` finds no violation of `rule` in a string field holding `s`.
fn rulePasses(comptime rule: v.Rule, s: []const u8) bool {
    var path_buf: [8]u8 = undefined;
    return v.check(&h.One([]const u8, rule){ .x = s }, &path_buf) == null;
}

test "every predicate and bound rule takes any bytes without a panic, and each rule agrees with its predicate" {
    var prng: std.Random.DefaultPrng = .init(0xda7e_5eed);
    const random = prng.random();
    var buf: [40]u8 = undefined;
    for (0..40_000) |n| {
        const s = if (n % 2 == 0) randomString(random, &buf) else randomDateTime(random, &buf);
        inline for (cases) |c| {
            if (rulePasses(c.rule, s) != c.predicate(s)) {
                std.debug.print("{s} and its rule disagree on \"{f}\"\n", .{ c.predicate_name, std.zig.fmtString(s) });
                return error.RuleDisagrees;
            }
        }
        // A bound rule passes a date only if date passes it, and a
        // date-time only if rfc3339 does.
        if (rulePasses(v.minDate("2000-01-01"), s) and !v.isDate(s)) return error.BoundWithoutForm;
        if (rulePasses(v.maxDate("2000-01-01T00:00:00+05:30"), s) and !v.isRfc3339(s)) return error.BoundWithoutForm;
        // iso8601 takes every date and every RFC 3339 date-time.
        if ((v.isDate(s) or v.isRfc3339(s)) and !v.isIso8601(s)) {
            std.debug.print("iso8601 rejects \"{f}\", which date or rfc3339 passes\n", .{std.zig.fmtString(s)});
            return error.NotASubset;
        }
    }
}

/// The example at the top of examples/dates.md.
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

test "the example of the dates page checks a booking" {
    comptime v.assertRules(Booking);
    try h.expectValid(&Booking{ .check_in = "2024-02-29", .created_at = "2024-01-01T10:00:00+02:00", .opening_hours = &.{ "09:00", "1800" } });
    try h.expectAll(&Booking{ .check_in = "29.02.2024", .created_at = "2024-01-01", .reminder = "2024-01-01T10:00", .opening_hours = &.{ "09:00", "24:00" } }, &.{
        .{ .code = "validation.date", .field = "check_in" },
        .{ .code = "validation.rfc3339", .field = "created_at" },
        .{ .code = "validation.rfc3339", .field = "reminder" },
        .{ .code = "validation.military_time", .field = "opening_hours[1]" },
    });
    try h.expectAt(&Booking{ .check_in = "2023-12-31", .created_at = "2024-01-01T10:00:00Z", .opening_hours = &.{} }, "validation.min_date", "must not be before 2024-01-01", "check_in");
    try h.expectAt(&Booking{ .check_in = "29.02.2024", .created_at = "2024-01-01T10:00:00Z", .opening_hours = &.{} }, "validation.date", "use YYYY-MM-DD", "check_in");
}
