//! Must not compile: a field of `Jobs` that holds a job by value; the
//! worker takes a pointer to each job, which the application owns.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    _ = scheduler.Worker(struct { invoices: SendInvoiceJob });
}
