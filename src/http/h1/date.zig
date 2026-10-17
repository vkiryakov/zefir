//! The `Date` of a response (RFC 9110 §5.6.7): the IMF-fixdate of a time
//! on the real-time clock, such as `Sun, 06 Nov 1994 08:49:37 GMT`, and
//! the dates of requests (`If-Modified-Since`, `If-Range`) in each of the
//! three forms a recipient takes. Pure.
//!
//! The backend reads `std.Io.Clock.real` for it, never the awake clock of
//! `ctx.now()` and `core.Deadline`, whose times are not dates.

const std = @import("std");
const epoch = std.time.epoch;

/// The length of an IMF-fixdate.
pub const len = 29;

const day_names = [7][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The last second an IMF-fixdate can show: 9999-12-31 23:59:59.
const max_seconds: u64 = 253_402_300_799;

/// Writes the IMF-fixdate of `ts`, a time of `std.Io.Clock.real` (seconds
/// since 1970-01-01 UTC), into `out` and returns it. A time before 1970
/// shows as 1970-01-01 00:00:00, one after 9999 as its last second.
pub fn formatImfFixdate(ts: std.Io.Timestamp, out: *[len]u8) []const u8 {
    const seconds: u64 = @min(@as(u64, @intCast(@max(ts.toSeconds(), 0))), max_seconds);
    const at: epoch.EpochSeconds = .{ .secs = seconds };
    const day = at.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = at.getDaySeconds();
    // 1970-01-01 was a Thursday.
    const written = std.fmt.bufPrint(out, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[@intCast(day.day % 7)],
        @as(u8, month_day.day_index) + 1,
        month_names[@as(usize, month_day.month.numeric()) - 1],
        year_day.year,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable; // always 29 bytes: four digits of year at most
    return written;
}

const long_day_names = [7][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };

/// The seconds since 1970-01-01 UTC of an HTTP-date (RFC 9110 §5.6.7), in
/// any of its three forms: the IMF-fixdate `Sun, 06 Nov 1994 08:49:37 GMT`,
/// and the obsolete `Sunday, 06-Nov-94 08:49:37 GMT` (RFC 850) and
/// `Sun Nov  6 08:49:37 1994` (asctime). Null for anything else: another
/// form, a name in another case, a date that does not exist. The two digits
/// of an RFC 850 year are 1970 to 2069; the name of the day is not checked
/// against the date.
pub fn parseHttpDate(text: []const u8) ?i64 {
    if (text.len == len and text[3] == ',') return imfFixdate(text);
    if (text.len == 24 and text[3] == ' ') return asctime(text);
    return rfc850(text);
}

/// `Sun, 06 Nov 1994 08:49:37 GMT`.
fn imfFixdate(t: []const u8) ?i64 {
    if (dayIndex(&day_names, t[0..3]) == null) return null;
    if (!std.mem.eql(u8, t[3..5], ", ") or t[7] != ' ' or t[11] != ' ' or t[16] != ' ') return null;
    if (!std.mem.eql(u8, t[25..], " GMT")) return null;
    return secondsOf(
        number(t[12..16]) orelse return null,
        monthOf(t[8..11]) orelse return null,
        number(t[5..7]) orelse return null,
        t[17..25],
    );
}

/// `Sunday, 06-Nov-94 08:49:37 GMT`.
fn rfc850(t: []const u8) ?i64 {
    const comma = std.mem.findScalar(u8, t, ',') orelse return null;
    if (dayIndex(&long_day_names, t[0..comma]) == null) return null;
    const rest = t[comma..];
    if (rest.len != 24 or !std.mem.eql(u8, rest[0..2], ", ")) return null;
    if (rest[4] != '-' or rest[8] != '-' or rest[11] != ' ' or !std.mem.eql(u8, rest[20..], " GMT")) return null;
    const two_digits = number(rest[9..11]) orelse return null;
    return secondsOf(
        if (two_digits < 70) 2000 + two_digits else 1900 + two_digits,
        monthOf(rest[5..8]) orelse return null,
        number(rest[2..4]) orelse return null,
        rest[12..20],
    );
}

/// `Sun Nov  6 08:49:37 1994`: the day is two digits or a space and one.
fn asctime(t: []const u8) ?i64 {
    if (dayIndex(&day_names, t[0..3]) == null) return null;
    if (t[7] != ' ' or t[10] != ' ' or t[19] != ' ') return null;
    const day = if (t[8] == ' ') number(t[9..10]) else number(t[8..10]);
    return secondsOf(
        number(t[20..24]) orelse return null,
        monthOf(t[4..7]) orelse return null,
        day orelse return null,
        t[11..19],
    );
}

fn dayIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// 1 to 12.
fn monthOf(name: []const u8) ?u32 {
    for (month_names, 1..) |n, m| {
        if (std.mem.eql(u8, n, name)) return @intCast(m);
    }
    return null;
}

/// Digits only.
fn number(digits: []const u8) ?u32 {
    var n: u32 = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// The seconds of a date and an `HH:MM:SS` time, if the date exists. A
/// second of 60, a leap second, counts as the first of the next minute.
fn secondsOf(year: u32, month: u32, day: u32, time: []const u8) ?i64 {
    if (time[2] != ':' or time[5] != ':') return null;
    const hour = number(time[0..2]) orelse return null;
    const minute = number(time[3..5]) orelse return null;
    const second = number(time[6..8]) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    if (year > 9999 or day == 0 or day > daysInMonth(year, month)) return null;
    const days = daysFromCivil(year, month, day);
    return days * epoch.secs_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn daysInMonth(year: u32, month: u32) u32 {
    const days = [12]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and epoch.isLeapYear(@intCast(year))) return 29;
    return days[month - 1];
}

/// The days from 1970-01-01 to a date of the proleptic Gregorian calendar
/// (the algorithm of Howard Hinnant's `days_from_civil`).
fn daysFromCivil(year: u32, month: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const m: i64 = month;
    const day_of_year = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

const testing = std.testing;

fn expectDate(expected: []const u8, seconds: i64) !void {
    var out: [len]u8 = undefined;
    try testing.expectEqualStrings(expected, formatImfFixdate(.fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s), &out));
}

test "formatImfFixdate: the example of RFC 9110, the epoch, leap days and the bounds" {
    try expectDate("Sun, 06 Nov 1994 08:49:37 GMT", 784_111_777);
    try expectDate("Thu, 01 Jan 1970 00:00:00 GMT", 0);
    try expectDate("Tue, 29 Feb 2000 00:00:00 GMT", 951_782_400);
    try expectDate("Thu, 29 Feb 2024 23:59:59 GMT", 1_709_251_199);
    try expectDate("Fri, 01 Mar 2024 00:00:00 GMT", 1_709_251_200);
    try expectDate("Sat, 17 Oct 2026 13:20:26 GMT", 1_792_243_226);
    try expectDate("Thu, 01 Jan 1970 00:00:00 GMT", -5);
    try expectDate("Fri, 31 Dec 9999 23:59:59 GMT", std.math.maxInt(i64));
    // Nanoseconds of a second do not round it up.
    var out: [len]u8 = undefined;
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:01 GMT", formatImfFixdate(.fromNanoseconds(1_999_999_999), &out));
}

test "parseHttpDate: the three forms of RFC 9110 give one time" {
    // The example of RFC 9110 §5.6.7 in each form.
    for ([_][]const u8{
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
        "Sun Nov 06 08:49:37 1994",
    }) |text| {
        testing.expectEqual(@as(?i64, 784_111_777), parseHttpDate(text)) catch |err| {
            std.debug.print("date {s}\n", .{text});
            return err;
        };
    }
    try testing.expectEqual(@as(?i64, 0), parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 951_782_400), parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 1_709_251_199), parseHttpDate("Thu, 29 Feb 2024 23:59:59 GMT"));
    // Two digits of a year: 1970 to 2069.
    try testing.expectEqual(@as(?i64, 1_792_243_226), parseHttpDate("Saturday, 17-Oct-26 13:20:26 GMT"));
    try testing.expectEqual(@as(?i64, 0), parseHttpDate("Thursday, 01-Jan-70 00:00:00 GMT"));
    // Before 1970: negative.
    try testing.expectEqual(@as(?i64, -86_400), parseHttpDate("Wed, 31 Dec 1969 00:00:00 GMT"));
    // A leap second is the first second of the next minute.
    try testing.expectEqual(@as(?i64, 60), parseHttpDate("Thu, 01 Jan 1970 00:00:60 GMT"));
}

test "parseHttpDate: what it formats it reads back" {
    var out: [len]u8 = undefined;
    for ([_]i64{ 0, 1, 784_111_777, 951_782_400, 1_709_251_200, 1_792_243_226, 253_402_300_799 }) |seconds| {
        const text = formatImfFixdate(.fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s), &out);
        try testing.expectEqual(@as(?i64, seconds), parseHttpDate(text));
    }
}

test "parseHttpDate: other forms, other cases and dates that do not exist are null" {
    for ([_][]const u8{
        "",
        "Sun, 06 Nov 1994 08:49:37",
        "Sun, 06 Nov 1994 08:49:37 UTC",
        "sun, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:37 gmt",
        "Sun,  6 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 94 08:49:37 GMT",
        "Sun, 06 Nov 1994 8:49:37 GMT ",
        "Sun, 06 Nov 1994 24:00:00 GMT",
        "Sun, 06 Nov 1994 08:60:00 GMT",
        "Sun, 06 Nov 1994 08:49:61 GMT",
        "Sun, 06 Nov 1994 08-49-37 GMT",
        "Sun, 31 Nov 1994 08:49:37 GMT",
        "Sun, 29 Feb 1900 08:49:37 GMT",
        "Sun, 00 Nov 1994 08:49:37 GMT",
        "Xyz, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:37 GMT\r\n",
        "Sun, 06 Nov 1994 08:49:3x GMT",
        "Sunday, 06-Nov-1994 08:49:37 GMT",
        "Sunday, 06 Nov 94 08:49:37 GMT",
        "Sun, 06-Nov-94 08:49:37 GMT",
        "Funday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov 6 08:49:37 1994",
        "Sun Nov  6 08:49:37 94",
        "Sun Nov 31 08:49:37 1994",
        "Sun Nov  6 08:49:37 1994 GMT",
        "Sun Nov _6 08:49:37 1994",
        "1994-11-06T08:49:37Z",
        "784111777",
    }) |text| {
        testing.expectEqual(@as(?i64, null), parseHttpDate(text)) catch |err| {
            std.debug.print("date {s}\n", .{text});
            return err;
        };
    }
}
