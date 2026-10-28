//! Must not compile: a retry without a pause.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice", .retry = .{ .delay = .zero } };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
