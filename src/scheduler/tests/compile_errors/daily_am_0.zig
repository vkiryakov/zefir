//! Must not compile: 0 is no hour of the 12-hour clock; midnight is 12
//! with .am, or 0 with .h24.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .dailyAt(0, 0, 0, .am);
    _ = s;
}
