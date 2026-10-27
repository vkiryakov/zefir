//! Jobs by key: one job for each order and for each tenant, which the shop
//! finds, moves, pauses and cancels by its key. An order gets a reminder
//! to pay three days later, and each tenant a report every Monday at 9 AM.
//! Only the client works here, on `scheduler.MemoryStore`: no worker runs
//! the jobs, so the program shows what the store keeps of them. `zig build
//! test-scheduler` runs it.

const std = @import("std");
const log = @import("log");
const scheduler = @import("scheduler");

/// The store logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// A reminder to pay an order. No worker runs it in this program.
const RemindToPay = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "remind-to-pay" };

    pub const Payload = struct { order_id: u64, amount_cents: u64 };

    pub fn run(_: *RemindToPay, _: *scheduler.Context, _: Payload) !void {}
};

/// The weekly report of a tenant: a repeating job, one for each tenant,
/// with the tenant as its key.
const WeeklyReport = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "weekly-report" };

    pub fn run(_: *WeeklyReport, _: *scheduler.Context) !void {}
};

const days: i64 = 24 * 60 * 60;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    var memory: scheduler.MemoryStore = .init(gpa, io, .{});
    defer memory.deinit();
    const client: scheduler.Client = .init(gpa, io, memory.store(), .{});

    // Three orders of two tenants: a reminder for each, three days on, by
    // the key of the order.
    for ([_]struct { []const u8, u64, []const u8 }{
        .{ "order-41", 41, "acme" },
        .{ "order-42", 42, "acme" },
        .{ "order-43", 43, "globex" },
    }) |order| {
        const key, const id, const tenant = order;
        const result = try client.schedule(io, .root, RemindToPay, .{
            .key = key,
            .when = .{ .after = .fromSeconds(3 * days) },
            .payload = .{ .order_id = id, .amount_cents = 1000 + id },
            .tenant = tenant,
        }, .{});
        app.info("Scheduled", .{ .key = key, .tenant = tenant, .result = result });
    }
    // The same request again, as a retry of the call that made it: the
    // key is taken, so nothing changes.
    const again = try client.schedule(io, .root, RemindToPay, .{
        .key = "order-42",
        .when = .{ .after = .fromSeconds(3 * days) },
        .payload = .{ .order_id = 42, .amount_cents = 1042 },
        .tenant = "acme",
    }, .{});
    app.info("Scheduled", .{ .key = "order-42", .result = again });

    // Order 41 is paid: no reminder. A second cancel finds nothing.
    for (0..2) |_| app.info("Cancelled", .{ .key = "order-41", .found = try client.cancel(io, .root, .of(RemindToPay, "order-41"), .{}) });
    // The customer of order 43 pays on payday: the reminder moves to the
    // 1st of December, 9 AM UTC.
    const moved = try client.reschedule(io, .root, .of(RemindToPay, "order-43"), .{ .at = .fromUtc(2026, 12, 1, 9, 0, 0, .am) }, .{});
    app.info("Moved", .{ .key = "order-43", .result = moved });

    // The report of each tenant, every Monday at 9 AM. acme stops its
    // reports for now: its job pauses, and a second pause changes nothing.
    for ([_][]const u8{ "acme", "globex" }) |tenant| {
        const result = try client.schedule(io, .root, WeeklyReport, .{ .key = tenant, .when = .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) }, .tenant = tenant }, .{});
        app.info("Scheduled", .{ .key = tenant, .result = result });
    }
    for (0..2) |_| app.info("Paused", .{ .key = "acme", .result = try client.pause(io, .root, .of(WeeklyReport, "acme"), .{}) });

    // Every job, two to a page.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var page: scheduler.Page = .{ .limit = 2 };
    while (true) {
        const jobs = try client.list(io, .root, .{}, page, arena, .{});
        for (jobs.records) |r| app.info("Job", .{ .job = r.job, .key = r.key, .tenant = r.tenant, .state = r.state, .plan = r.plan, .run_at = r.run_at });
        page.after = jobs.next orelse break;
    }
    // The jobs of one tenant, and the paused ones.
    const of_acme = try client.list(io, .root, .{ .tenant = "acme" }, .{}, arena, .{});
    const paused = try client.list(io, .root, .{ .state = .paused }, .{}, arena, .{});
    app.info("Listed", .{ .tenant_acme = of_acme.records.len, .paused = paused.records.len });

    // One job by its key, and its payload as the type of the job's.
    const record = (try client.get(io, .root, .of(RemindToPay, "order-42"), arena, .{})) orelse return error.NoReminder;
    const payload = try record.payloadAs(RemindToPay, arena);
    app.info("Found", .{ .key = record.key, .order = payload.order_id, .amount_cents = payload.amount_cents, .attempt = record.attempt });

    // A request that breaks a rule fails before it reaches the store, and
    // the diagnostics say which rule.
    var d: scheduler.Diagnostics = .{};
    if (client.schedule(io, .root, RemindToPay, .{
        .key = "",
        .when = .{ .after = .fromSeconds(3 * days) },
        .payload = .{ .order_id = 44, .amount_cents = 1044 },
    }, .{ .diagnostics = &d })) |_| {
        return error.EmptyKeyTaken;
    } else |err| app.warn("Not scheduled", .{ .reason = err, .details = d.message() });
}
