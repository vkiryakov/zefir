//! Must not compile: a threshold of zero would skip every run that is a
//! moment late.
const scheduler = @import("scheduler");

const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "nightly-cleanup",
        .repeat = .dailyAt(3, 30, 0, .am),
        .misfire = .{ .skip = .zero },
    };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .declared(NightlyCleanup);
    _ = ref;
}
