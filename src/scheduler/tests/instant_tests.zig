//! Tests of scheduler.Instant and of the UTC calendar of the schedules.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");
const calendar = @import("../schedule/calendar.zig");
const args = @import("../schedule/args.zig");
const Instant = scheduler.Instant;

const ms_per_hour = 60 * 60 * 1000;

fn expectFormat(expected: []const u8, i: Instant) !void {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{i}));
}

test "the calendar of the epoch and of 2026-10-24" {
    try testing.expectEqual(0, calendar.daysFromCivil(1970, 1, 1));
    try testing.expectEqual(20750, calendar.daysFromCivil(2026, 10, 24));
    try testing.expectEqual(calendar.Civil{ .year = 2026, .month = 10, .day = 24 }, calendar.civilFromDays(20750));
    try testing.expectEqual(calendar.Civil{ .year = 1969, .month = 12, .day = 31 }, calendar.civilFromDays(-1));
    try testing.expectEqual(scheduler.Weekday.thursday, calendar.weekdayOf(0));
    try testing.expectEqual(scheduler.Weekday.saturday, calendar.weekdayOf(20750));
    try testing.expectEqual(scheduler.Weekday.wednesday, calendar.weekdayOf(-1));
    try testing.expect(calendar.isLeap(2000));
    try testing.expect(calendar.isLeap(2096));
    try testing.expect(!calendar.isLeap(2100));
    try testing.expect(!calendar.isLeap(2026));
    try testing.expectEqual(28, calendar.daysIn(2026, 2));
    try testing.expectEqual(29, calendar.daysIn(2096, 2));
    try testing.expectEqual(30, calendar.daysIn(2026, 11));
    try testing.expectEqual(31, calendar.daysIn(2026, 12));
}

test "civilFromDays undoes daysFromCivil from 1970 to 9999" {
    const last = calendar.daysFromCivil(9999, 12, 31);
    try testing.expectEqual(calendar.Civil{ .year = 9999, .month = 12, .day = 31 }, calendar.civilFromDays(last));
    var days: i64 = 0;
    while (days <= last) : (days += 97) {
        const date = calendar.civilFromDays(days);
        try testing.expect(date.month >= 1 and date.month <= 12);
        try testing.expect(date.day >= 1 and date.day <= calendar.daysIn(date.year, date.month));
        try testing.expectEqual(days, calendar.daysFromCivil(date.year, date.month, date.day));
    }
}

test "hour24 reads an hour by its clock: 12 AM is midnight, 12 PM is noon" {
    try testing.expectEqual(@as(?u5, 0), calendar.hour24(12, .am));
    try testing.expectEqual(@as(?u5, 1), calendar.hour24(1, .am));
    try testing.expectEqual(@as(?u5, 11), calendar.hour24(11, .am));
    try testing.expectEqual(@as(?u5, 12), calendar.hour24(12, .pm));
    try testing.expectEqual(@as(?u5, 13), calendar.hour24(1, .pm));
    try testing.expectEqual(@as(?u5, 23), calendar.hour24(11, .pm));
    try testing.expectEqual(@as(?u5, 0), calendar.hour24(0, .h24));
    try testing.expectEqual(@as(?u5, 23), calendar.hour24(23, .h24));
    for ([_]i64{ 0, 13, 24, -1 }) |hour| {
        try testing.expectEqual(@as(?u5, null), calendar.hour24(hour, .am));
        try testing.expectEqual(@as(?u5, null), calendar.hour24(hour, .pm));
    }
    try testing.expectEqual(@as(?u5, null), calendar.hour24(24, .h24));
    try testing.expectEqual(@as(?u5, null), calendar.hour24(-1, .h24));
}

test "fromUtc reads the hour by its clock" {
    try testing.expectEqual(1_792_855_800_000, Instant.fromUtc(2026, 10, 24, 15, 30, 0, .h24).unix_ms);
    try testing.expectEqual(1_792_855_800_000, Instant.fromUtc(2026, 10, 24, 3, 30, 0, .pm).unix_ms);
    try testing.expectEqual(1_792_800_000_000, Instant.fromUtc(2026, 10, 24, 12, 0, 0, .am).unix_ms);
    try testing.expectEqual(1_792_800_000_000 + 12 * ms_per_hour, Instant.fromUtc(2026, 10, 24, 12, 0, 0, .pm).unix_ms);
    try testing.expectEqual(0, Instant.fromUtc(1970, 1, 1, 0, 0, 0, .h24).unix_ms);

    // The same values known only at run time give the same moments.
    var year: u16 = 2026;
    var hour: u8 = 3;
    var clock: scheduler.HourFormat = .pm;
    _ = .{ &year, &hour, &clock };
    try testing.expectEqual(1_792_855_800_000, Instant.fromUtc(year, 10, 24, hour, 30, 0, clock).unix_ms);
    hour = 12;
    clock = .am;
    try testing.expectEqual(1_792_800_000_000, Instant.fromUtc(year, 10, 24, hour, 0, 0, clock).unix_ms);
    year = 9999;
    hour = 11;
    clock = .pm;
    try expectFormat("9999-12-31T23:59:59.000Z", Instant.fromUtc(year, 12, 31, hour, 59, 59, clock));
}

test "format writes RFC 3339 in UTC with milliseconds" {
    try expectFormat("2026-10-24T15:30:00.000Z", Instant.fromUtc(2026, 10, 24, 15, 30, 0, .h24));
    try expectFormat("2026-10-24T15:30:00.123Z", Instant.fromUnixMs(1_792_855_800_123));
    try expectFormat("1970-01-01T00:00:00.000Z", Instant.fromUnixMs(0));
    try expectFormat("1969-12-31T23:59:59.999Z", Instant.fromUnixMs(-1));
    try expectFormat("9999-12-31T23:59:59.999Z", Instant.fromUnixMs(253_402_300_799_999));
    try expectFormat("invalid", Instant.invalid);
    // Moments beyond the four digits of RFC 3339 keep their sign and year.
    try expectFormat("+292278994-08-17T07:12:55.807Z", Instant.fromUnixMs(std.math.maxInt(i64)));
    try expectFormat("-292275055-05-16T16:47:04.193Z", Instant.fromUnixMs(std.math.minInt(i64) + 1));
}

test "add saturates" {
    try testing.expectEqual(std.math.maxInt(i64), Instant.fromUnixMs(std.math.maxInt(i64)).add(.fromSeconds(1)).unix_ms);
    try testing.expectEqual(std.math.maxInt(i64), Instant.fromUnixMs(0).add(.max).unix_ms);
    // The low end stops short of `invalid`, which only a refused fromUtc gives.
    try testing.expectEqual(std.math.minInt(i64) + 1, Instant.fromUnixMs(std.math.minInt(i64) + 1).add(.fromSeconds(-1)).unix_ms);
    try testing.expectEqual(Instant.invalid, Instant.invalid.add(.fromSeconds(1)));
    try testing.expectEqual(1_500, Instant.fromUnixMs(1_000).add(.fromMilliseconds(500)).unix_ms);
    try testing.expectEqual(500, Instant.fromUnixMs(1_000).add(.fromMilliseconds(-500)).unix_ms);
    // A part of a millisecond counts down, as fromTimestamp counts it.
    try testing.expectEqual(1_001, Instant.fromUnixMs(1_000).add(.fromMicroseconds(1_500)).unix_ms);
    try testing.expectEqual(998, Instant.fromUnixMs(1_000).add(.fromMicroseconds(-1_500)).unix_ms);
}

test "fromTimestamp keeps the milliseconds of Clock.real" {
    try testing.expectEqual(1_792_855_800_123, Instant.fromTimestamp(.{ .nanoseconds = 1_792_855_800_123_999_999 }).unix_ms);
    try testing.expectEqual(-1, Instant.fromTimestamp(.{ .nanoseconds = -1 }).unix_ms);
    try testing.expectEqual(std.math.maxInt(i64), Instant.fromTimestamp(.{ .nanoseconds = std.math.maxInt(i96) }).unix_ms);
    try testing.expectEqual(std.math.minInt(i64) + 1, Instant.fromTimestamp(.{ .nanoseconds = std.math.minInt(i96) }).unix_ms);
    // The clock of the test runs after the day this module was written.
    const now = Instant.fromTimestamp(std.Io.Clock.real.now(testing.io));
    try testing.expect(now.unix_ms > Instant.fromUtc(2026, 1, 1, 0, 0, 0, .h24).unix_ms);
}

test "fromUtc of run-time values that are no moment is invalid" {
    const Case = struct { year: i32, month: u8, day: u8, hour: i64, minute: u8, second: u8, clock: scheduler.HourFormat };
    const cases = [_]Case{
        .{ .year = 2026, .month = 2, .day = 29, .hour = 0, .minute = 0, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 13, .day = 1, .hour = 0, .minute = 0, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 10, .day = 0, .hour = 0, .minute = 0, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 10, .day = 24, .hour = 0, .minute = 0, .second = 0, .clock = .am },
        .{ .year = 2026, .month = 10, .day = 24, .hour = 13, .minute = 0, .second = 0, .clock = .pm },
        .{ .year = 2026, .month = 10, .day = 24, .hour = 24, .minute = 0, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 10, .day = 24, .hour = 12, .minute = 60, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 10, .day = 24, .hour = 12, .minute = 0, .second = 60, .clock = .h24 },
        .{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .clock = .h24 },
        .{ .year = 10000, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .clock = .h24 },
        .{ .year = 2026, .month = 10, .day = 24, .hour = std.math.minInt(i64), .minute = 0, .second = 0, .clock = .h24 },
    };
    for (cases) |case| {
        var c = case;
        _ = &c;
        try testing.expectEqual(Instant.invalid, Instant.fromUtc(c.year, c.month, c.day, c.hour, c.minute, c.second, c.clock));
    }
    // An hour beyond i64 is no hour either.
    var huge: u64 = std.math.maxInt(u64);
    _ = &huge;
    try testing.expectEqual(Instant.invalid, Instant.fromUtc(2026, 10, 24, huge, 0, 0, .h24));
}

fn expectUtcProblem(expected: []const u8, u: args.Utc) !void {
    try testing.expectEqual(@as(?i64, null), u.unixMs());
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{std.fmt.alt(u, .writeProblem)}));
}

fn utc(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, clock: scheduler.HourFormat) args.Utc {
    return .{ .year = year, .month = month, .day = day, .time = .{ .hour = hour, .minute = minute, .second = second, .clock = clock } };
}

test "the texts of fromUtc name the call and the rule" {
    try expectUtcProblem("fromUtc(2026, 2, 29, 0, 0, 0, .h24): 2026-02-29 is not a date", utc(2026, 2, 29, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(2026, 4, 31, 0, 0, 0, .h24): 2026-04-31 is not a date", utc(2026, 4, 31, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(2026, 10, 0, 0, 0, 0, .h24): a day is 1–31", utc(2026, 10, 0, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(2026, 13, 1, 0, 0, 0, .h24): a month is 1–12", utc(2026, 13, 1, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(1969, 12, 31, 0, 0, 0, .h24): a year is 1970–9999", utc(1969, 12, 31, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(10000, 1, 1, 0, 0, 0, .h24): a year is 1970–9999", utc(10000, 1, 1, 0, 0, 0, .h24));
    try expectUtcProblem("fromUtc(2026, 10, 24, 13, 0, 0, .pm): an hour of the 12-hour clock is 1–12; " ++
        "1 PM is .fromUtc(2026, 10, 24, 1, 0, 0, .pm), or .fromUtc(2026, 10, 24, 13, 0, 0, .h24)", utc(2026, 10, 24, 13, 0, 0, .pm));
    try expectUtcProblem("fromUtc(2026, 10, 24, 0, 30, 0, .am): an hour of the 12-hour clock is 1–12; " ++
        "12:30 AM is .fromUtc(2026, 10, 24, 12, 30, 0, .am), or .fromUtc(2026, 10, 24, 0, 30, 0, .h24)", utc(2026, 10, 24, 0, 30, 0, .am));
    try expectUtcProblem("fromUtc(2026, 10, 24, 24, 0, 0, .h24): an hour of the 24-hour clock is 0–23", utc(2026, 10, 24, 24, 0, 0, .h24));
    try expectUtcProblem("fromUtc(2026, 10, 24, 9, 60, 0, .am): a minute is 0–59", utc(2026, 10, 24, 9, 60, 0, .am));
    try expectUtcProblem("fromUtc(2026, 10, 24, 9, 0, -1, .am): a second is 0–59", utc(2026, 10, 24, 9, 0, -1, .am));
}
