//! Must not compile: L, the last day of a month, is not in v1.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .cron("0 0 L * *");
    _ = s;
}
