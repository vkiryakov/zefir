//! Must not compile: the longest pause is shorter than the first one.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        .retry = .{ .delay = .fromSeconds(10), .max_delay = .fromSeconds(5) },
    };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
