//! Must not compile: the 31st, which five months a year lack.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .monthlyOn(31, 0, 0, 0, .h24);
    _ = s;
}
