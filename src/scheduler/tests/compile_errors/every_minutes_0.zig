//! Must not compile: a step of no minutes.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .everyMinutes(0);
    _ = s;
}
