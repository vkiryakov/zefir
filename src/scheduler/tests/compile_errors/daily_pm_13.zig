//! Must not compile: 13 is no hour of the 12-hour clock; 1 PM is 1 with
//! .pm, or 13 with .h24.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .dailyAt(13, 0, 0, .pm);
    _ = s;
}
