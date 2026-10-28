//! Must not compile: a declaration written as a literal without its type
//! is an anonymous struct, not a scheduler.Job.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job = .{ .name = "send-invoice" };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
