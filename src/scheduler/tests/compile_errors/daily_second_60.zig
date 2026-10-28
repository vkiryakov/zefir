//! Must not compile: a second is 0–59.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .dailyAt(9, 0, 60, .am);
    _ = s;
}
