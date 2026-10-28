//! Must not compile: a succeeded job kept for no time; `.none` removes it
//! at once.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice", .when_done = .{ .succeeded = .{ .keep_for = .zero } } };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
