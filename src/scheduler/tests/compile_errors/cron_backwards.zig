//! Must not compile: a range goes up, and Saturday to Sunday, which wraps
//! round the end of the week, is Saturday to 7.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .cron("0 0 * * SAT-SUN");
    _ = s;
}
