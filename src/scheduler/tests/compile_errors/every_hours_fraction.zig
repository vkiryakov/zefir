//! Must not compile: a step is a whole number of units.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .everyHours(1.5);
    _ = s;
}
