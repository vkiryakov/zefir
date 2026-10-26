//! The arguments of the calls that build schedules and moments
//! (`Schedule.dailyAt`, `Instant.fromUtc`, …): whether the compiler knows
//! them, how a number of any integer type is read, and the rules of a time
//! of day with their texts. A compile error and the text of a check come
//! from the same function, so the two never differ.

const std = @import("std");
const Io = std.Io;
const calendar = @import("calendar.zig");
const HourFormat = calendar.HourFormat;
const Weekday = calendar.Weekday;

/// Whether every field of the tuple type `T` is known at compile time.
/// Inside an inline function, `@TypeOf(.{ a, b })` of its parameters says
/// whether the caller knew them all then: literals, constants, the values
/// of a declaration.
pub fn known(comptime T: type) bool {
    for (@typeInfo(T).@"struct".field_attrs) |attrs| {
        if (!attrs.@"comptime") return false;
    }
    return true;
}

/// `x`, an integer of any type, as an `i64`. A value beyond `i64` becomes
/// its nearer end, which no rule of a schedule or a moment takes either.
pub inline fn int(comptime call: []const u8, comptime name: []const u8, x: anytype) i64 {
    const X = @TypeOf(x);
    switch (@typeInfo(X)) {
        .comptime_int, .int => {},
        else => @compileError("scheduler: " ++ call ++ ": " ++ name ++ " is an integer, not " ++ @typeName(X)),
    }
    return std.math.cast(i64, x) orelse if (x < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// A time of day as a call got it, its hour still read by `clock`.
pub const Time = struct {
    hour: i64,
    minute: i64,
    second: i64,
    clock: HourFormat,

    /// Seconds from midnight, or null when the arguments are no time of day.
    pub fn secondOfDay(t: Time) ?u17 {
        const hour = calendar.hour24(t.hour, t.clock) orelse return null;
        if (!isSixty(t.minute) or !isSixty(t.second)) return null;
        return @intCast(@as(i64, hour) * 3600 + t.minute * 60 + t.second);
    }

    /// Writes why `secondOfDay` refused the time. `call` writes the same
    /// call with another hour, for the hint of an hour of the 24-hour clock
    /// given with `.am` or `.pm`.
    pub fn writeProblem(t: Time, call: Call, w: *Io.Writer) Io.Writer.Error!void {
        if (calendar.hour24(t.hour, t.clock) == null) {
            if (t.clock == .h24) return w.writeAll("an hour of the 24-hour clock is 0–23");
            try w.writeAll("an hour of the 12-hour clock is 1–12");
            // The hour is 0 or 13–23 of the 24-hour clock: name the time
            // both ways.
            if (t.hour < 0 or t.hour > 23 or !isSixty(t.minute) or !isSixty(t.second)) return;
            const twelve: Time = .{
                .hour = if (t.hour == 0) 12 else t.hour - 12,
                .minute = t.minute,
                .second = t.second,
                .clock = if (t.hour == 0) .am else .pm,
            };
            try w.writeAll("; ");
            try twelve.writeName(w);
            try w.writeAll(" is .");
            try call.write(w, twelve);
            try w.writeAll(", or .");
            try call.write(w, .{ .hour = t.hour, .minute = t.minute, .second = t.second, .clock = .h24 });
            return;
        }
        if (!isSixty(t.minute)) return w.writeAll("a minute is 0–59");
        return w.writeAll("a second is 0–59");
    }

    /// A time of the 12-hour clock in words: "1 PM", "1:30 PM",
    /// "1:30:15 PM", "midnight", "12:30 AM".
    fn writeName(t: Time, w: *Io.Writer) Io.Writer.Error!void {
        if (t.clock == .am and t.hour == 12 and t.minute == 0 and t.second == 0) return w.writeAll("midnight");
        try w.print("{d}", .{t.hour});
        if (t.minute != 0 or t.second != 0) try w.print(":{d:0>2}", .{@as(u8, @intCast(t.minute))});
        if (t.second != 0) try w.print(":{d:0>2}", .{@as(u8, @intCast(t.second))});
        try w.writeAll(if (t.clock == .am) " AM" else " PM");
    }
};

/// Whether `x` is a minute or a second: 0–59.
fn isSixty(x: i64) bool {
    return x >= 0 and x <= 59;
}

/// A call that takes a time of day, as its texts write it.
pub const Call = union(enum) {
    dailyAt,
    weeklyOn: Weekday,
    /// The day of the month.
    monthlyOn: i64,
    /// The year, the month and the day.
    fromUtc: [3]i64,

    /// Writes the call with the time `t`: `dailyAt(13, 0, 0, .pm)`.
    pub fn write(c: Call, w: *Io.Writer, t: Time) Io.Writer.Error!void {
        switch (c) {
            .dailyAt => try w.writeAll("dailyAt("),
            .weeklyOn => |day| try w.print("weeklyOn(.{t}, ", .{day}),
            .monthlyOn => |day| try w.print("monthlyOn({d}, ", .{day}),
            .fromUtc => |date| try w.print("fromUtc({d}, {d}, {d}, ", .{ date[0], date[1], date[2] }),
        }
        try w.print("{d}, {d}, {d}, .{t})", .{ t.hour, t.minute, t.second, t.clock });
    }
};

/// The arguments of `Instant.fromUtc`.
pub const Utc = struct {
    year: i64,
    month: i64,
    day: i64,
    time: Time,

    /// Milliseconds from the epoch, or null when the arguments are no
    /// moment of the years 1970–9999.
    pub fn unixMs(u: Utc) ?i64 {
        if (u.year < 1970 or u.year > 9999 or u.month < 1 or u.month > 12 or u.day < 1) return null;
        const year: i32 = @intCast(u.year);
        const month: u4 = @intCast(u.month);
        if (u.day > calendar.daysIn(year, month)) return null;
        const second_of_day = u.time.secondOfDay() orelse return null;
        const days = calendar.daysFromCivil(year, month, @intCast(u.day));
        return (days * 86_400 + second_of_day) * 1000;
    }

    /// Writes the call and why `unixMs` refused its arguments:
    /// `fromUtc(2026, 2, 29, 0, 0, 0, .h24): 2026-02-29 is not a date`.
    pub fn writeProblem(u: Utc, w: *Io.Writer) Io.Writer.Error!void {
        const call: Call = .{ .fromUtc = .{ u.year, u.month, u.day } };
        try call.write(w, u.time);
        try w.writeAll(": ");
        if (u.year < 1970 or u.year > 9999) return w.writeAll("a year is 1970–9999");
        if (u.month < 1 or u.month > 12) return w.writeAll("a month is 1–12");
        if (u.day < 1 or u.day > 31) return w.writeAll("a day is 1–31");
        const year: u16 = @intCast(u.year);
        const month: u8 = @intCast(u.month);
        const day: u8 = @intCast(u.day);
        if (day > calendar.daysIn(year, @intCast(month))) return w.print("{d}-{d:0>2}-{d:0>2} is not a date", .{ year, month, day });
        return u.time.writeProblem(call, w);
    }
};
