//! When jobs run: the next moments of schedules after a fixed moment,
//! Saturday 2026-10-24 at midnight UTC, so that every run prints the same.
//! A schedule is a value without memory of its own: the code builds it
//! with a ready-made function or a cron expression, the compiler checks
//! the arguments it knows, `next` gives the first moment after a moment,
//! and `format` writes the text that the record of a job keeps. Values
//! known only at run time, such as settings, are checked by `check`, as
//! the client checks a schedule it is given. No store, no worker: `zig
//! build test-scheduler` runs it.

const std = @import("std");
const scheduler = @import("scheduler");
const Schedule = scheduler.Schedule;

/// The moment the next runs count from: Saturday 24 October 2026, 00:00
/// UTC.
const start: scheduler.Instant = .fromUtc(2026, 10, 24, 0, 0, 0, .h24);

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.writeAll("The next runs after Sat 2026-10-24 00:00:00 UTC\n");

    try out.writeAll("\nEvery n seconds, minutes or hours, counted from the Unix epoch:\n");
    try show(out, ".everySeconds(45)", .everySeconds(45), 3);
    try show(out, ".everyMinutes(15)", .everyMinutes(15), 4);
    try show(out, ".everyMinutes(7)", .everyMinutes(7), 10);
    try show(out, ".everyHours(6)", .everyHours(6), 4);
    try show(out, ".everyHours(5)", .everyHours(5), 5);
    // A cron step starts again at each hour, a step from the epoch does not.
    try show(out, ".cron(\"*/7 * * * *\")", .cron("*/7 * * * *"), 10);

    try out.writeAll("\nTimes of day, by the clock the last argument names; 12 AM is midnight, 12 PM is noon:\n");
    try show(out, ".dailyAt(12, 0, 0, .am)", .dailyAt(12, 0, 0, .am), 1);
    try show(out, ".dailyAt(12, 30, 0, .am)", .dailyAt(12, 30, 0, .am), 1);
    try show(out, ".dailyAt(1, 0, 0, .am)", .dailyAt(1, 0, 0, .am), 1);
    try show(out, ".dailyAt(11, 59, 59, .am)", .dailyAt(11, 59, 59, .am), 1);
    try show(out, ".dailyAt(12, 0, 0, .pm)", .dailyAt(12, 0, 0, .pm), 1);
    try show(out, ".dailyAt(3, 30, 0, .pm)", .dailyAt(3, 30, 0, .pm), 1);
    try show(out, ".dailyAt(11, 0, 0, .pm)", .dailyAt(11, 0, 0, .pm), 1);
    try show(out, ".dailyAt(0, 0, 0, .h24)", .dailyAt(0, 0, 0, .h24), 1);
    try show(out, ".dailyAt(15, 30, 0, .h24)", .dailyAt(15, 30, 0, .h24), 1);
    try show(out, ".weeklyOn(.monday, 9, 0, 0, .am)", .weeklyOn(.monday, 9, 0, 0, .am), 2);
    try show(out, ".monthlyOn(1, 0, 0, 0, .h24)", .monthlyOn(1, 0, 0, 0, .h24), 2);

    try out.writeAll("\nCron, in UTC:\n");
    try show(out, ".cron(\"0 30 2 * * *\")", .cron("0 30 2 * * *"), 2);
    try show(out, ".cron(\"0 9 * * MON-FRI\")", .cron("0 9 * * MON-FRI"), 3);
    try show(out, ".cron(\"@weekly\")", .cron("@weekly"), 2);
    // Neither day field is *: a day that matches either one comes.
    try show(out, ".cron(\"0 0 13 * FRI\")", .cron("0 0 13 * FRI"), 4);
    // */2 is no *: the odd days of the month, or a Monday.
    try show(out, ".cron(\"0 0 */2 * MON\")", .cron("0 0 */2 * MON"), 5);
    // The months without the day are skipped.
    try show(out, ".cron(\"0 0 0 31 * *\")", .cron("0 0 0 31 * *"), 4);
    try show(out, ".cron(\"0 0 29 2 *\")", .cron("0 0 29 2 *"), 2);

    try out.writeAll("\nAfter each run, counted by the store:\n");
    try show(out, ".fixedDelay(.fromSeconds(30))", .fixedDelay(.fromSeconds(30)), 1);

    try out.writeAll("\nValues the program reads when it runs, which the compiler cannot check:\n");
    try fromSettings(out, 1, .pm, "0 0 30 * *");
    try fromSettings(out, 13, .pm, "0 0 30 2 *");
    try out.flush();
}

/// How the code writes the schedule and the text that the record of a job
/// keeps, then its first `count` moments after `start`, each with its date
/// when that is not the date of the moment before: one moment on the same
/// line, more on a line of their own.
fn show(out: *std.Io.Writer, code: []const u8, schedule: Schedule, count: usize) !void {
    var text: [64]u8 = undefined;
    const canonical = try std.fmt.bufPrint(&text, "{f}", .{schedule});
    if (count == 1) {
        try out.print("  {s: <34} {s: <20}", .{ code, canonical });
    } else {
        try out.print("  {s: <34} {s}\n     ", .{ code, canonical });
    }
    var after = start;
    var day: ?i64 = null;
    for (0..count) |i| {
        const moment = schedule.next(after) orelse {
            try out.writeAll(" none: the store counts it after each run");
            break;
        };
        const moment_day = @divFloor(moment.unix_ms, std.time.ms_per_day);
        try out.writeAll(if (i == 0) " " else ", ");
        try printMoment(out, moment, moment_day != day);
        day = moment_day;
        after = moment;
    }
    try out.writeByte('\n');
}

/// A moment as "Sat 2026-10-24 00:04:00", the RFC 3339 text of
/// `Instant.format` without its milliseconds; only its time, "00:04:00",
/// when `with_date` is false.
fn printMoment(out: *std.Io.Writer, moment: scheduler.Instant, with_date: bool) !void {
    var text: [32]u8 = undefined;
    const rfc3339 = try std.fmt.bufPrint(&text, "{f}", .{moment});
    if (with_date) {
        // 1970-01-01, the day 0, was a Thursday.
        const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        const days = @divFloor(moment.unix_ms, std.time.ms_per_day);
        try out.print("{s} {s} ", .{ weekdays[@intCast(@mod(days, 7))], rfc3339[0..10] });
    }
    try out.writeAll(rfc3339[11..19]);
}

/// Schedules from the settings of a service, known only when it runs: the
/// hour of a nightly report and a cron expression. A wrong value makes no
/// compile error; the schedule carries the problem, and `check`, as the
/// `schedule` and `reschedule` of the client, answers
/// `error.InvalidArgument` with the same text as the compiler's.
fn fromSettings(out: *std.Io.Writer, hour: u8, clock: scheduler.HourFormat, expression: []const u8) !void {
    for ([_]Schedule{ .dailyAt(hour, 0, 0, clock), .cron(expression) }) |schedule| {
        var d: scheduler.Diagnostics = .{};
        if (schedule.check(&d)) |_| {
            try out.print("  ok: {f}\n", .{schedule});
        } else |err| {
            try out.print("  error.{t}: {s}\n", .{ err, d.message() });
        }
    }
}
