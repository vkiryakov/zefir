//! Must not compile: the declared record of a repeat carries Payload{},
//! and a field of this Payload has no default.
const scheduler = @import("scheduler");

const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(3, 30, 0, .am) };
    pub const Payload = struct { older_than_days: u32, dry_run: bool = false };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

test {
    const ref: scheduler.Ref = .declared(NightlyCleanup);
    _ = ref;
}
