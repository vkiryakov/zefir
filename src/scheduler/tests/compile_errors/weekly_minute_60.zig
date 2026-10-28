//! Must not compile: a minute is 0–59.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .weeklyOn(.monday, 9, 60, 0, .am);
    _ = s;
}
