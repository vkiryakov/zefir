//! Must not compile: a job name with a capital letter.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "Send" };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
