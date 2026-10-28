//! Must not compile: an hour of the 24-hour clock, 15, given with .am.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .dailyAt(15, 30, 0, .am);
    _ = s;
}
