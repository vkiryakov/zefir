//! What build.zig compiles for the compile checks of zefir-scheduler,
//! read by `addSchedulerCompileChecks`. Paths are relative to the
//! repository root and stay inside `src/`, the part of the package that
//! `build.zig.zon` ships, since a client's build runs zefir's build.zig
//! too. Each file is application code: a `test` block that imports
//! "scheduler" and makes a call that the compiler must refuse.

/// A file that must fail to compile with an error whose message is
/// `expect`: the whole text after `error: ` to the end of the line.
pub const Fixture = struct { file: []const u8, expect: []const u8 };

/// Files in src/scheduler/tests/compile_errors/.
pub const compile_errors = [_]Fixture{
    // Schedules: the hour on each clock, the minute, the second, the day of
    // monthlyOn, a step.
    .{ .file = dir ++ "daily_pm_13.zig", .expect = "scheduler: dailyAt(13, 0, 0, .pm): " ++ twelve ++ "1 PM is .dailyAt(1, 0, 0, .pm), or .dailyAt(13, 0, 0, .h24)" },
    .{ .file = dir ++ "daily_am_15.zig", .expect = "scheduler: dailyAt(15, 30, 0, .am): " ++ twelve ++ "3:30 PM is .dailyAt(3, 30, 0, .pm), or .dailyAt(15, 30, 0, .h24)" },
    .{ .file = dir ++ "daily_am_0.zig", .expect = "scheduler: dailyAt(0, 0, 0, .am): " ++ twelve ++ "midnight is .dailyAt(12, 0, 0, .am), or .dailyAt(0, 0, 0, .h24)" },
    .{ .file = dir ++ "daily_h24_24.zig", .expect = "scheduler: dailyAt(24, 0, 0, .h24): an hour of the 24-hour clock is 0–23" },
    .{ .file = dir ++ "weekly_minute_60.zig", .expect = "scheduler: weeklyOn(.monday, 9, 60, 0, .am): a minute is 0–59" },
    .{ .file = dir ++ "daily_second_60.zig", .expect = "scheduler: dailyAt(9, 0, 60, .am): a second is 0–59" },
    .{ .file = dir ++ "monthly_29.zig", .expect = "scheduler: monthlyOn(29, 0, 0, 0, .h24): " ++ every_month ++
        "the 29th of the months that have one is .cron(\"0 0 0 29 * *\"); the last day of a month is not in v1" },
    .{ .file = dir ++ "monthly_31.zig", .expect = "scheduler: monthlyOn(31, 0, 0, 0, .h24): " ++ every_month ++
        "the 31st of the months that have one is .cron(\"0 0 0 31 * *\"); the last day of a month is not in v1" },
    .{ .file = dir ++ "every_minutes_0.zig", .expect = "scheduler: everyMinutes(0): n is 1 or more" },
    .{ .file = dir ++ "every_hours_fraction.zig", .expect = "scheduler: everyHours: n is an integer, not comptime_float" },
    // Cron literals.
    .{ .file = dir ++ "cron_february_30.zig", .expect = "scheduler: cron \"0 0 30 2 *\": day 30 never comes in February, and the day of the week is *" },
    .{ .file = dir ++ "cron_reboot.zig", .expect = "scheduler: cron \"@reboot\": @reboot is not in v1" },
    .{ .file = dir ++ "cron_last.zig", .expect = "scheduler: cron \"0 0 L * *\": field 3, the day of the month, \"L\": L is not in v1" },
    .{ .file = dir ++ "cron_backwards.zig", .expect = "scheduler: cron \"0 0 * * SAT-SUN\": field 5, the day of the week, \"SAT-SUN\": a range goes up, and Sunday is 7 too: write SAT-7" },
    // Decl literals through an optional field of a declaration and through
    // a union built at run time.
    .{ .file = dir ++ "declared_cron.zig", .expect = "scheduler: cron \"0 0 31 4,6,9,11 *\": day 31 never comes in April, June, September or November, " ++
        "and the day of the week is *" },
    .{ .file = dir ++ "when_at_run_time.zig", .expect = "scheduler: weeklyOn(.friday, 5, 0, 60, .pm): a second is 0–59" },
    // Moments.
    .{ .file = dir ++ "from_utc_february_29.zig", .expect = "scheduler: fromUtc(2026, 2, 29, 0, 0, 0, .h24): 2026-02-29 is not a date" },
    // Store.init; stores.zig is not a fixture, but the methods they share.
    .{ .file = dir ++ "store_by_value.zig", .expect = "scheduler: Store.init: pass a pointer to the store, e.g. &store; got BadStore" },
    .{ .file = dir ++ "store_no_name.zig", .expect = "scheduler: Store.init: BadStore has no pub const name: []const u8" },
    .{ .file = dir ++ "store_no_claim.zig", .expect = "scheduler: Store.init: BadStore has no method claim; expected pub fn claim(self: *BadStore, io: std.Io, " ++
        "ctx: core.Context, request: *const scheduler.Store.ClaimRequest, options: scheduler.Store.CallOptions) scheduler.StoreError!scheduler.Store.ClaimResult" },
    .{ .file = dir ++ "store_renew_signature.zig", .expect = "scheduler: Store.init: BadStore.renew has the wrong signature; expected pub fn renew(self: *BadStore, io: std.Io, " ++
        "ctx: core.Context, request: *const scheduler.Store.RenewRequest, options: scheduler.Store.CallOptions) scheduler.StoreError!scheduler.Store.RenewResult" },
    // Job types, reached through Ref.of and Ref.declared: the declaration,
    // the name, run, Payload, and the values of the policy.
    .{ .file = dir ++ "job_no_declaration.zig", .expect = "scheduler: SendInvoiceJob has no scheduler_job: declare pub const scheduler_job: scheduler.Job = .{ .name = \"send-invoice-job\" };" },
    .{ .file = dir ++ "job_declaration_type.zig", .expect = "scheduler: SendInvoiceJob.scheduler_job is a []const u8: " ++ write_job },
    .{ .file = dir ++ "job_declaration_untyped.zig", .expect = "scheduler: SendInvoiceJob.scheduler_job is an anonymous struct: " ++ write_job },
    .{ .file = dir ++ "job_name.zig", .expect = "scheduler: SendInvoiceJob: the name \"Send\": a name is 1–64 bytes of a-z, 0-9, '-', '_' and '.', starting with a letter or a digit" },
    .{ .file = dir ++ "job_run_signature.zig", .expect = "scheduler: SendInvoiceJob: expected pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: SendInvoiceJob.Payload) !void" },
    .{ .file = dir ++ "job_no_run.zig", .expect = "scheduler: NightlyCleanup: expected pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void" },
    .{ .file = dir ++ "job_payload_not_struct.zig", .expect = "scheduler: SendInvoiceJob: Payload is the JSON object of a run: a struct" },
    .{ .file = dir ++ "job_repeat_payload.zig", .expect = "scheduler: NightlyCleanup: the declared record of a repeat gets Payload{}: give every field of Payload a default, or drop .repeat" },
    .{ .file = dir ++ "job_repeat_invalid.zig", .expect = "scheduler: NightlyCleanup: repeat: fixedDelay(0ns): a delay is a whole number of milliseconds, 1 or more" },
    .{ .file = dir ++ "job_retry_attempts.zig", .expect = "scheduler: SendInvoiceJob: retry.attempts is 0: write 1 or more, or null for the default" },
    .{ .file = dir ++ "job_retry_multiplier.zig", .expect = "scheduler: SendInvoiceJob: retry.multiplier is 0: write 1 for a constant pause, or more" },
    .{ .file = dir ++ "job_retry_delay.zig", .expect = "scheduler: SendInvoiceJob: retry.delay must be more than zero" },
    .{ .file = dir ++ "job_retry_max_delay.zig", .expect = "scheduler: SendInvoiceJob: retry.max_delay is less than retry.delay" },
    .{ .file = dir ++ "job_timeout.zig", .expect = "scheduler: SendInvoiceJob: timeout must be more than zero" },
    .{ .file = dir ++ "job_history.zig", .expect = "scheduler: SendInvoiceJob: history.keep_for must be more than zero" },
    .{ .file = dir ++ "job_when_done_succeeded.zig", .expect = "scheduler: SendInvoiceJob: when_done.succeeded.keep_for must be more than zero" },
    .{ .file = dir ++ "job_when_done_failed.zig", .expect = "scheduler: SendInvoiceJob: when_done.failed.keep_for must be more than zero" },
    .{ .file = dir ++ "job_misfire_skip.zig", .expect = "scheduler: NightlyCleanup: misfire.skip must be more than zero" },
    // Worker(Jobs): a field that is no pointer to a job, two jobs of one
    // name.
    .{ .file = dir ++ "jobs_not_pointer.zig", .expect = "scheduler: Worker(Jobs): a field of Jobs points to a job: invoices: *SendInvoiceJob" },
    .{ .file = dir ++ "jobs_same_name.zig", .expect = "scheduler: Worker(Jobs): SendInvoiceJob and Reminder share the name \"send-invoice\"" },
};

const twelve = "an hour of the 12-hour clock is 1–12; ";
const every_month = "a day of monthlyOn is 1–28, which every month has; ";
const write_job = "write pub const scheduler_job: scheduler.Job = .{ … }";

const dir = "src/scheduler/tests/compile_errors/";
