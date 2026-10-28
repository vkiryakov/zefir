//! Must not compile: the declaration of a job is a scheduler.Job, not
//! its name alone.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: []const u8 = "send-invoice";

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
