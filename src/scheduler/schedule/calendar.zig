//! The proleptic Gregorian calendar in UTC, without allocation, and how a
//! schedule reads an hour. Days are numbered from 1970-01-01 (day 0), as
//! H. Hinnant's `days_from_civil` and `civil_from_days` number them; a day
//! number comes from a moment of `i64` milliseconds, so its year fits an
//! `i32`.

/// How to read an hour.
pub const HourFormat = enum {
    /// The 24-hour clock: 0–23.
    h24,
    /// The 12-hour clock before noon: 1–12; 12 AM is midnight (00:xx).
    am,
    /// The 12-hour clock after noon: 1–12; 12 PM is noon (12:xx).
    pm,
};

pub const Weekday = enum { monday, tuesday, wednesday, thursday, friday, saturday, sunday };

/// A date: its month is 1–12, its day 1–31.
pub const Civil = struct { year: i32, month: u4, day: u5 };

/// The number of the day of a date (H. Hinnant's `days_from_civil`).
pub fn daysFromCivil(year: i32, month: u4, day: u5) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    // March is month 0, so that the leap day ends the year.
    const shifted_month: i64 = @mod(@as(i64, month) + 9, 12);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// The date of a day number (H. Hinnant's `civil_from_days`).
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day: u5 = @intCast(day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1);
    const month: u4 = @intCast(if (shifted_month < 10) shifted_month + 3 else shifted_month - 9);
    const year = year_of_era + era * 400;
    return .{ .year = @intCast(if (month <= 2) year + 1 else year), .month = month, .day = day };
}

/// The weekday of a day number; 1970-01-01 was a Thursday.
pub fn weekdayOf(days: i64) Weekday {
    return @fromBackingInt(@as(u3, @intCast(@mod(days + 3, 7))));
}

pub fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

/// The days of a month 1–12.
pub fn daysIn(year: i32, month: u4) u5 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// The hour of the 24-hour clock that `hour` names on `clock`, or null
/// when it is no hour of that clock: 12 AM is 0, 12 PM is 12.
pub fn hour24(hour: i64, clock: HourFormat) ?u5 {
    return switch (clock) {
        .h24 => if (hour >= 0 and hour <= 23) @intCast(hour) else null,
        .am => if (hour == 12) 0 else if (hour >= 1 and hour <= 11) @intCast(hour) else null,
        .pm => if (hour == 12) 12 else if (hour >= 1 and hour <= 11) @intCast(hour + 12) else null,
    };
}
