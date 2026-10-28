//! Must not compile: a job without `run`; without Payload, the expected
//! `run` has no third parameter.
const scheduler = @import("scheduler");

const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(3, 30, 0, .am) };

    pub fn cleanUp(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .declared(NightlyCleanup);
    _ = ref;
}
