//! The records of declared jobs. A job type with `.repeat` has a record of
//! its own, with the key "", which `Worker.start` creates and moves to the
//! plan of the code when the code changed it; after that the record rules
//! its schedule. Only an instance that declares the job claims that
//! record: the names of a worker's jobs split into those it claims with any
//! key and those it claims only with a key, so the record of a declaration
//! that this code does not have stays parked until it is cancelled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Instant = @import("../Instant.zig");
const Schedule = @import("../schedule/Schedule.zig");
const Store = @import("../Store.zig");
const job_type = @import("../Job.zig");
const payload = @import("../payload.zig");
const record = @import("../record.zig");
const signature = @import("../signature.zig");
const policy = @import("policy.zig");

/// The names of the jobs of `Jobs`, a struct of pointers to job types, for
/// a claim: `any_key` has the jobs declared here with `.repeat`, whose
/// records go with any key, the declared one too; `keyed_only` the others,
/// whose records go only with a key that is not "".
pub fn split(comptime Jobs: type) struct { any_key: []const []const u8, keyed_only: []const []const u8 } {
    return comptime names: {
        var any_key: []const []const u8 = &.{};
        var keyed_only: []const []const u8 = &.{};
        for (@typeInfo(Jobs).@"struct".field_types) |Field| {
            const J = @typeInfo(Field).pointer.child;
            job_type.assertJob(J);
            const name: []const []const u8 = &.{J.scheduler_job.name};
            if (J.scheduler_job.repeat != null) any_key = any_key ++ name else keyed_only = keyed_only ++ name;
        }
        break :names .{ .any_key = any_key, .keyed_only = keyed_only };
    };
}

/// The record that the declared job `J` wants: the key "", the canonical
/// text of its `.repeat`, the JSON of `Payload{}` ("{}" for a job without
/// `Payload`), and its first run after `now`, the store's clock as the
/// process knows it (`fixedDelay`: its delay after the store takes the
/// record). The plan and the payload are in `arena`.
/// error.InvalidArgument: a string of `Payload{}` that is not UTF-8, or no
/// run within the search of the schedule.
pub fn wanted(comptime J: type, arena: Allocator, now: Instant, life: record.Life) error{ OutOfMemory, InvalidArgument }!Store.CreateRequest {
    const s: Schedule = comptime J.scheduler_job.repeat orelse
        @compileError("scheduler: " ++ signature.shortName(J) ++ " has no .repeat, so no declared record");
    const value: job_type.PayloadOf(J) = if (comptime job_type.hasPayload(J)) .{} else {};
    if (!payload.validUtf8(value)) return error.InvalidArgument;
    return .{
        .job = J.scheduler_job.name,
        .key = "",
        .life = life,
        .plan = try std.fmt.allocPrint(arena, "{f}", .{s}),
        .payload = try payload.encode(J, arena, value),
        .run_at = policy.nextRun(s, now) orelse return error.InvalidArgument,
    };
}

/// What `Worker.start` does with the live record of a declared job that it
/// found (pending, running or paused): nothing when its plan is the code's,
/// else the patch to the code's plan. A waiting record moves to `first`,
/// the first run of that plan as `wanted` gives it; a running one gets
/// only the plan, and its next moment comes from it when the run ends.
pub fn reconcile(found: *const record.Record, plan: []const u8, first: Store.Moment) ?Store.Patch {
    if (std.mem.eql(u8, found.plan, plan)) return null;
    if (found.state == .running) return .{ .plan = plan };
    return .{ .plan = plan, .run_at = first };
}
