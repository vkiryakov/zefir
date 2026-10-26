//! Must not compile: monthlyOn takes the days that every month has; the
//! 29th is a cron expression, which skips the months without it.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .monthlyOn(29, 0, 0, 0, .h24);
    _ = s;
}
