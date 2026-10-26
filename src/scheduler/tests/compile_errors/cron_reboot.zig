//! Must not compile: @reboot is not in v1.
const scheduler = @import("scheduler");

test {
    const s: scheduler.Schedule = .cron("@reboot");
    _ = s;
}
