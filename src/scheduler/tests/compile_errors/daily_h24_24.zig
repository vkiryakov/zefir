//! Must not compile: the 24-hour clock ends at 23.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .dailyAt(24, 0, 0, .h24);
    _ = s;
}
