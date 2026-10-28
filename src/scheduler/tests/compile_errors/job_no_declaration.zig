//! Must not compile: a job type without its declaration; the message
//! names the declaration to write, with the type's name in kebab case.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const Payload = struct { order_id: u64 };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

test {
    const ref: scheduler.Ref = .of(SendInvoiceJob, "order-42");
    _ = ref;
}
