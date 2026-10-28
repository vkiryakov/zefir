//! Must not compile: a job name with a capital letter.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "Send" };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
