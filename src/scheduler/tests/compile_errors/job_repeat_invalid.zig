//! Must not compile: fixedDelay is no inline function, so a declaration
//! is where its value is checked at compile time.
const scheduler = @import("scheduler");

const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .fixedDelay(.zero) };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .declared(NightlyCleanup);
    _ = ref;
}
