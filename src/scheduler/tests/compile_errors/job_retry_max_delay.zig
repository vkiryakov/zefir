//! Must not compile: the longest pause is shorter than the first one.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        .retry = .{ .delay = .fromSeconds(10), .max_delay = .fromSeconds(5) },
    };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
