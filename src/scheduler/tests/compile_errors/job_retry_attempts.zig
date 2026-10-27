//! Must not compile: zero attempts would never run the job.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice", .retry = .{ .attempts = 0 } };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
