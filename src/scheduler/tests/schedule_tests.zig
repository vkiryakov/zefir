//! Tests of scheduler.Schedule without cron: steps from the epoch, times
//! of day on the 12- and 24-hour clocks, fixedDelay, the checks of values
//! known at run time and the canonical text. `t0` is
//! 2026-10-24T00:00:00Z, a Saturday.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const Schedule = scheduler.Schedule;
const Instant = scheduler.Instant;
const Diagnostics = scheduler.Diagnostics;

const t0: Instant = .fromUtc(2026, 10, 24, 0, 0, 0, .h24);

/// The moments of `s` one after another from `from`, each `next` from the
/// one before.
fn expectNexts(s: Schedule, from: Instant, expected: []const []const u8) !void {
    var after = from;
    var buffer: [64]u8 = undefined;
    for (expected) |text| {
        const moment = s.next(after) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(text, try std.fmt.bufPrint(&buffer, "{f}", .{moment}));
        after = moment;
    }
}

fn expectText(expected: []const u8, s: Schedule) !void {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{s}));
}

/// `s` was built from values that make no schedule: `check` says why, and
/// it has no moments.
fn expectProblem(expected: []const u8, s: Schedule) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, s.check(&d));
    try testing.expectEqualStrings(expected, d.message());
    try testing.expectError(error.InvalidArgument, s.check(null));
    try testing.expectEqual(@as(?Instant, null), s.next(t0));
    try expectText("invalid", s);
}

test "a schedule whose arguments the compiler knows is built at compile time" {
    // Each `comptime` block below builds only when its schedule is a
    // constant: the inline functions took their compile-time path.
    const step: Schedule = .everyMinutes(7);
    const daily: Schedule = .dailyAt(3, 30, 0, .pm);
    const weekly: Schedule = .weeklyOn(.monday, 9, 0, 0, .am);
    const monthly: Schedule = .monthlyOn(15, 0, 0, 0, .h24);
    const hour: u8 = 3;
    const typed: Schedule = .dailyAt(hour, 0, 0, .pm);
    comptime {
        std.debug.assert(step.internal.every == 420);
        std.debug.assert(daily.internal.daily == 15 * 3600 + 30 * 60);
        std.debug.assert(weekly.internal.weekly.second_of_day == 9 * 3600);
        std.debug.assert(monthly.internal.monthly.day == 15);
        std.debug.assert(typed.internal.daily == 15 * 3600);
    }
    const moment: Instant = .fromUtc(2026, 10, 24, 3, 30, 0, .pm);
    comptime std.debug.assert(moment.unix_ms == 1_792_855_800_000);
}

test "everyMinutes(7) counts 420 s from the epoch" {
    const s: Schedule = .everyMinutes(7);
    try s.check(null);
    try expectText("every 420s", s);
    try expectNexts(s, t0, &.{
        "2026-10-24T00:04:00.000Z", "2026-10-24T00:11:00.000Z", "2026-10-24T00:18:00.000Z", "2026-10-24T00:25:00.000Z",
        "2026-10-24T00:32:00.000Z", "2026-10-24T00:39:00.000Z", "2026-10-24T00:46:00.000Z", "2026-10-24T00:53:00.000Z",
        "2026-10-24T01:00:00.000Z", "2026-10-24T01:07:00.000Z",
    });
    // The same step in seconds is the same schedule.
    try testing.expectEqual(s, Schedule.everySeconds(420));
}

test "everyHours(5) does not restart at midnight" {
    const s: Schedule = .everyHours(5);
    try expectText("every 18000s", s);
    try expectNexts(s, t0, &.{
        "2026-10-24T05:00:00.000Z", "2026-10-24T10:00:00.000Z", "2026-10-24T15:00:00.000Z",
        "2026-10-24T20:00:00.000Z", "2026-10-25T01:00:00.000Z",
    });
}

test "a step that divides the hour or the day matches the clock" {
    try expectNexts(.everyMinutes(15), t0, &.{
        "2026-10-24T00:15:00.000Z", "2026-10-24T00:30:00.000Z", "2026-10-24T00:45:00.000Z", "2026-10-24T01:00:00.000Z",
    });
    try expectNexts(.everyHours(6), t0, &.{
        "2026-10-24T06:00:00.000Z", "2026-10-24T12:00:00.000Z", "2026-10-24T18:00:00.000Z", "2026-10-25T00:00:00.000Z",
    });
    try expectNexts(.everySeconds(1), t0.add(.fromMilliseconds(500)), &.{ "2026-10-24T00:00:01.000Z", "2026-10-24T00:00:02.000Z" });
}

test "every row of the 12- and 24-hour table" {
    try expectText("daily 00:00:00", .dailyAt(12, 0, 0, .am));
    try expectText("daily 00:30:00", .dailyAt(12, 30, 0, .am));
    try expectText("daily 01:00:00", .dailyAt(1, 0, 0, .am));
    try expectText("daily 11:59:59", .dailyAt(11, 59, 59, .am));
    try expectText("daily 12:00:00", .dailyAt(12, 0, 0, .pm));
    try expectText("daily 15:30:00", .dailyAt(3, 30, 0, .pm));
    try expectText("daily 23:00:00", .dailyAt(11, 0, 0, .pm));
    try expectText("daily 00:00:00", .dailyAt(0, 0, 0, .h24));
    try expectText("daily 15:30:00", .dailyAt(15, 30, 0, .h24));
    try expectText("weekly mon 09:00:00", .weeklyOn(.monday, 9, 0, 0, .am));
    try expectText("monthly 1 00:00:00", .monthlyOn(1, 0, 0, 0, .h24));

    try expectNexts(.dailyAt(12, 0, 0, .am), t0, &.{ "2026-10-25T00:00:00.000Z", "2026-10-26T00:00:00.000Z" });
    try expectNexts(.dailyAt(12, 30, 0, .am), t0, &.{ "2026-10-24T00:30:00.000Z", "2026-10-25T00:30:00.000Z" });
    try expectNexts(.weeklyOn(.monday, 9, 0, 0, .am), t0, &.{ "2026-10-26T09:00:00.000Z", "2026-11-02T09:00:00.000Z" });
    try expectNexts(.monthlyOn(1, 0, 0, 0, .h24), t0, &.{ "2026-11-01T00:00:00.000Z", "2026-12-01T00:00:00.000Z", "2027-01-01T00:00:00.000Z" });
    // The day of the week of `t0` itself, and a day of the month still ahead.
    try expectNexts(.weeklyOn(.saturday, 1, 0, 0, .am), t0, &.{ "2026-10-24T01:00:00.000Z", "2026-10-31T01:00:00.000Z" });
    try expectNexts(.monthlyOn(28, 11, 59, 59, .pm), t0, &.{ "2026-10-28T23:59:59.000Z", "2026-11-28T23:59:59.000Z" });
}

test "fixedDelay has no next and writes seconds or milliseconds" {
    const thirty: Schedule = .fixedDelay(.fromSeconds(30));
    try thirty.check(null);
    try expectText("delay 30s", thirty);
    try testing.expectEqual(@as(?Instant, null), thirty.next(t0));
    try expectText("delay 1500ms", .fixedDelay(.fromMilliseconds(1500)));
    try expectText("delay 1ms", .fixedDelay(.fromMilliseconds(1)));
    try expectText("delay 3155760000s", .fixedDelay(.fromSeconds(3_155_760_000)));

    const whole = "a delay is a whole number of milliseconds, 1 or more";
    try expectProblem("fixedDelay(0ns): " ++ whole, .fixedDelay(.zero));
    try expectProblem("fixedDelay(-1s): " ++ whole, .fixedDelay(.fromSeconds(-1)));
    try expectProblem("fixedDelay(1.5ms): " ++ whole, .fixedDelay(.fromMicroseconds(1500)));
    try expectProblem("fixedDelay(100y3w4d1s): a delay is at most 100 years", .fixedDelay(.fromSeconds(3_155_760_001)));
}

test "values known at run time are checked by check" {
    var hour: u8 = 13;
    var minute: u8 = 60;
    var second: u8 = 60;
    var day: u8 = 29;
    var n: u32 = 0;
    var clock: scheduler.HourFormat = .pm;
    _ = .{ &hour, &minute, &second, &day, &n, &clock };

    try expectProblem("dailyAt(13, 0, 0, .pm): an hour of the 12-hour clock is 1–12; 1 PM is .dailyAt(1, 0, 0, .pm), or .dailyAt(13, 0, 0, .h24)", .dailyAt(hour, 0, 0, .pm));
    try expectProblem("dailyAt(13, 30, 0, .am): an hour of the 12-hour clock is 1–12; 1:30 PM is .dailyAt(1, 30, 0, .pm), or .dailyAt(13, 30, 0, .h24)", .dailyAt(hour, 30, 0, .am));
    try expectProblem("dailyAt(13, 0, 0, .pm): an hour of the 12-hour clock is 1–12; 1 PM is .dailyAt(1, 0, 0, .pm), or .dailyAt(13, 0, 0, .h24)", .dailyAt(13, 0, 0, clock));
    try expectProblem("weeklyOn(.monday, 9, 60, 0, .am): a minute is 0–59", .weeklyOn(.monday, 9, minute, 0, .am));
    try expectProblem("dailyAt(9, 0, 60, .am): a second is 0–59", .dailyAt(9, 0, second, .am));
    try expectProblem("monthlyOn(29, 0, 0, 0, .h24): a day of monthlyOn is 1–28, which every month has; " ++
        "the 29th of the months that have one is .cron(\"0 0 0 29 * *\"); the last day of a month is not in v1", .monthlyOn(day, 0, 0, 0, .h24));
    try expectProblem("everyMinutes(0): n is 1 or more", .everyMinutes(n));

    hour = 0;
    try expectProblem("dailyAt(0, 0, 0, .am): an hour of the 12-hour clock is 1–12; midnight is .dailyAt(12, 0, 0, .am), or .dailyAt(0, 0, 0, .h24)", .dailyAt(hour, 0, 0, .am));
    try expectProblem("weeklyOn(.friday, 0, 30, 15, .am): an hour of the 12-hour clock is 1–12; " ++
        "12:30:15 AM is .weeklyOn(.friday, 12, 30, 15, .am), or .weeklyOn(.friday, 0, 30, 15, .h24)", .weeklyOn(.friday, hour, 30, 15, .am));
    hour = 24;
    try expectProblem("dailyAt(24, 0, 0, .h24): an hour of the 24-hour clock is 0–23", .dailyAt(hour, 0, 0, .h24));
    // An hour that no clock has gets no hint, nor does a time with a
    // wrong minute.
    try expectProblem("dailyAt(24, 0, 0, .pm): an hour of the 12-hour clock is 1–12", .dailyAt(hour, 0, 0, .pm));
    hour = 13;
    try expectProblem("dailyAt(13, 60, 0, .pm): an hour of the 12-hour clock is 1–12", .dailyAt(hour, minute, 0, .pm));

    // monthlyOn checks the time first: the hint of a day carries it.
    day = 31;
    try expectProblem("monthlyOn(31, 3, 30, 0, .pm): a day of monthlyOn is 1–28, which every month has; " ++
        "the 31st of the months that have one is .cron(\"0 30 15 31 * *\"); the last day of a month is not in v1", .monthlyOn(day, 3, 30, 0, .pm));
    day = 30;
    try expectProblem("monthlyOn(30, 0, 0, 0, .h24): a day of monthlyOn is 1–28, which every month has; " ++
        "the 30th of the months that have one is .cron(\"0 0 0 30 * *\"); the last day of a month is not in v1", .monthlyOn(day, 0, 0, 0, .h24));
    try expectProblem("monthlyOn(30, 13, 0, 0, .am): an hour of the 12-hour clock is 1–12; " ++
        "1 PM is .monthlyOn(30, 1, 0, 0, .pm), or .monthlyOn(30, 13, 0, 0, .h24)", .monthlyOn(day, 13, 0, 0, .am));
    day = 0;
    try expectProblem("monthlyOn(0, 0, 0, 0, .h24): a day of monthlyOn is 1–28, which every month has", .monthlyOn(day, 0, 0, 0, .h24));

    // A step of n units is 1 s to 100 years.
    var big: u64 = 876_601;
    var negative: i32 = -1;
    _ = .{ &big, &negative };
    try expectProblem("everyHours(876601): n is at most 876600, which is 100 years", .everyHours(big));
    try expectProblem("everySeconds(-1): n is 1 or more", .everySeconds(negative));
    big = 3_155_760_001;
    try expectProblem("everySeconds(3155760001): n is at most 3155760000, which is 100 years", .everySeconds(big));
    big = std.math.maxInt(u64);
    try expectProblem("everyMinutes(9223372036854775807): n is at most 52596000, which is 100 years", .everyMinutes(big));
    big = 876_600;
    try expectText("every 3155760000s", .everyHours(big));
}

test "next stays within the years 1970-9999" {
    // Moments before the epoch count from it.
    try expectNexts(.everySeconds(1), .fromUnixMs(-5000), &.{"1970-01-01T00:00:00.000Z"});
    try expectNexts(.dailyAt(3, 30, 0, .am), .fromUnixMs(std.math.minInt(i64) + 1), &.{"1970-01-01T03:30:00.000Z"});
    // No moment, which a refused fromUtc gives, has no next one.
    for ([_]Schedule{ .everySeconds(1), .dailyAt(3, 30, 0, .am), .weeklyOn(.monday, 9, 0, 0, .am), .monthlyOn(1, 0, 0, 0, .h24), .cron("0 30 2 * * *") }) |s|
        try testing.expectEqual(@as(?Instant, null), s.next(.invalid));
    // The last moment of 9999 ends every schedule.
    const late: Instant = .fromUtc(9999, 12, 31, 23, 0, 0, .h24);
    try expectNexts(.dailyAt(11, 30, 0, .pm), late, &.{"9999-12-31T23:30:00.000Z"});
    try testing.expectEqual(@as(?Instant, null), Schedule.dailyAt(11, 0, 0, .pm).next(late));
    try testing.expectEqual(@as(?Instant, null), Schedule.weeklyOn(.monday, 9, 0, 0, .am).next(late));
    try testing.expectEqual(@as(?Instant, null), Schedule.monthlyOn(1, 0, 0, 0, .h24).next(late));
    try testing.expectEqual(@as(?Instant, null), Schedule.everyHours(876_600).next(late));
    try testing.expectEqual(@as(?Instant, null), Schedule.everySeconds(1).next(.fromUnixMs(std.math.maxInt(i64))));
}

fn expectReadBack(s: Schedule) !void {
    var text: [128]u8 = undefined;
    const written = try std.fmt.bufPrint(&text, "{f}", .{s});
    const back = try Schedule.parse(written, null);
    try expectText(written, back);
    try testing.expectEqual(s.next(t0), back.next(t0));
    try testing.expectEqual(s, back);
}

fn expectRefused(expected: []const u8, text: []const u8) !void {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, Schedule.parse(text, &d));
    try testing.expectEqualStrings(expected, d.message());
}

test "the canonical text reads back" {
    try expectReadBack(.everyMinutes(7));
    try expectReadBack(.everySeconds(1));
    try expectReadBack(.fixedDelay(.fromSeconds(30)));
    try expectReadBack(.fixedDelay(.fromMilliseconds(1500)));
    try expectReadBack(.dailyAt(3, 30, 0, .pm));
    try expectReadBack(.weeklyOn(.sunday, 11, 59, 59, .pm));
    try expectReadBack(.monthlyOn(28, 12, 0, 0, .am));
    try expectReadBack(.monthlyOn(1, 9, 5, 7, .h24));
    try testing.expectError(error.InvalidArgument, Schedule.parse("daily 24:00:00", null));

    const starts = "; a plan is every <n>s, delay <n>s, delay <n>ms, daily HH:MM:SS, weekly <day> HH:MM:SS, monthly <day> HH:MM:SS or cron <fields>";
    try expectRefused("plan \"daily 24:00:00\": an hour is 00–23", "daily 24:00:00");
    try expectRefused("plan \"daily 23:60:00\": a minute is 00–59", "daily 23:60:00");
    try expectRefused("plan \"daily 23:00:60\": a second is 00–59", "daily 23:00:60");
    try expectRefused("plan \"daily 9:00:00\": a time is HH:MM:SS", "daily 9:00:00");
    try expectRefused("plan \"weekly xyz 09:00:00\": xyz is no day; the days are mon, tue, wed, thu, fri, sat and sun", "weekly xyz 09:00:00");
    try expectRefused("plan \"monthly 29 00:00:00\": a day of monthly is 1–28", "monthly 29 00:00:00");
    try expectRefused("plan \"every 0s\": a step is 1 s to 100 years", "every 0s");
    try expectRefused("plan \"every 3155760001s\": a step is 1 s to 100 years", "every 3155760001s");
    try expectRefused("plan \"delay 0ms\": a delay is 1 ms to 100 years", "delay 0ms");
    try expectRefused("plan \"delay 30m\": not a schedule" ++ starts, "delay 30m");
    try expectRefused("plan \"hourly 5\": not a schedule" ++ starts, "hourly 5");
    try expectRefused("plan \"daily 15:30:00 extra\": not a schedule" ++ starts, "daily 15:30:00 extra");
    try expectRefused("plan \"\": not a schedule" ++ starts, "");
    try expectRefused("plan \"invalid\": not a schedule" ++ starts, "invalid");
    // A byte that is not text shows as an escape.
    try expectRefused("plan \"daily \\xff\": a time is HH:MM:SS", "daily \xff");
}

fn repeatOf(w: scheduler.When) !Schedule {
    return switch (w) {
        .repeat => |s| s,
        else => error.TestUnexpectedResult,
    };
}

test "When takes moments and schedules by their decl literals" {
    const Declared = struct { repeat: ?Schedule = null };
    const declared: Declared = .{ .repeat = .dailyAt(3, 30, 0, .am) };
    try expectText("daily 03:30:00", declared.repeat orelse return error.TestUnexpectedResult);

    var hour: u8 = 9;
    _ = &hour;
    const whens = [_]scheduler.When{
        .{ .at = .fromUtc(2026, 10, 24, 15, 30, 0, .h24) },
        .{ .after = .fromSeconds(60) },
        .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) },
        .{ .repeat = .weeklyOn(.monday, hour, 0, 0, .am) },
        .{ .repeat = .weeklyOn(.monday, hour, 0, 0, .pm) },
    };
    switch (whens[0]) {
        .at => |at| try testing.expectEqual(1_792_855_800_000, at.unix_ms),
        else => return error.TestUnexpectedResult,
    }
    switch (whens[1]) {
        .after => |after| try testing.expectEqual(60 * std.time.ns_per_s, after.nanoseconds),
        else => return error.TestUnexpectedResult,
    }
    try expectText("weekly mon 09:00:00", try repeatOf(whens[2]));
    try expectText("weekly mon 09:00:00", try repeatOf(whens[3]));
    try expectText("weekly mon 21:00:00", try repeatOf(whens[4]));
}
