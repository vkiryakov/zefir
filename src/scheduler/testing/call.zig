//! `scheduler.testing.call`: runs the `run` of a job in a test, without a
//! store or a worker.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const job_type = @import("../Job.zig");
const context = @import("../Context.zig");
const run_info = @import("../worker/run_info.zig");

/// Runs `job.run` with a test `Context` and returns what `run` returns.
/// The arena of the run is one of `gpa`, freed when `run` returns; the
/// operation has no deadline, a token nobody cancels and a trace of its
/// own; `ctx.info()` is `info`. A job without `Payload` takes `{}` for
/// `payload`.
///
/// ```zig
/// var invoices: SendInvoice = .{ .billing = &billing };
/// try scheduler.testing.call(io, std.testing.allocator, &invoices, .{ .order_id = 42, .amount_cents = 1999 }, info);
/// ```
pub fn call(io: Io, gpa: Allocator, job: anytype, payload: job_type.PayloadOf(@TypeOf(job.*)), info: context.RunInfo) job_type.RunResult(@TypeOf(job.*)) {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var token: core.CancellationToken = .init;
    var state: context.State = .{ .io = io, .operation = run_info.operation(io, null, null, &token), .arena = arena.allocator(), .info = info };
    if (comptime job_type.hasPayload(@TypeOf(job.*))) return job.run(context.of(&state), payload);
    return job.run(context.of(&state));
}
