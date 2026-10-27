//! Tests of the cron expressions of scheduler.Schedule: the dialect, the
//! texts of what it refuses, the rules of `next`, and `next` against a
//! plain walk over the calendar of std on 2000 random cases. `t0` is
//! 2026-10-24T00:00:00Z, a Saturday.

const std = @import("std");
const testing = std.testing;
const epoch = std.time.epoch;
const scheduler = @import("../root.zig");
const Schedule = scheduler.Schedule;
const Instant = scheduler.Instant;
const Diagnostics = scheduler.Diagnostics;

const t0: Instant = .fromUtc(2026, 10, 24, 0, 0, 0, .h24);

/// `e` copied into `buffer`: a slice the compiler does not know, so that
/// `.cron` reads it at run time.
fn runtime(buffer: []u8, e: []const u8) []const u8 {
    @memcpy(buffer[0..e.len], e);
    return buffer[0..e.len];
}

fn expectNext(expected: []const u8, s: Schedule, after: Instant) !void {
    var buffer: [64]u8 = undefined;
    const moment = s.next(after) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{moment}));
}

fn expectText(expected: []const u8, s: Schedule) !void {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{s}));
}

test "a cron literal is checked and built at compile time" {
    const s: Schedule = .cron("0 30 2 * * *");
    comptime std.debug.assert(s.internal == .cron);
    try expectText("cron 0 30 2 * * *", s);
    try expectNext("2026-10-24T02:30:00.000Z", s, t0);
}

test "cron parses the fields of the dialect" {
    const valid = [_][]const u8{
        "0 30 2 * * *", "*/15 * * * *", "0 9 * * MON-FRI", "0 0 1,15 * *", "0 0 * jan,JUL *", "0 0 1-20/5 * *",
        "@yearly",      "@annually",    "@monthly",        "@weekly",      "@daily",          "@midnight",
        "@hourly",      "@Daily",       "  0 0 * * *\t",
    };
    for (valid) |e| {
        var buffer: [64]u8 = undefined;
        const s: Schedule = .cron(runtime(&buffer, e));
        var d: Diagnostics = .{};
        s.check(&d) catch {
            std.debug.print("{s}: {s}\n", .{ e, d.message() });
            return error.TestUnexpectedResult;
        };
    }
    var buffer: [64]u8 = undefined;
    try expectNext("2026-10-24T02:30:00.000Z", .cron(runtime(&buffer, "0 30 2 * * *")), t0);
    try expectNext("2026-10-24T00:15:00.000Z", .cron(runtime(&buffer, "*/15 * * * *")), t0);
    try expectNext("2026-10-26T09:00:00.000Z", .cron(runtime(&buffer, "0 9 * * MON-FRI")), t0);
    try expectNext("2026-11-01T00:00:00.000Z", .cron(runtime(&buffer, "0 0 1,15 * *")), t0);
    try expectNext("2027-01-01T00:00:00.000Z", .cron(runtime(&buffer, "0 0 * jan,JUL *")), t0);
    try expectNext("2026-11-01T00:00:00.000Z", .cron(runtime(&buffer, "0 0 1-20/5 * *")), t0);
    try expectNext("2026-11-06T00:00:00.000Z", .cron(runtime(&buffer, "0 0 1-20/5 * *")), .fromUtc(2026, 11, 1, 0, 0, 0, .h24));
    try expectNext("2027-01-01T00:00:00.000Z", .cron(runtime(&buffer, "@yearly")), t0);
    try expectNext("2026-11-01T00:00:00.000Z", .cron(runtime(&buffer, "@monthly")), t0);
    try expectNext("2026-10-24T01:00:00.000Z", .cron(runtime(&buffer, "@hourly")), t0);
    try expectNext("2026-10-25T00:00:00.000Z", .cron(runtime(&buffer, "@midnight")), t0);

    // Sunday is 0 and 7.
    var seven_buffer: [16]u8 = undefined;
    var zero_buffer: [16]u8 = undefined;
    const seven: Schedule = .cron(runtime(&seven_buffer, "0 0 * * 7"));
    const zero: Schedule = .cron(runtime(&zero_buffer, "0 0 * * 0"));
    var after = t0;
    for (0..50) |_| {
        try testing.expectEqual(zero.next(after), seven.next(after));
        after = after.add(.fromSeconds(17 * 60 * 60 + 13));
    }
    try expectNext("2026-10-25T00:00:00.000Z", seven, t0);
}

fn expectRefused(expected: []const u8, e: []const u8) !void {
    var buffer: [64]u8 = undefined;
    const s: Schedule = .cron(runtime(&buffer, e));
    var d: Diagnostics = .{};
    s.check(&d) catch |err| {
        try testing.expectEqual(error.InvalidArgument, err);
        try testing.expectEqualStrings(expected, d.message());
        try testing.expectEqual(@as(?Instant, null), s.next(t0));
        return;
    };
    std.debug.print("cron \"{s}\" was taken\n", .{e});
    return error.TestUnexpectedResult;
}

test "cron refuses what is not in v1, by field and position" {
    const fields = "an expression has 5 fields (minute, hour, day of the month, month, day of the week) or 6, the second first";
    try expectRefused("cron \"0 0 ? * *\": field 3, the day of the month, \"?\": ? is not in v1; write *", "0 0 ? * *");
    try expectRefused("cron \"0 0 L * *\": field 3, the day of the month, \"L\": L is not in v1", "0 0 L * *");
    try expectRefused("cron \"0 0 15W * *\": field 3, the day of the month, \"15W\": W is not in v1", "0 0 15W * *");
    try expectRefused("cron \"0 0 * * 5#3\": field 5, the day of the week, \"5#3\": # is not in v1", "0 0 * * 5#3");
    try expectRefused("cron \"0 0 * * 5L\": field 5, the day of the week, \"5L\": L is not in v1", "0 0 * * 5L");
    try expectRefused("cron \"H * * * *\": field 1, the minute, \"H\": H is not in v1", "H * * * *");
    try expectRefused("cron \"H/5 * * * * *\": field 1, the second, \"H/5\": H is not in v1", "H/5 * * * * *");
    try expectRefused("cron \"0 0 0 1 1 * 2030\": 7 fields; " ++ fields ++ "; a year is not in v1", "0 0 0 1 1 * 2030");
    try expectRefused("cron \"0 0 * *\": 4 fields; " ++ fields, "0 0 * *");
    try expectRefused("cron \"\": " ++ fields, "");
    try expectRefused("cron \"  \": " ++ fields, "  ");
    try expectRefused("cron \"5/15 * * * *\": field 1, the minute, \"5/15\": a step goes after * or a range, as */15 or 5-59/15", "5/15 * * * *");
    try expectRefused("cron \"@reboot\": @reboot is not in v1", "@reboot");
    try expectRefused("cron \"@every 5m\": @every is not in v1; a step from the epoch is .everySeconds(n), .everyMinutes(n) or .everyHours(n)", "@every 5m");
    try expectRefused("cron \"@often\": @often is no macro; the macros are @yearly, @annually, @monthly, @weekly, @daily, @midnight and @hourly", "@often");
    try expectRefused("cron \"@daily 5\": a macro stands alone", "@daily 5");
    try expectRefused("cron \"60 * * * *\": field 1, the minute, \"60\": a minute is 0–59", "60 * * * *");
    try expectRefused("cron \"60 0 0 * * *\": field 1, the second, \"60\": a second is 0–59", "60 0 0 * * *");
    try expectRefused("cron \"0 24 * * *\": field 2, the hour, \"24\": an hour is 0–23", "0 24 * * *");
    try expectRefused("cron \"0 0 0 * *\": field 3, the day of the month, \"0\": a day of the month is 1–31", "0 0 0 * *");
    try expectRefused("cron \"0 0 0 0 * *\": field 4, the day of the month, \"0\": a day of the month is 1–31", "0 0 0 0 * *");
    try expectRefused("cron \"0 0 1 13 *\": field 4, the month, \"13\": a month is 1–12 or JAN–DEC", "0 0 1 13 *");
    try expectRefused("cron \"0 0 1 jxn *\": field 4, the month, \"jxn\": a month is 1–12 or JAN–DEC", "0 0 1 jxn *");
    try expectRefused("cron \"0 0 * * 8\": field 5, the day of the week, \"8\": a day of the week is 0–7 or SUN–SAT; Sunday is 0 and 7", "0 0 * * 8");
    try expectRefused("cron \"0 0 * * jan\": field 5, the day of the week, \"jan\": a day of the week is 0–7 or SUN–SAT; Sunday is 0 and 7", "0 0 * * jan");
    try expectRefused("cron \"1-60 * * * *\": field 1, the minute, \"1-60\": a minute is 0–59", "1-60 * * * *");
    try expectRefused("cron \"*/0 * * * *\": field 1, the minute, \"*/0\": a step is 1 or more", "*/0 * * * *");
    try expectRefused("cron \"*/x * * * *\": field 1, the minute, \"*/x\": a step is 1 or more", "*/x * * * *");
    try expectRefused("cron \"1,,2 * * * *\": field 1, the minute, \"1,,2\": a list has no empty item", "1,,2 * * * *");
    try expectRefused("cron \"0 0 31 4,6,9,11 *\": day 31 never comes in April, June, September or November, and the day of the week is *", "0 0 31 4,6,9,11 *");
    try expectRefused("cron \"0 0 30 2 *\": day 30 never comes in February, and the day of the week is *", "0 0 30 2 *");
    try expectRefused("cron \"0 0 30,31 2 *\": days 30 and 31 never come in February, and the day of the week is *", "0 0 30,31 2 *");
    try expectRefused("cron \"0 0 31 2,4 *\": day 31 never comes in February or April, and the day of the week is *", "0 0 31 2,4 *");
    // A byte that is not text shows as an escape.
    try expectRefused("cron \"0 0 \\xff * *\": field 3, the day of the month, \"\\xff\": a day of the month is 1–31", "0 0 \xff * *");
}

/// `e` with its first `item` in place of `with`, in `buffer`.
fn replaced(buffer: []u8, e: []const u8, item: []const u8, with: []const u8) ![]const u8 {
    const at = std.mem.find(u8, e, item) orelse return error.TestUnexpectedResult;
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ e[0..at], with, e[at + item.len ..] });
}

/// Fails unless `e` is taken, and says so.
fn expectTaken(e: []const u8) !Schedule {
    const s: Schedule = .cron(e);
    var d: Diagnostics = .{};
    s.check(&d) catch {
        std.debug.print("cron \"{s}\": {s}\n", .{ e, d.message() });
        return error.TestUnexpectedResult;
    };
    return s;
}

test "a range that goes down is refused with the line that wraps it round the end of its field" {
    const Case = struct {
        /// The expression, the field at fault, and its item that goes down.
        e: []const u8,
        field: []const u8,
        item: []const u8,
        /// The refusal after the item, but for the line it says to write.
        rule: []const u8,
        line: []const u8,
        /// The values of the field that the item means wrapped round its
        /// end.
        values: []const u8,
    };
    const wraps = "a range goes up and does not wrap: write ";
    const seven = "a range goes up, and Sunday is 7 too: write ";
    const zero = "a range goes up, and Sunday is 0 too: write ";
    const weekday = "field 5, the day of the week";
    const hour = "field 2, the hour";
    const cases = [_]Case{
        .{ .e = "0 0 * * FRI-MON", .field = weekday, .item = "FRI-MON", .rule = wraps, .line = "FRI-SAT,SUN-MON", .values = "5,6,0,1" },
        .{ .e = "0 0 * * fri-mon", .field = weekday, .item = "fri-mon", .rule = wraps, .line = "fri-sat,sun-mon", .values = "5,6,0,1" },
        .{ .e = "0 0 * * SAT-SUN", .field = weekday, .item = "SAT-SUN", .rule = seven, .line = "SAT-7", .values = "6,0" },
        .{ .e = "0 0 * * MON-SUN", .field = weekday, .item = "MON-SUN", .rule = seven, .line = "MON-7", .values = "1,2,3,4,5,6,0" },
        .{ .e = "0 0 * * MON-SUN/2", .field = weekday, .item = "MON-SUN/2", .rule = seven, .line = "MON-7/2", .values = "1,3,5,0" },
        .{ .e = "0 0 * * 7-MON", .field = weekday, .item = "7-MON", .rule = zero, .line = "0-MON", .values = "0,1" },
        .{ .e = "0 22-2 * * *", .field = hour, .item = "22-2", .rule = wraps, .line = "22-23,0-2", .values = "22,23,0,1,2" },
        .{ .e = "0 0 22-2 * * *", .field = "field 3, the hour", .item = "22-2", .rule = wraps, .line = "22-23,0-2", .values = "22,23,0,1,2" },
        .{ .e = "0 23-1 * * *", .field = hour, .item = "23-1", .rule = wraps, .line = "23,0-1", .values = "23,0,1" },
        .{ .e = "0 22-2/2 * * *", .field = hour, .item = "22-2/2", .rule = wraps, .line = "22,0-2/2", .values = "22,0,2" },
        .{ .e = "0 21-1/2 * * *", .field = hour, .item = "21-1/2", .rule = wraps, .line = "21-23/2,1", .values = "21,23,1" },
        .{ .e = "0 22-0/4 * * *", .field = hour, .item = "22-0/4", .rule = wraps, .line = "22", .values = "22" },
        .{ .e = "0 22-2/99999999999999999999 * * *", .field = hour, .item = "22-2/99999999999999999999", .rule = wraps, .line = "22", .values = "22" },
        .{ .e = "50-10/5 * * * *", .field = "field 1, the minute", .item = "50-10/5", .rule = wraps, .line = "50-59/5,0-10/5", .values = "50,55,0,5,10" },
        .{ .e = "0 0 25-5 * *", .field = "field 3, the day of the month", .item = "25-5", .rule = wraps, .line = "25-31,1-5", .values = "25,26,27,28,29,30,31,1,2,3,4,5" },
        .{ .e = "0 0 1 NOV-FEB *", .field = "field 4, the month", .item = "NOV-FEB", .rule = wraps, .line = "NOV-DEC,JAN-FEB", .values = "11,12,1,2" },
        .{ .e = "0 0 1 11-2 *", .field = "field 4, the month", .item = "11-2", .rule = wraps, .line = "11-12,1-2", .values = "11,12,1,2" },
    };
    for (cases) |c| {
        var message: [192]u8 = undefined;
        try expectRefused(try std.fmt.bufPrint(&message, "cron \"{s}\": {s}, \"{s}\": {s}{s}", .{ c.e, c.field, c.item, c.rule, c.line }), c.e);
        // The line to write is taken, and comes when the values come.
        var line_buffer: [64]u8 = undefined;
        var values_buffer: [64]u8 = undefined;
        const line = try expectTaken(try replaced(&line_buffer, c.e, c.item, c.line));
        const values = try expectTaken(try replaced(&values_buffer, c.e, c.item, c.values));
        var after = t0;
        for (0..40) |_| {
            const moment = values.next(after) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(?Instant, moment), line.next(after));
            after = moment;
        }
    }
}

test "next follows the rules of the dialect" {
    var buffer: [32]u8 = undefined;
    // 29 February waits for a leap year: 2100 is none.
    try expectNext("2104-02-29T00:00:00.000Z", .cron(runtime(&buffer, "0 0 29 2 *")), .fromUtc(2096, 3, 1, 0, 0, 0, .h24));
    // The 13th or a Friday.
    try expectNext("2026-10-30T00:00:00.000Z", .cron(runtime(&buffer, "0 0 13 * 5")), t0);
    // */2 restricts the day of the month, so either day matches: the 25th.
    try expectNext("2026-10-25T00:00:00.000Z", .cron(runtime(&buffer, "0 0 */2 * 1")), t0);
    // A day the next month lacks is skipped.
    try expectNext("2026-12-31T00:00:00.000Z", .cron(runtime(&buffer, "0 0 31 * *")), .fromUtc(2026, 10, 31, 0, 0, 0, .h24));
    // Six fields: the second first; strictly after the moment.
    try expectNext("2026-10-25T10:15:30.000Z", .cron(runtime(&buffer, "30 15 10 * * *")), .fromUtc(2026, 10, 24, 10, 15, 30, .h24));
    try expectNext("2026-10-24T10:15:30.000Z", .cron(runtime(&buffer, "30 15 10 * * *")), .fromUtc(2026, 10, 24, 10, 15, 29, .h24));
    try expectNext("2026-10-25T00:00:00.000Z", .cron(runtime(&buffer, "@weekly")), t0);
    // A moment with milliseconds goes on to the next whole second.
    try expectNext("2026-10-24T00:00:01.000Z", .cron(runtime(&buffer, "* * * * * *")), t0.add(.fromMilliseconds(500)));
    try expectNext("2026-10-24T00:00:01.000Z", .cron(runtime(&buffer, "* * * * * *")), t0);
    try expectNext("2026-10-24T00:01:00.000Z", .cron(runtime(&buffer, "* * * * *")), t0.add(.fromMilliseconds(999)));
    // The carry runs through the minute, the hour, the day, the month and
    // the year.
    try expectNext("2027-01-01T00:00:00.000Z", .cron(runtime(&buffer, "0 0 0 1 1 *")), .fromUtc(2026, 12, 31, 23, 59, 59, .h24));
    // Both day fields restricted: the 1st or a Monday.
    try expectNext("2026-10-26T00:00:00.000Z", .cron(runtime(&buffer, "0 0 1 * mon")), t0);
    // The last moment of 9999 ends a schedule.
    try testing.expectEqual(@as(?Instant, null), Schedule.cron(runtime(&buffer, "0 0 1 1 *")).next(.fromUtc(9999, 6, 1, 0, 0, 0, .h24)));
}

test "a cron schedule writes its fields and reads back" {
    try expectText("cron 0 30 2 * * *", .cron("0  30 2 * * *"));
    try expectText("cron 0 9 * * MON-FRI", .cron("\t0 9 * * MON-FRI "));
    try expectText("cron @daily", .cron("@daily"));

    const daily = try Schedule.parse("cron @daily", null);
    try expectText("cron @daily", daily);
    try testing.expectEqual(Schedule.cron("0 0 * * *").next(t0), daily.next(t0));

    const back = try Schedule.parse("cron 0 30 2 * * *", null);
    try expectText("cron 0 30 2 * * *", back);
    try testing.expectEqual(Schedule.cron("0 30 2 * * *").next(t0), back.next(t0));

    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, Schedule.parse("cron 0 0 30 2 *", &d));
    try testing.expectEqualStrings("plan \"cron 0 0 30 2 *\": day 30 never comes in February, and the day of the week is *", d.message());
    try testing.expectError(error.InvalidArgument, Schedule.parse("cron", &d));
}

/// What a random expression means, by the test's own reading of the
/// dialect: the second, the minute, the hour, the day of the month (1–31),
/// the month (1–12) and the day of the week (Sunday 0).
const Model = struct {
    seconds: [60]bool = @splat(false),
    minutes: [60]bool = @splat(false),
    hours: [24]bool = @splat(false),
    days: [32]bool = @splat(false),
    months: [13]bool = @splat(false),
    weekdays: [7]bool = @splat(false),
    any_day: bool = false,
    any_weekday: bool = false,
};

const Spec = struct { min: u8, max: u8, star_max: u8, names: []const []const u8 = &.{}, first_name: u8 = 0 };
const second_spec: Spec = .{ .min = 0, .max = 59, .star_max = 59 };
const minute_spec: Spec = second_spec;
const hour_spec: Spec = .{ .min = 0, .max = 23, .star_max = 23 };
const day_spec: Spec = .{ .min = 1, .max = 31, .star_max = 31 };
const month_spec: Spec = .{ .min = 1, .max = 12, .star_max = 12, .names = &.{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }, .first_name = 1 };
const weekday_spec: Spec = .{ .min = 0, .max = 7, .star_max = 6, .names = &.{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" } };

/// Writes `v` as a number or, now and then, as its name in a random case.
fn writeValue(w: *std.Io.Writer, random: std.Random, spec: Spec, v: u8) !void {
    if (spec.names.len != 0 and v >= spec.first_name and v - spec.first_name < spec.names.len and random.boolean()) {
        for (spec.names[v - spec.first_name]) |c| try w.writeByte(if (random.boolean()) std.ascii.toUpper(c) else c);
        return;
    }
    try w.print("{d}", .{v});
}

fn mark(set: []bool, v: u8) void {
    // 7 in the day of the week is Sunday.
    set[if (set.len == 7 and v == 7) 0 else v] = true;
}

/// Writes one item of a list, a value, a range or a range with a step,
/// and marks what it means.
fn writeItem(w: *std.Io.Writer, random: std.Random, spec: Spec, set: []bool) !void {
    const a = random.intRangeAtMost(u8, spec.min, spec.max);
    switch (random.uintLessThan(u8, 3)) {
        0 => {
            try writeValue(w, random, spec, a);
            mark(set, a);
        },
        else => |form| {
            const b = random.intRangeAtMost(u8, a, spec.max);
            try writeValue(w, random, spec, a);
            try w.writeByte('-');
            try writeValue(w, random, spec, b);
            const step: u8 = if (form == 2) random.intRangeAtMost(u8, 1, b - a + 2) else 1;
            if (form == 2) try w.print("/{d}", .{step});
            var v = a;
            while (v <= b) : (v += step) mark(set, v);
        },
    }
}

/// Writes a random field and marks what it means; true when it is `*`.
fn writeField(w: *std.Io.Writer, random: std.Random, spec: Spec, set: []bool, star_odds: u8) !bool {
    if (random.uintLessThan(u8, 100) < star_odds) {
        try w.writeByte('*');
        var v = spec.min;
        while (v <= spec.star_max) : (v += 1) mark(set, v);
        return true;
    }
    switch (random.uintLessThan(u8, 3)) {
        0 => {
            const step = random.intRangeAtMost(u8, 1, spec.star_max - spec.min + 2);
            try w.print("*/{d}", .{step});
            var v = spec.min;
            while (v <= spec.star_max) : (v += step) mark(set, v);
        },
        1 => try writeItem(w, random, spec, set),
        else => {
            const items = random.intRangeAtMost(u8, 2, 3);
            for (0..items) |i| {
                if (i != 0) try w.writeByte(',');
                try writeItem(w, random, spec, set);
            }
        },
    }
    return false;
}

/// How far `next` looks ahead, by the dialect: 9 years.
const search_days = 9 * 365 + 3;

/// The first moment of `m` strictly after `after`: a walk over the days of
/// std's calendar from the day of `after`, and in a day that matches, over
/// its hours, minutes and seconds in order.
fn walk(m: Model, after: i64) ?i64 {
    const start = @divFloor(after, 1000) + 1;
    var day_number = @divFloor(start, 86_400);
    var from_second = @mod(start, 86_400);
    const year_day = (epoch.EpochDay{ .day = @intCast(day_number) }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var year = year_day.year;
    var month = month_day.month.numeric();
    var day: u8 = month_day.day_index + 1;
    // 1970-01-01 was a Thursday, 4 with Sunday 0.
    var weekday: u3 = @intCast(@mod(day_number + 4, 7));
    for (0..search_days + 1) |_| {
        const by_day = m.days[day];
        const by_weekday = m.weekdays[weekday];
        const matches = if (m.any_day and m.any_weekday) true else if (m.any_day) by_weekday else if (m.any_weekday) by_day else by_day or by_weekday;
        if (matches and m.months[month]) {
            if (firstSecond(m, from_second)) |second| return (day_number * 86_400 + second) * 1000;
        }
        day_number += 1;
        from_second = 0;
        weekday = if (weekday == 6) 0 else weekday + 1;
        day += 1;
        if (day > epoch.getDaysInMonth(year, @fromBackingInt(month))) {
            day = 1;
            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
        }
    }
    return null;
}

fn firstSecond(m: Model, from: i64) ?i64 {
    for (0..24) |hour| {
        if (!m.hours[hour] or @as(i64, @intCast(hour)) * 3600 + 3599 < from) continue;
        for (0..60) |minute| {
            if (!m.minutes[minute] or @as(i64, @intCast(hour * 3600 + minute * 60 + 59)) < from) continue;
            for (0..60) |second| {
                const at: i64 = @intCast(hour * 3600 + minute * 60 + second);
                if (m.seconds[second] and at >= from) return at;
            }
        }
    }
    return null;
}

test "next agrees with a plain walk on 2000 random cases" {
    var prng = std.Random.DefaultPrng.init(0x5c4ed01e);
    const random = prng.random();
    const first = Instant.fromUtc(2026, 1, 1, 0, 0, 0, .h24).unix_ms;
    const last = Instant.fromUtc(2110, 12, 31, 23, 59, 59, .h24).unix_ms;
    var found: usize = 0;
    for (0..2000) |case| {
        var buffer: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        var m: Model = .{};
        if (random.boolean()) {
            _ = try writeField(&w, random, second_spec, &m.seconds, 30);
            try w.writeByte(' ');
        } else {
            m.seconds[0] = true;
        }
        _ = try writeField(&w, random, minute_spec, &m.minutes, 30);
        try w.writeByte(' ');
        _ = try writeField(&w, random, hour_spec, &m.hours, 30);
        try w.writeByte(' ');
        m.any_day = try writeField(&w, random, day_spec, &m.days, 40);
        try w.writeByte(' ');
        _ = try writeField(&w, random, month_spec, &m.months, 40);
        try w.writeByte(' ');
        m.any_weekday = try writeField(&w, random, weekday_spec, &m.weekdays, 40);
        const expression = w.buffered();

        var after = random.intRangeAtMost(i64, first, last);
        if (random.boolean()) after -= @mod(after, 1000);
        const expected = walk(m, after);
        const got = Schedule.cron(expression).next(.fromUnixMs(after));
        if (expected != null) found += 1;
        const got_ms: ?i64 = if (got) |moment| moment.unix_ms else null;
        const same = if (expected) |e| (if (got_ms) |g| e == g else false) else got_ms == null;
        if (!same) {
            std.debug.print("case {d}: cron \"{s}\" after {f}: expected {?d}, got {?d}\n", .{ case, expression, Instant.fromUnixMs(after), expected, got_ms });
            return error.TestUnexpectedResult;
        }
    }
    // Nearly every random expression has a moment: the cases test `next`,
    // not only the refusals.
    try testing.expect(found > 1900);
}
