//! Must not compile: 2026 is no leap year.
const scheduler = @import("scheduler");

test {
    const moment: scheduler.Instant = .fromUtc(2026, 2, 29, 0, 0, 0, .h24);
    _ = moment;
}
