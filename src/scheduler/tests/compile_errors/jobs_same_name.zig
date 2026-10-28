//! Must not compile: two job types of one worker with the same name; the
//! store could not tell their records apart.
const scheduler = @import("scheduler");

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

const Reminder = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };

    pub fn run(self: *Reminder, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

test {
    _ = scheduler.Worker(struct { invoices: *SendInvoiceJob, reminders: *Reminder });
}
