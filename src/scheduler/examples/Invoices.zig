//! The jobs of the invoices of a shop, which jobs_test.zig tests, and the
//! two systems they write to. A job runs at least once, so a run may come
//! twice, and each system does the work of a run once, by its run key,
//! which is the same for every attempt of the run. The ledger also keeps
//! an owner whose claim was taken over, and who goes on anyway, from
//! posting after the claim that took it over, by the life of the record
//! and the number of the claim; that alone would not stop a repeat, since
//! the claim that takes over has the greater number.

const std = @import("std");
const scheduler = @import("scheduler");

/// The billing service, in memory: it sends the invoice of a run key
/// once, so a second run of the same run sends nothing.
pub const Billing = struct {
    mutex: std.Io.Mutex = .init,
    /// The run keys of the invoices sent.
    sent: std.BufSet,
    /// The orders cancelled since their invoices were scheduled.
    gone: []const u64 = &.{},
    reminders: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Billing {
        return .{ .sent = .init(gpa) };
    }

    pub fn deinit(b: *Billing) void {
        b.sent.deinit();
    }

    /// Sends the invoice of `order_id`, unless the invoice of `run_key`
    /// went out before.
    pub fn send(b: *Billing, io: std.Io, run_key: []const u8, order_id: u64) !void {
        if (std.mem.findScalar(u64, b.gone, order_id) != null) return error.OrderGone;
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        if (b.sent.contains(run_key)) return;
        try b.sent.insert(run_key);
    }

    /// Reminds the customers of their unpaid invoices.
    pub fn remindUnpaid(b: *Billing, io: std.Io) !void {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        b.reminders += 1;
    }

    /// How many invoices went out.
    pub fn count(b: *Billing, io: std.Io) usize {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        return b.sent.count();
    }
};

/// The invoice of an order: a job for each order, by its key.
pub const SendInvoice = struct {
    billing: *Billing,

    pub const scheduler_job: scheduler.Job = .{
        .name = "send-invoice",
        // A run past 30 s is cancelled, and counts as a failed attempt.
        .timeout = .fromSeconds(30),
        // An order that is gone gets no invoice, however often it tries.
        .retry = .{ .give_up_on = &.{error.OrderGone} },
        // A row of history for each attempt, kept for 90 days.
        .history = .{ .keep_for = .fromSeconds(90 * 24 * 60 * 60) },
    };

    /// The data of one run: the store keeps it as JSON.
    pub const Payload = struct {
        order_id: u64,
        amount_cents: u64,
        /// A field that a later version added has a default, so the jobs
        /// that an earlier version scheduled still read.
        note: ?[]const u8 = null,
    };

    pub fn run(self: *SendInvoice, ctx: *scheduler.Context, payload: Payload) !void {
        // The run key is the same for every attempt of this run: the key
        // of idempotency for the billing service.
        try self.billing.send(ctx.io(), ctx.info().run_key, payload.order_id);
    }
};

/// The ledger of the shop. It closes the days of a run once, by its run
/// key, so the same run again, as after a crash of the instance that ran
/// it before it wrote the outcome, closes nothing more. And it refuses the
/// post of a claim older than one that posted for the same record: an
/// owner whose claim was taken over, and who goes on anyway, writes
/// nothing after the claim that took it over.
pub const Ledger = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// The run keys of the runs that closed days.
    closed: std.BufSet,
    /// The newest claim that posted, for each life of a record: the fence
    /// alone would not do, since a record made again with the same key
    /// counts its claims from 1 again.
    fences: std.AutoHashMapUnmanaged(scheduler.Life, u64) = .empty,
    days_closed: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Ledger {
        return .{ .gpa = gpa, .closed = .init(gpa) };
    }

    pub fn deinit(l: *Ledger) void {
        l.closed.deinit();
        l.fences.deinit(l.gpa);
    }

    /// Closes `days` days for the run `run_key`, which the claim `fence` of
    /// the record of `life` posts: nothing when the run closed them before,
    /// and error.StaleClaim when a newer claim of the record posted.
    pub fn closeDays(l: *Ledger, io: std.Io, run_key: []const u8, life: scheduler.Life, fence: u64, days: u32) !void {
        try l.mutex.lock(io);
        defer l.mutex.unlock(io);
        const newest = try l.fences.getOrPut(l.gpa, life);
        if (newest.found_existing and fence < newest.value_ptr.*) return error.StaleClaim;
        newest.value_ptr.* = fence;
        if (l.closed.contains(run_key)) return;
        try l.closed.insert(run_key);
        l.days_closed += days;
    }
};

/// Closes the day in the ledger, every night at 11 PM. The code declares
/// it, so the worker keeps its record. A run that stands for the nights
/// the shop was down closes those days too.
pub const CloseDay = struct {
    ledger: *Ledger,

    pub const scheduler_job: scheduler.Job = .{
        .name = "close-day",
        .repeat = .dailyAt(11, 0, 0, .pm),
        // Three attempts for each night: a run that fails, or whose
        // instance is lost, runs again within the night. The ledger closes
        // the days of a run once, however often it runs.
        .retry = .{ .attempts = 3 },
    };

    pub fn run(self: *CloseDay, ctx: *scheduler.Context) !void {
        const info = ctx.info();
        // One run for the nights it missed too: misfire is .coalesce.
        try self.ledger.closeDays(ctx.io(), info.run_key, info.life, info.fence, 1 + info.missed);
    }
};

/// Reminds the customers of their unpaid invoices, every morning at 9 AM.
/// A run later than 10 AM is skipped: a customer gets no reminder in the
/// afternoon, and the next morning sends one.
pub const RemindUnpaid = struct {
    billing: *Billing,

    pub const scheduler_job: scheduler.Job = .{
        .name = "remind-unpaid",
        .repeat = .dailyAt(9, 0, 0, .am),
        .misfire = .{ .skip = .fromSeconds(60 * 60) },
    };

    pub fn run(self: *RemindUnpaid, ctx: *scheduler.Context) !void {
        try self.billing.remindUnpaid(ctx.io());
    }
};
