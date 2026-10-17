//! The `Date` of a response (RFC 9110 §5.6.7): the IMF-fixdate of a time
//! on the real-time clock, such as `Sun, 06 Nov 1994 08:49:37 GMT`. Pure.
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
