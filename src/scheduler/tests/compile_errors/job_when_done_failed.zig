//! Must not compile: a failed job kept for no time; `.none` removes it
//! at once.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice", .when_done = .{ .failed = .{ .keep_for = .zero } } };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
