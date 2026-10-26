//! Must not compile: 30 February never comes, and the day of the week,
//! `*`, leaves the day of the month to decide.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .cron("0 0 30 2 *");
    _ = s;
}
