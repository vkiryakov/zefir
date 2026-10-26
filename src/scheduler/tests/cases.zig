//! What build.zig compiles for the compile checks of zefir-scheduler,
//! read by `addSchedulerCompileChecks`. Paths are relative to the
//! repository root and stay inside `src/`, the part of the package that
//! `build.zig.zon` ships, since a client's build runs zefir's build.zig
//! too. Each file is application code: a `test` block that imports
//! "scheduler" and makes a call that the compiler must refuse.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

/// Files in src/scheduler/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // Schedules: the hour on each clock, the minute, the second, the day of
    // monthlyOn, a step.
    .{ .file = dir ++ "daily_pm_13.zig", .expect = "scheduler: dailyAt(13, 0, 0, .pm): " ++ twelve ++ "1 PM is .dailyAt(1, 0, 0, .pm), or .dailyAt(13, 0, 0, .h24)" },
    .{ .file = dir ++ "daily_am_15.zig", .expect = "scheduler: dailyAt(15, 30, 0, .am): " ++ twelve ++ "3:30 PM is .dailyAt(3, 30, 0, .pm), or .dailyAt(15, 30, 0, .h24)" },
    .{ .file = dir ++ "daily_am_0.zig", .expect = "scheduler: dailyAt(0, 0, 0, .am): " ++ twelve ++ "midnight is .dailyAt(12, 0, 0, .am), or .dailyAt(0, 0, 0, .h24)" },
    .{ .file = dir ++ "daily_h24_24.zig", .expect = "scheduler: dailyAt(24, 0, 0, .h24): an hour of the 24-hour clock is 0–23" },
    .{ .file = dir ++ "weekly_minute_60.zig", .expect = "scheduler: weeklyOn(.monday, 9, 60, 0, .am): a minute is 0–59" },
    .{ .file = dir ++ "daily_second_60.zig", .expect = "scheduler: dailyAt(9, 0, 60, .am): a second is 0–59" },
    .{ .file = dir ++ "monthly_29.zig", .expect = "scheduler: monthlyOn(29, 0, 0, 0, .h24): " ++ every_month ++
        "the 29th of the months that have one is .cron(\"0 0 0 29 * *\"); the last day of a month is not in v1" },
    .{ .file = dir ++ "monthly_31.zig", .expect = "scheduler: monthlyOn(31, 0, 0, 0, .h24): " ++ every_month ++
        "the 31st of the months that have one is .cron(\"0 0 0 31 * *\"); the last day of a month is not in v1" },
    .{ .file = dir ++ "every_minutes_0.zig", .expect = "scheduler: everyMinutes(0): n is 1 or more" },
    .{ .file = dir ++ "every_hours_fraction.zig", .expect = "scheduler: everyHours: n is an integer, not comptime_float" },
    // Cron literals.
    .{ .file = dir ++ "cron_february_30.zig", .expect = "scheduler: cron \"0 0 30 2 *\": day 30 never comes in February, and the day of the week is *" },
    .{ .file = dir ++ "cron_reboot.zig", .expect = "scheduler: cron \"@reboot\": @reboot is not in v1" },
    .{ .file = dir ++ "cron_last.zig", .expect = "scheduler: cron \"0 0 L * *\": field 3, the day of the month, \"L\": L is not in v1" },
    // Decl literals through an optional field of a declaration and through
    // a union built at run time.
    .{ .file = dir ++ "declared_cron.zig", .expect = "scheduler: cron \"0 0 31 4,6,9,11 *\": day 31 never comes in April, June, September or November, " ++
        "and the day of the week is *" },
    .{ .file = dir ++ "when_at_run_time.zig", .expect = "scheduler: weeklyOn(.friday, 5, 0, 60, .pm): a second is 0–59" },
    // Moments.
    .{ .file = dir ++ "from_utc_february_29.zig", .expect = "scheduler: fromUtc(2026, 2, 29, 0, 0, 0, .h24): 2026-02-29 is not a date" },
};

const twelve = "an hour of the 12-hour clock is 1–12; ";
const every_month = "a day of monthlyOn is 1–28, which every month has; ";

const dir = "src/scheduler/tests/compile_errors/";
