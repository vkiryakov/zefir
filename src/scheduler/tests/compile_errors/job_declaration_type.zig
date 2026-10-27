//! Must not compile: the declaration of a job is a scheduler.Job, not
//! its name alone.
const scheduler = @import("scheduler");

const SendInvoice = struct {
    pub const scheduler_job: []const u8 = "send-invoice";

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoice, "order-42");
    _ = ref;
}
