//! The schedule of a repeating job: a value without allocation. The
//! ready-made schedules are functions, written as decl literals:
//! `.everyMinutes(5)`, `.dailyAt(3, 30, 0, .am)`, `.cron("0 30 2 * * *")`.
//! Arguments that the compiler knows are checked at compile time, so
//! `.dailyAt(13, 0, 0, .pm)` does not build, and its error names the call
//! to write instead. Arguments known only at run time give a schedule with
//! the error inside: the call that takes it (`check`, and the client's
//! `schedule` and `reschedule`) answers `error.InvalidArgument` with the
//! text in `Diagnostics`.
//!
//! The canonical text (`format`, `parse`) is what the record of a job
//! keeps: `every 420s`, `delay 30s` or `delay 1500ms`, `daily 15:30:00`,
//! `weekly mon 09:00:00`, `monthly 15 00:00:00`, `cron 0 30 2 * * *`. Its
//! time of day is on the 24-hour clock, however the code wrote it.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Diagnostics = @import("../Diagnostics.zig");
const Instant = @import("../Instant.zig");
const calendar = @import("calendar.zig");
const args = @import("args.zig");
const crontab = @import("cron.zig");
const HourFormat = calendar.HourFormat;
const Weekday = calendar.Weekday;
const Schedule = @This();

/// The canonical form: every, delay, daily, weekly, monthly, cron or
/// invalid. Build a schedule with the functions below and read it with
/// `next`, `check` and `format`.
internal: Internal,

const Internal = union(enum) {
    /// The step in seconds: the multiples of it from the epoch.
    every: u32,
    /// The pause after a run, in milliseconds.
    delay: u64,
    /// The second of the day.
    daily: u17,
    weekly: struct { day: Weekday, second_of_day: u17 },
    /// The day of the month, 1–28, and the second of the day.
    monthly: struct { day: u5, second_of_day: u17 },
    cron: crontab.Cron,
    invalid: Invalid,
};

/// The longest step and the longest delay, in seconds: 100 years of 365.25
/// days, as the longest `.after` of a job.
const max_step = 36_525 * 24 * 60 * 60;
/// The last moment of a schedule: 9999-12-31T23:59:59.999Z.
const last_ms = 253_402_300_799_999;
const ms_per_day = 24 * 60 * 60 * 1000;

/// Every n seconds, minutes or hours: the moments that are multiples of n
/// units from the Unix epoch in UTC. Every instance counts the same
/// moments, and n need not divide a minute, an hour or a day:
/// `.everyMinutes(7)` runs at 00:04, 00:11, …, 00:53, 01:00, 01:07, and
/// `.everyHours(5)` does not start again at midnight. n is 1 or more, and n
/// units are at most 100 years.
pub inline fn everySeconds(n: anytype) Schedule {
    return checked(stepOf, .{ Unit.seconds, args.int("everySeconds", "n", n) });
}

/// Every n minutes from the epoch; see `everySeconds`.
pub inline fn everyMinutes(n: anytype) Schedule {
    return checked(stepOf, .{ Unit.minutes, args.int("everyMinutes", "n", n) });
}

/// Every n hours from the epoch; see `everySeconds`.
pub inline fn everyHours(n: anytype) Schedule {
    return checked(stepOf, .{ Unit.hours, args.int("everyHours", "n", n) });
}

/// `delay` after the end of the run before, by the store's clock; the
/// first run comes `delay` after the job was scheduled. `delay` is a whole
/// number of milliseconds, 1 ms to 100 years.
pub fn fixedDelay(delay: Duration) Schedule {
    const ns = delay.nanoseconds;
    if (ns < std.time.ns_per_ms or @rem(ns, std.time.ns_per_ms) != 0 or ns > max_step * std.time.ns_per_s) {
        return .{ .internal = .{ .invalid = .{ .delay = delay } } };
    }
    return .{ .internal = .{ .delay = @intCast(@divExact(ns, std.time.ns_per_ms)) } };
}

/// Every day at this time of UTC. `clock` says how to read the hour: 12 AM
/// is midnight (00:xx), 12 PM is noon (12:xx). `.dailyAt(3, 30, 0, .pm)`
/// and `.dailyAt(15, 30, 0, .h24)` are the same schedule.
pub inline fn dailyAt(hour: anytype, minute: anytype, second: anytype, clock: HourFormat) Schedule {
    return checked(dailyOf, .{
        args.int("dailyAt", "hour", hour),
        args.int("dailyAt", "minute", minute),
        args.int("dailyAt", "second", second),
        clock,
    });
}

/// Every week on `day` at this time of UTC. The hour reads as in
/// `dailyAt`: 12 AM is midnight (00:xx), 12 PM is noon (12:xx).
pub inline fn weeklyOn(day: Weekday, hour: anytype, minute: anytype, second: anytype, clock: HourFormat) Schedule {
    return checked(weeklyOf, .{
        day,
        args.int("weeklyOn", "hour", hour),
        args.int("weeklyOn", "minute", minute),
        args.int("weeklyOn", "second", second),
        clock,
    });
}

/// Every month on `day`, 1–28, which every month has, at this time of UTC.
/// The hour reads as in `dailyAt`: 12 AM is midnight (00:xx), 12 PM is
/// noon (12:xx). The 29th to the 31st are cron expressions, which skip the
/// months without the day: `.cron("0 0 0 31 * *")`; the last day of a
/// month is not in v1.
pub inline fn monthlyOn(day: anytype, hour: anytype, minute: anytype, second: anytype, clock: HourFormat) Schedule {
    return checked(monthlyOf, .{
        args.int("monthlyOn", "day", day),
        args.int("monthlyOn", "hour", hour),
        args.int("monthlyOn", "minute", minute),
        args.int("monthlyOn", "second", second),
        clock,
    });
}

/// A cron expression in UTC: 5 fields (minute, hour, day of the month,
/// month, day of the week) or 6 with the second first. A field is `*`,
/// `a`, `a-b`, `a,b,…`, `*/n` or `a-b/n`; the names JAN–DEC and SUN–SAT go
/// in any case, and Sunday is 0 and 7. The macros are @yearly, @annually,
/// @monthly, @weekly, @daily, @midnight and @hourly. When neither the day
/// of the month nor the day of the week is exactly `*`, a day that matches
/// either one comes; when one is `*`, the other decides, and `*/2` is no
/// `*`. Not in v1: `?`, `L`, `W`, `#`, `H`, a year, `a/n`, @reboot and
/// @every. The schedule borrows `expression` until the call that takes it
/// returns.
pub inline fn cron(expression: []const u8) Schedule {
    return checked(cronOf, .{expression});
}

fn cronOf(expression: []const u8) Schedule {
    return switch (crontab.parse(expression)) {
        .cron => |parsed| .{ .internal = .{ .cron = parsed } },
        .problem => |problem| .{ .internal = .{ .invalid = .{ .cron = .{ .expression = expression, .problem = problem } } } },
    };
}

/// The first moment of the schedule strictly after `after`. Moments run
/// from the epoch to the end of 9999, and cron looks at most 9 years
/// ahead: null when no moment is left in them, and always for
/// `fixedDelay`, whose time the store counts, and for an invalid schedule.
pub fn next(s: Schedule, after: Instant) ?Instant {
    // A moment before the epoch counts from it.
    const from = @max(after.unix_ms, -1);
    if (from >= last_ms) return null;
    const day = @divFloor(from, ms_per_day);
    const ms: i64 = switch (s.internal) {
        .delay, .invalid => return null,
        .every => |step| ms: {
            const step_ms = @as(i64, step) * 1000;
            break :ms (@divFloor(from, step_ms) + 1) * step_ms;
        },
        .daily => |second_of_day| firstAfter(from, day * ms_per_day + @as(i64, second_of_day) * 1000, ms_per_day),
        .weekly => |weekly| ms: {
            const ahead = @mod(@as(i64, @backingInt(weekly.day)) - @backingInt(calendar.weekdayOf(day)), 7);
            break :ms firstAfter(from, (day + ahead) * ms_per_day + @as(i64, weekly.second_of_day) * 1000, 7 * ms_per_day);
        },
        .monthly => |monthly| ms: {
            const date = calendar.civilFromDays(day);
            const this_month = calendar.daysFromCivil(date.year, date.month, monthly.day) * ms_per_day + @as(i64, monthly.second_of_day) * 1000;
            if (this_month > from) break :ms this_month;
            const year = if (date.month == 12) date.year + 1 else date.year;
            const month: u4 = if (date.month == 12) 1 else date.month + 1;
            break :ms calendar.daysFromCivil(year, month, monthly.day) * ms_per_day + @as(i64, monthly.second_of_day) * 1000;
        },
        .cron => |parsed| parsed.next(from) orelse return null,
    };
    return if (ms > last_ms) null else .fromUnixMs(ms);
}

/// `first`, or one `period` later when `first` is not after `from`.
fn firstAfter(from: i64, first: i64, period: i64) i64 {
    return if (first > from) first else first + period;
}

/// `error.InvalidArgument`, with the text in `d`, when the schedule was
/// built from values that make none: "dailyAt(13, 0, 0, .pm): an hour of
/// the 12-hour clock is 1–12; …".
pub fn check(s: Schedule, d: ?*Diagnostics) error{InvalidArgument}!void {
    switch (s.internal) {
        .invalid => |problem| {
            if (d) |diagnostics| diagnostics.set(null, "{f}", .{problem});
            return error.InvalidArgument;
        },
        else => {},
    }
}

/// The canonical text, which the record of a job keeps; an invalid
/// schedule writes "invalid", which `parse` refuses.
pub fn format(s: Schedule, w: *Io.Writer) Io.Writer.Error!void {
    switch (s.internal) {
        .every => |step| try w.print("every {d}s", .{step}),
        .delay => |ms| if (ms % 1000 == 0) try w.print("delay {d}s", .{ms / 1000}) else try w.print("delay {d}ms", .{ms}),
        .daily => |second_of_day| {
            try w.writeAll("daily ");
            try writeClock(w, second_of_day);
        },
        .weekly => |weekly| {
            try w.print("weekly {s} ", .{day_names[@backingInt(weekly.day)]});
            try writeClock(w, weekly.second_of_day);
        },
        .monthly => |monthly| {
            try w.print("monthly {d} ", .{monthly.day});
            try writeClock(w, monthly.second_of_day);
        },
        .cron => |parsed| try parsed.format(w),
        .invalid => try w.writeAll("invalid"),
    }
}

/// The days of `weekly`, Monday first.
const day_names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

fn writeClock(w: *Io.Writer, second_of_day: u17) Io.Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ second_of_day / 3600, second_of_day / 60 % 60, second_of_day % 60 });
}

/// Reads a canonical text, as `format` writes it, back into a schedule; a
/// cron schedule borrows its expression from `text`. A text that is none
/// is `error.InvalidArgument`, with `plan "<text>": ` and the reason in
/// `d`.
pub fn parse(text: []const u8, d: ?*Diagnostics) error{InvalidArgument}!Schedule {
    if (std.mem.startsWith(u8, text, "cron ")) {
        return switch (crontab.parse(text["cron ".len..])) {
            .cron => |parsed| .{ .internal = .{ .cron = parsed } },
            .problem => |problem| refuse(d, text, "{f}", .{problem}),
        };
    }
    var words: [4][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |word| : (count += 1) {
        if (count == words.len) return refuse(d, text, forms, .{});
        words[count] = word;
    }
    const kind = words[0];
    if (count == 2 and std.mem.eql(u8, kind, "every")) {
        const n = number(words[1], "s") orelse return refuse(d, text, forms, .{});
        if (n < 1 or n > max_step) return refuse(d, text, "a step is 1 s to 100 years", .{});
        return .{ .internal = .{ .every = @intCast(n) } };
    }
    if (count == 2 and std.mem.eql(u8, kind, "delay")) {
        const ms = if (number(words[1], "ms")) |n| n else if (number(words[1], "s")) |n| n *| 1000 else return refuse(d, text, forms, .{});
        if (ms < 1 or ms > max_step * 1000) return refuse(d, text, "a delay is 1 ms to 100 years", .{});
        return .{ .internal = .{ .delay = ms } };
    }
    if (count == 2 and std.mem.eql(u8, kind, "daily")) {
        return .{ .internal = .{ .daily = try clockOf(words[1], text, d) } };
    }
    if (count == 3 and std.mem.eql(u8, kind, "weekly")) {
        const day = for (day_names, 0..) |name, i| {
            if (std.mem.eql(u8, words[1], name)) break @as(Weekday, @fromBackingInt(@as(u3, @intCast(i))));
        } else return refuse(d, text, "{f} is no day; the days are mon, tue, wed, thu, fri, sat and sun", .{args.Quoted{ .text = words[1] }});
        return .{ .internal = .{ .weekly = .{ .day = day, .second_of_day = try clockOf(words[2], text, d) } } };
    }
    if (count == 3 and std.mem.eql(u8, kind, "monthly")) {
        const day = number(words[1], "") orelse 0;
        if (day < 1 or day > 28) return refuse(d, text, "a day of monthly is 1–28", .{});
        return .{ .internal = .{ .monthly = .{ .day = @intCast(day), .second_of_day = try clockOf(words[2], text, d) } } };
    }
    return refuse(d, text, forms, .{});
}

const forms = "not a schedule; a plan is every <n>s, delay <n>s, delay <n>ms, daily HH:MM:SS, " ++
    "weekly <day> HH:MM:SS, monthly <day> HH:MM:SS or cron <fields>";

fn refuse(d: ?*Diagnostics, text: []const u8, comptime reason: []const u8, reason_args: anytype) error{InvalidArgument} {
    if (d) |diagnostics| diagnostics.set(null, "plan \"{f}\": " ++ reason, .{args.Quoted{ .text = text }} ++ reason_args);
    return error.InvalidArgument;
}

/// The decimal number of `word` before `unit`, which ends the word; null
/// when the word is no number with that unit. A number too big for `u64`
/// saturates, to fail the range of its form.
fn number(word: []const u8, unit: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, word, unit) or word.len == unit.len) return null;
    var n: u64 = 0;
    for (word[0 .. word.len - unit.len]) |c| {
        if (c < '0' or c > '9') return null;
        n = n *| 10 +| (c - '0');
    }
    return n;
}

/// The second of the day of `HH:MM:SS`.
fn clockOf(word: []const u8, text: []const u8, d: ?*Diagnostics) error{InvalidArgument}!u17 {
    if (word.len != 8 or word[2] != ':' or word[5] != ':') return refuse(d, text, "a time is HH:MM:SS", .{});
    const hour = number(word[0..2], "") orelse return refuse(d, text, "a time is HH:MM:SS", .{});
    const minute = number(word[3..5], "") orelse return refuse(d, text, "a time is HH:MM:SS", .{});
    const second = number(word[6..8], "") orelse return refuse(d, text, "a time is HH:MM:SS", .{});
    if (hour > 23) return refuse(d, text, "an hour is 00–23", .{});
    if (minute > 59) return refuse(d, text, "a minute is 00–59", .{});
    if (second > 59) return refuse(d, text, "a second is 00–59", .{});
    return @intCast(hour * 3600 + minute * 60 + second);
}

/// The unit of a step, as its length in seconds.
const Unit = enum(u32) {
    seconds = 1,
    minutes = 60,
    hours = 60 * 60,

    fn call(unit: Unit) []const u8 {
        return switch (unit) {
            .seconds => "everySeconds",
            .minutes => "everyMinutes",
            .hours => "everyHours",
        };
    }

    /// The most units of a step: 100 years.
    fn most(unit: Unit) i64 {
        return max_step / @backingInt(unit);
    }
};

fn stepOf(unit: Unit, n: i64) Schedule {
    if (n < 1 or n > unit.most()) return .{ .internal = .{ .invalid = .{ .every = .{ .unit = unit, .n = n } } } };
    return .{ .internal = .{ .every = @intCast(n * @backingInt(unit)) } };
}

fn dailyOf(hour: i64, minute: i64, second: i64, clock: HourFormat) Schedule {
    return timeOf(.dailyAt, .{ .hour = hour, .minute = minute, .second = second, .clock = clock });
}

fn weeklyOf(day: Weekday, hour: i64, minute: i64, second: i64, clock: HourFormat) Schedule {
    return timeOf(.{ .weeklyOn = day }, .{ .hour = hour, .minute = minute, .second = second, .clock = clock });
}

fn monthlyOf(day: i64, hour: i64, minute: i64, second: i64, clock: HourFormat) Schedule {
    return timeOf(.{ .monthlyOn = day }, .{ .hour = hour, .minute = minute, .second = second, .clock = clock });
}

/// A schedule at a time of day. monthlyOn checks the time first, so that
/// the hint for a day it refuses carries a right time.
fn timeOf(call: args.Call, t: args.Time) Schedule {
    const invalid: Schedule = .{ .internal = .{ .invalid = .{ .time = .{ .call = call, .time = t } } } };
    const second_of_day = t.secondOfDay() orelse return invalid;
    return switch (call) {
        .dailyAt => .{ .internal = .{ .daily = second_of_day } },
        .weeklyOn => |day| .{ .internal = .{ .weekly = .{ .day = day, .second_of_day = second_of_day } } },
        .monthlyOn => |day| if (day < 1 or day > 28) invalid else .{ .internal = .{ .monthly = .{ .day = @intCast(day), .second_of_day = second_of_day } } },
        // A moment, which no schedule is.
        .fromUtc => unreachable,
    };
}

/// `make(values)`, at compile time when the compiler knows every value: an
/// invalid schedule then stops the build with the text that `check` would
/// give, after "scheduler: ".
inline fn checked(comptime make: anytype, values: anytype) Schedule {
    if (comptime args.known(@TypeOf(values))) {
        return comptime built: {
            @setEvalBranchQuota(100_000);
            const s: Schedule = @call(.auto, make, values);
            switch (s.internal) {
                .invalid => |problem| @compileError("scheduler: " ++ std.fmt.comptimePrint("{f}", .{problem})),
                else => break :built s,
            }
        };
    }
    return @call(.auto, make, values);
}

/// The arguments of a call that make no schedule, kept so that `check`
/// can say what is wrong with them.
const Invalid = union(enum) {
    every: struct { unit: Unit, n: i64 },
    delay: Duration,
    time: struct { call: args.Call, time: args.Time },
    cron: struct { expression: []const u8, problem: crontab.Problem },

    /// The call and why it makes no schedule: the text of `check`, and of
    /// the compile error after "scheduler: ".
    pub fn format(problem: Invalid, w: *Io.Writer) Io.Writer.Error!void {
        switch (problem) {
            .every => |every| {
                try w.print("{s}({d}): ", .{ every.unit.call(), every.n });
                if (every.n < 1) return w.writeAll("n is 1 or more");
                return w.print("n is at most {d}, which is 100 years", .{every.unit.most()});
            },
            .delay => |delay| {
                try w.print("fixedDelay({f}): ", .{delay});
                if (delay.nanoseconds > max_step * std.time.ns_per_s) return w.writeAll("a delay is at most 100 years");
                return w.writeAll("a delay is a whole number of milliseconds, 1 or more");
            },
            .cron => |refused| try w.print("cron \"{f}\": {f}", .{ args.Quoted{ .text = refused.expression }, refused.problem }),
            .time => |at| {
                try at.call.write(w, at.time);
                try w.writeAll(": ");
                const second_of_day = at.time.secondOfDay() orelse return at.time.writeProblem(at.call, w);
                // The time is right, so the day of monthlyOn is not.
                const day = switch (at.call) {
                    .monthlyOn => |day| day,
                    else => unreachable,
                };
                try w.writeAll("a day of monthlyOn is 1–28, which every month has");
                if (day < 29 or day > 31) return;
                try w.print("; the {d}{s} of the months that have one is .cron(\"{d} {d} {d} {d} * *\"); the last day of a month is not in v1", .{
                    day,
                    if (day == 31) "st" else "th",
                    second_of_day % 60,
                    second_of_day / 60 % 60,
                    second_of_day / 3600,
                    day,
                });
            },
        }
    }
};
