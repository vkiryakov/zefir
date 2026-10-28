//! A moment of UTC to the millisecond: the time that a store keeps, in
//! milliseconds from 1970-01-01T00:00:00Z.

const std = @import("std");
const Io = std.Io;
const calendar = @import("schedule/calendar.zig");
const args = @import("schedule/args.zig");
const HourFormat = calendar.HourFormat;
const Instant = @This();

unix_ms: i64,

/// No moment: what `fromUtc` gives for values known only at run time that
/// are no moment of the years 1970–9999 or no hour of their clock. A call
/// that takes it answers `error.InvalidArgument`, and `Schedule.next`
/// null; `format` writes "invalid".
pub const invalid: Instant = .{ .unix_ms = std.math.minInt(i64) };

const ms_per_day = 24 * 60 * 60 * 1000;

pub fn fromUnixMs(ms: i64) Instant {
    return .{ .unix_ms = ms };
}

/// A moment of the clock `.real`:
/// `.fromTimestamp(std.Io.Clock.real.now(io))`. The part of a millisecond
/// is dropped.
pub fn fromTimestamp(t: Io.Timestamp) Instant {
    return .{ .unix_ms = saturate(@divFloor(t.nanoseconds, std.time.ns_per_ms)) };
}

/// `d` later, or earlier when `d` is negative. It saturates instead of
/// overflowing, and `invalid` stays `invalid`.
pub fn add(i: Instant, d: Io.Duration) Instant {
    if (i.unix_ms == invalid.unix_ms) return invalid;
    return .{ .unix_ms = saturate(@as(i128, i.unix_ms) + @divFloor(d.nanoseconds, std.time.ns_per_ms)) };
}

/// A moment of the calendar in UTC. `clock` says how to read the hour: 12
/// AM is midnight (00:xx), 12 PM is noon (12:xx). Arguments known at
/// compile time are checked there, so `.fromUtc(2026, 2, 29, 0, 0, 0,
/// .h24)` does not build; values known only at run time that are no moment
/// of the years 1970–9999, or no hour of their clock, give `invalid`.
pub inline fn fromUtc(year: anytype, month: anytype, day: anytype, hour: anytype, minute: anytype, second: anytype, clock: HourFormat) Instant {
    if (comptime args.known(@TypeOf(.{ year, month, day, hour, minute, second, clock }))) {
        return comptime check: {
            @setEvalBranchQuota(10_000);
            const u = utc(year, month, day, hour, minute, second, clock);
            const ms = u.unixMs() orelse @compileError("scheduler: " ++ std.fmt.comptimePrint("{f}", .{std.fmt.alt(u, .writeProblem)}));
            break :check fromUnixMs(ms);
        };
    }
    const u = utc(year, month, day, hour, minute, second, clock);
    return .{ .unix_ms = u.unixMs() orelse return invalid };
}

inline fn utc(year: anytype, month: anytype, day: anytype, hour: anytype, minute: anytype, second: anytype, clock: HourFormat) args.Utc {
    return .{
        .year = args.int("fromUtc", "year", year),
        .month = args.int("fromUtc", "month", month),
        .day = args.int("fromUtc", "day", day),
        .time = .{
            .hour = args.int("fromUtc", "hour", hour),
            .minute = args.int("fromUtc", "minute", minute),
            .second = args.int("fromUtc", "second", second),
            .clock = clock,
        },
    };
}

/// RFC 3339 in UTC with milliseconds: "2026-10-24T15:30:00.000Z". A year
/// beyond 0–9999 keeps its sign, as "+292278994", and `invalid` writes
/// "invalid".
pub fn format(i: Instant, w: *Io.Writer) Io.Writer.Error!void {
    if (i.unix_ms == invalid.unix_ms) return w.writeAll("invalid");
    const date = calendar.civilFromDays(@divFloor(i.unix_ms, ms_per_day));
    const ms: u32 = @intCast(@mod(i.unix_ms, ms_per_day));
    if (date.year >= 0 and date.year <= 9999) {
        try w.print("{d:0>4}", .{@as(u16, @intCast(date.year))});
    } else {
        try w.print("{c}{d:0>4}", .{ @as(u8, if (date.year < 0) '-' else '+'), @abs(date.year) });
    }
    try w.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        date.month,
        date.day,
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000,
    });
}

/// `ms` within the moments of `i64`, short of `invalid`.
fn saturate(ms: i128) i64 {
    return @intCast(std.math.clamp(ms, std.math.minInt(i64) + 1, std.math.maxInt(i64)));
}
