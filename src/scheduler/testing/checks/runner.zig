//! One check of `scheduler.testing.conformance` on its way: what it may
//! use, the helpers that the checks share, the invariants of a record that
//! any caller of a store can see, and what the check found. Also the run of
//! the checks, each on a fresh setup in a task of its own with its time
//! limit, the harness behind its table, and the allocator that counts what
//! a check holds.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const conformance = @import("../conformance.zig");
const Diagnostics = @import("../../Diagnostics.zig");
const Instant = @import("../../Instant.zig");
const Store = @import("../../Store.zig");
const model = @import("../../record.zig");
const Op = @import("../FaultyStore.zig").Op;
const records = @import("records.zig");
const claims = @import("claims.zig");
const outcomes = @import("outcomes.zig");
const Check = conformance.Check;
const Setup = conformance.Setup;
const Record = model.Record;
const Ref = model.Ref;

const Runner = @This();

const log = std.log.scoped(.scheduler);

io: Io,
/// Counts what the check holds: the harness gets it in `setUp`.
gpa: Allocator,
/// The report's arena: the messages. The check's task only.
arena: Allocator,
harness: Harness,
options: conformance.Options,
check: Check,
body: Body,
/// What `setUp` gave, during the check.
setup: Setup = undefined,
/// Memory for results, over `gpa`, freed before `tearDown`. The check's
/// task only.
scratch: Allocator = undefined,
/// The diagnostics of the latest call of the check's task.
diag: Diagnostics = .{},
/// Cancelled, for the contexts of S16.
token: core.CancellationToken = .init,
/// The lives and tags of the check.
rng: std.Random.DefaultPrng,
store_name: []const u8 = "",
failure: ?[]const u8 = null,
skipped: ?[]const u8 = null,

pub const Error = error{ CheckFailed, CheckSkipped, OutOfMemory };

/// What a check does, in its task.
pub const Body = *const fn (r: *Runner) Error!void;

fn go(r: *Runner, done: *Io.Event) void {
    defer done.set(r.io);
    r.runBody() catch |err| switch (err) {
        error.CheckFailed, error.CheckSkipped => {},
        error.OutOfMemory => if (r.failure == null) {
            r.failure = "out of memory";
        },
    };
}

fn runBody(r: *Runner) Error!void {
    const setup = r.harness.set_up(r.harness.ptr, r.io, r.gpa) catch |err|
        return r.fail("harness.setUp returned error.{t}", .{err});
    defer r.harness.tear_down(r.harness.ptr, r.io, setup);
    r.setup = setup;
    // A name of the store's table: constant, it outlives the setup.
    r.store_name = setup.store.vtable.name;
    var scratch: std.heap.ArenaAllocator = .init(r.gpa);
    defer scratch.deinit();
    r.scratch = scratch.allocator();
    r.token.cancel();
    return r.body(r);
}

/// `n` milliseconds, stretched by `Options.time_scale`.
pub fn ms(r: *const Runner, n: i64) Io.Duration {
    return .fromMilliseconds(n * @as(i64, @max(r.options.time_scale, 1)));
}

/// How far a time the store writes may be from what its `now` said
/// around the call: 1 s, stretched.
pub fn slack(r: *const Runner) Io.Duration {
    return r.ms(1000);
}

/// The context of a call that should go through: 10 s, stretched.
pub fn ctx(r: *const Runner) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(r.io), r.ms(10_000)));
}

/// A context with less than 1 ms left.
pub fn nearlyExpired(r: *const Runner) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(r.io), .fromMicroseconds(500)));
}

/// A context whose token is cancelled.
pub fn cancelled(r: *const Runner) core.Context {
    return core.Context.root.withCancellation(&r.token);
}

pub fn fail(r: *Runner, comptime fmt: []const u8, args: anytype) Error {
    r.failure = try std.fmt.allocPrint(r.arena, fmt, args);
    return error.CheckFailed;
}

pub fn expect(r: *Runner, holds: bool, comptime fmt: []const u8, args: anytype) Error!void {
    if (!holds) return r.fail(fmt, args);
}

pub fn skip(r: *Runner, why: []const u8) Error {
    r.skipped = why;
    return error.CheckSkipped;
}

/// The payload of `result`; its error fails the check, with the text of
/// the diagnostics.
pub fn need(r: *Runner, result: anytype, comptime what: []const u8) Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| r.fail(what ++ " returned error.{t}: {s}", .{ err, r.diag.message() });
}

pub fn store(r: *const Runner) Store {
    return r.setup.store;
}

/// The options of a call: the scratch memory and the diagnostics.
pub fn call(r: *Runner) Store.CallOptions {
    return .{ .allocator = r.scratch, .diagnostics = &r.diag };
}

/// The store's clock, as its `now` says.
pub fn now(r: *const Runner) Instant {
    return r.store().now(r.io);
}

/// Sleeps `duration` on the awake clock; a cancel of the check's task, past
/// its time limit, fails the check.
pub fn sleep(r: *Runner, duration: Io.Duration) Error!void {
    const until = Io.Clock.awake.now(r.io).addDuration(duration);
    while (true) {
        const left = Io.Clock.awake.now(r.io).durationTo(until);
        // A sleep of std's Io on Windows may end a tick of its timer early.
        if (left.nanoseconds <= 0) return;
        r.io.sleep(left, .awake) catch return r.fail("the check's task was canceled while it waited", .{});
    }
}

/// Until the store's clock, as its `now` says, is past `at`.
pub fn waitPast(r: *Runner, at: Instant) Error!void {
    while (true) {
        const left = at.unix_ms -| r.now().unix_ms;
        if (left < 0) return;
        try r.sleep(.fromMilliseconds(@min(left +| 1, 100)));
    }
}

pub fn newLife(r: *Runner) model.Life {
    var life: model.Life = undefined;
    r.rng.random().bytes(&life);
    return life;
}

pub fn newTag(r: *Runner) Store.Tag {
    var tag: Store.Tag = undefined;
    r.rng.random().bytes(&tag);
    return tag;
}

/// A one-shot record of `job` and `key` with the payload `{}` and a life of
/// its own; what create answered.
pub fn create(r: *Runner, job: []const u8, key: []const u8, run_at: Store.Moment) Error!Store.CreateResult {
    const request: Store.CreateRequest = .{ .job = job, .key = key, .life = r.newLife(), .plan = "", .payload = "{}", .run_at = run_at };
    return r.need(r.store().create(r.io, r.ctx(), &request, r.call()), "create");
}

/// The record of `job` and `key`, or null.
pub fn get(r: *Runner, job: []const u8, key: []const u8) Error!?Record {
    const found = try r.need(r.store().get(r.io, r.ctx(), &.{ .job = job, .key = key }, r.call()), "get");
    if (found) |rec| try r.expectShape(rec, "get");
    return found;
}

/// The record of `job` and `key`; none fails the check.
pub fn fetch(r: *Runner, job: []const u8, key: []const u8) Error!Record {
    return (try r.get(job, key)) orelse r.fail("get of {s}/{s} found no record", .{ job, key });
}

pub fn remove(r: *Runner, job: []const u8, key: []const u8) Error!bool {
    return r.need(r.store().remove(r.io, r.ctx(), &.{ .job = job, .key = key }, r.call()), "remove");
}

/// The change `set` of `current`, on its revision and state.
pub fn update(r: *Runner, current: Record, set: Store.Patch) Error!Store.UpdateResult {
    const request: Store.UpdateRequest = .{ .ref = refOf(current), .expect = .{ .revision = current.revision, .state = current.state }, .set = set, .tag = r.newTag() };
    return r.need(r.store().update(r.io, r.ctx(), &request, r.call()), "update");
}

/// `update` that must apply, a revision one more; the record after it.
pub fn updated(r: *Runner, current: Record, set: Store.Patch) Error!Record {
    switch (try r.update(current, set)) {
        .updated => |revision| try r.expect(revision == current.revision +% 1, "update of revision {d} answered revision {d}", .{ current.revision, revision }),
        .conflict => |now_| return r.fail("update of {s}/{s} on its revision and state answered conflict, with revision {d} and state {t}", .{ current.job, current.key, now_.revision, now_.state }),
        .not_found => return r.fail("update of {s}/{s} answered not_found", .{ current.job, current.key }),
    }
    return r.fetch(current.job, current.key);
}

/// A claim with a tag of its own; each record it gives must be running, of
/// `owner` and of the record model.
pub fn claim(r: *Runner, owner: []const u8, any_key: []const []const u8, keyed_only: []const []const u8, max: u32, lease: Io.Duration) Error!Store.ClaimResult {
    const request: Store.ClaimRequest = .{ .owner = owner, .any_key = any_key, .keyed_only = keyed_only, .max = max, .lease = lease, .tag = r.newTag() };
    const result = try r.need(r.store().claim(r.io, r.ctx(), &request, r.call()), "claim");
    try r.expect(result.claimed.len <= max, "a claim of at most {d} gave {d} records", .{ max, result.claimed.len });
    for (result.claimed) |c| {
        try r.expectShape(c.record, "claim");
        try r.expect(c.record.state == .running and std.mem.eql(u8, c.record.owner orelse "", owner), "claim gave {s}/{s}, {t} with owner {?s}, not running with its owner", .{ c.record.job, c.record.key, c.record.state, c.record.owner });
    }
    return result;
}

/// A record of `job` and `key`, due now, claimed by `owner` for `lease`;
/// no other record of `job` may be due. The record of the claim.
pub fn running(r: *Runner, job: []const u8, key: []const u8, owner: []const u8, lease: Io.Duration) Error!Record {
    const created = try r.create(job, key, .{ .after = .zero });
    try r.expect(created == .created, "create of {s}/{s} answered {t}, not created", .{ job, key, created });
    const result = try r.claim(owner, &.{job}, &.{}, 1, lease);
    try r.expect(result.claimed.len == 1, "a claim of the due record {s}/{s} took {d} records", .{ job, key, result.claimed.len });
    const rec = result.claimed[0].record;
    try r.expect(std.mem.eql(u8, rec.key, key), "a claim of the due record {s}/{s} took {s}/{s}", .{ job, key, rec.job, rec.key });
    return rec;
}

/// The renew of the claim of `claimed` by `owner`: its life and fence.
pub fn renew(r: *Runner, claimed: Record, owner: []const u8, lease: Io.Duration) Error!Store.RenewResult {
    const request: Store.RenewRequest = .{ .ref = refOf(claimed), .life = claimed.life, .owner = owner, .fence = claimed.fence, .lease = lease };
    return r.need(r.store().renew(r.io, r.ctx(), &request, r.call()), "renew");
}

/// Waits until the lease of `held` expired by the store's clock, then
/// claims records of its job for `owner` until one is taken, 10 s at most:
/// the claim, which must be of `held`'s record.
pub fn takeOver(r: *Runner, owner: []const u8, held: Record, lease: Io.Duration) Error!Store.Claimed {
    try r.waitPast(held.lease_until orelse return r.fail("{s}/{s} was not running", .{ held.job, held.key }));
    const give_up = Io.Clock.awake.now(r.io).addDuration(r.ms(10_000));
    while (true) {
        const result = try r.claim(owner, &.{held.job}, &.{}, 1, lease);
        if (result.claimed.len == 1) {
            const took = result.claimed[0];
            try r.expect(std.mem.eql(u8, took.record.key, held.key) and std.mem.eql(u8, &took.record.life, &held.life), "a claim after the lease of {s}/{s} took {s}/{s}", .{ held.job, held.key, took.record.job, took.record.key });
            return took;
        }
        if (Io.Clock.awake.now(r.io).nanoseconds > give_up.nanoseconds)
            return r.fail("no claim took over {s}/{s} within 10 s after its lease expired", .{ held.job, held.key });
        try r.sleep(r.ms(50));
    }
}

/// The finish of the claim of `claimed` by `owner`, with its life, fence
/// and revision, a tag of its own, `next`, a last run that succeeded and no
/// rows.
pub fn finishOf(r: *Runner, claimed: Record, owner: []const u8, next: Store.Next) Store.FinishRequest {
    return .{
        .ref = refOf(claimed),
        .life = claimed.life,
        .owner = owner,
        .fence = claimed.fence,
        .revision = claimed.revision,
        .tag = r.newTag(),
        .next = next,
        .last = lastOf(claimed, .succeeded, null),
    };
}

pub fn finish(r: *Runner, request: Store.FinishRequest) Error!Store.FinishResult {
    return r.need(r.store().finish(r.io, r.ctx(), &request, r.call()), "finish");
}

/// `finish` that must answer done.
pub fn finished(r: *Runner, request: Store.FinishRequest) Error!void {
    const result = try r.finish(request);
    try r.expect(result == .done, "finish of {s}/{s} answered {t}, not done", .{ request.ref.job, request.ref.key, result });
}

pub fn refOf(rec: Record) Ref {
    return .{ .job = rec.job, .key = rec.key };
}

/// What a record shows of the run of the claim of `claimed`.
pub fn lastOf(claimed: Record, outcome: model.RunOutcome, error_name: ?[]const u8) model.LastRun {
    const started = claimed.claimed_at orelse Instant.fromUnixMs(0);
    return .{ .outcome = outcome, .error_name = error_name, .attempt = claimed.attempt, .started_at = started, .finished_at = started };
}

/// The row of the history of the claim of `claimed`.
pub fn rowOf(claimed: Record, outcome: model.RunOutcome, error_name: ?[]const u8, instance: []const u8) model.Run {
    const started = claimed.claimed_at orelse Instant.fromUnixMs(0);
    return .{
        .job = claimed.job,
        .key = claimed.key,
        .tenant = claimed.tenant,
        .life = claimed.life,
        .fence = claimed.fence,
        .attempt = claimed.attempt,
        .scheduled_at = claimed.scheduled_at,
        .started_at = started,
        .finished_at = started,
        .outcome = outcome,
        .error_name = error_name,
        .instance = instance,
        .expires_at = null,
    };
}

/// Fails unless `got` is `after` past the store's now during a call that
/// came between its `t0` and `t1`, within the slack.
pub fn expectNear(r: *Runner, got: ?Instant, t0: Instant, t1: Instant, after: Io.Duration, comptime what: []const u8) Error!void {
    const at = got orelse return r.fail(what ++ " is null", .{});
    const low = t0.add(after).add(.fromNanoseconds(-r.slack().nanoseconds));
    const high = t1.add(after).add(r.slack());
    try r.expect(at.unix_ms >= low.unix_ms and at.unix_ms <= high.unix_ms, what ++ " is {f}, not within {f} … {f}", .{ at, low, high });
}

/// The first field, but those in `except`, in which `a` and `b` differ;
/// null when they are the same, byte for byte.
pub fn difference(a: Record, b: Record, comptime except: []const []const u8) ?[]const u8 {
    inline for (@typeInfo(Record).@"struct".field_names) |field| {
        const skipped = comptime for (except) |name| {
            if (std.mem.eql(u8, name, field)) break true;
        } else false;
        if (!skipped and !same(@field(a, field), @field(b, field))) return field;
    }
    return null;
}

fn same(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .optional => {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return same(x, y);
        },
        .pointer => return std.mem.eql(u8, a, b),
        .array => return std.mem.eql(u8, &a, &b),
        .@"struct" => |info| {
            inline for (info.field_names) |field| {
                if (!same(@field(a, field), @field(b, field))) return false;
            }
            return true;
        },
        else => return a == b,
    }
}

/// Fails if `now_` differs from `before` in a field but those of `except`.
pub fn expectSame(r: *Runner, before: Record, now_: Record, comptime except: []const []const u8, comptime what: []const u8) Error!void {
    if (difference(before, now_, except)) |field| return r.fail(what ++ " changed {s} of {s}/{s}", .{ field, before.job, before.key });
}

/// Every record of `filter`, `limit` a page: each (job, key) once, each of
/// the record model and of the filter, the records of a job together and in
/// the order of their keys. The order of the jobs is the store's.
pub fn listAll(r: *Runner, filter: model.ListFilter, limit: u32) Error![]const Record {
    var all: std.ArrayList(Record) = .empty;
    var after: ?[]const u8 = null;
    for (0..100_000) |_| {
        const page = try r.need(r.store().list(r.io, r.ctx(), &.{ .filter = filter, .page = .{ .after = after, .limit = limit } }, r.call()), "list");
        try r.expect(page.records.len <= limit, "list gave a page of {d} records, past its limit of {d}", .{ page.records.len, limit });
        for (page.records) |rec| {
            try r.expectShape(rec, "list");
            try r.expect(listed(filter, rec), "list gave {s}/{s}, {t}, of tenant {?s}, which its filter does not take", .{ rec.job, rec.key, rec.state, rec.tenant });
            if (all.items.len > 0) {
                const before = all.items[all.items.len - 1];
                if (std.mem.eql(u8, before.job, rec.job)) {
                    try r.expect(std.mem.order(u8, before.key, rec.key) == .lt, "list gave {s}/{s} after {s}/{s}: keys not in order, or twice", .{ rec.job, rec.key, before.job, before.key });
                } else for (all.items) |seen| {
                    try r.expect(!std.mem.eql(u8, seen.job, rec.job), "list gave records of {s} apart, around those of {s}", .{ rec.job, before.job });
                }
            }
            try all.append(r.scratch, rec);
        }
        after = page.next orelse return all.items;
    }
    return r.fail("list gave a next page 100000 times", .{});
}

fn listed(filter: model.ListFilter, rec: Record) bool {
    if (filter.job) |job| if (!std.mem.eql(u8, job, rec.job)) return false;
    if (filter.state) |state| if (state != rec.state) return false;
    if (filter.tenant) |tenant| if (!std.mem.eql(u8, tenant, rec.tenant orelse return false)) return false;
    return true;
}

/// Every row of `filter`, `limit` a page: each of the filter, the only one
/// of its (life, fence), the newest first.
pub fn historyAll(r: *Runner, filter: model.HistoryFilter, limit: u32) Error![]const model.Run {
    const Claim = struct { life: model.Life, fence: u64 };
    var seen: std.AutoHashMapUnmanaged(Claim, void) = .empty;
    var all: std.ArrayList(model.Run) = .empty;
    var after: ?[]const u8 = null;
    for (0..100_000) |_| {
        const page = try r.need(r.store().history(r.io, r.ctx(), &.{ .filter = filter, .page = .{ .after = after, .limit = limit } }, r.call()), "history");
        try r.expect(page.runs.len <= limit, "history gave a page of {d} rows, past its limit of {d}", .{ page.runs.len, limit });
        for (page.runs) |run| {
            try r.expect(inHistory(filter, run), "history gave a row of {s}/{s}, {t}, of tenant {?s}, which its filter does not take", .{ run.job, run.key, run.outcome, run.tenant });
            const entry = try seen.getOrPut(r.scratch, .{ .life = run.life, .fence = run.fence });
            try r.expect(!entry.found_existing, "history gave two rows of one claim, fence {d} of {s}/{s}", .{ run.fence, run.job, run.key });
            if (all.items.len > 0) {
                const newer = all.items[all.items.len - 1].finished_at;
                try r.expect(run.finished_at.unix_ms <= newer.unix_ms, "history gave a row finished at {f} after one finished at {f}: not the newest first", .{ run.finished_at, newer });
            }
            try all.append(r.scratch, run);
        }
        after = page.next orelse return all.items;
    }
    return r.fail("history gave a next page 100000 times", .{});
}

fn inHistory(filter: model.HistoryFilter, run: model.Run) bool {
    if (filter.job) |job| if (!std.mem.eql(u8, job, run.job)) return false;
    if (filter.key) |key| if (!std.mem.eql(u8, key, run.key)) return false;
    if (filter.outcome) |outcome| if (outcome != run.outcome) return false;
    if (filter.tenant) |tenant| if (!std.mem.eql(u8, tenant, run.tenant orelse return false)) return false;
    return true;
}

/// The first rule of the record model that `rec` breaks, or null: a
/// running record and only it has an owner, `claimed_at` and
/// `lease_until`; a pending or paused one and only it has a `run_at`; a
/// finished one and only it has a `finished_at`, and an `expires_at` if
/// any; a record never claimed (fence 0) waits.
pub fn shape(rec: Record) ?[]const u8 {
    const of_claim = [_]bool{ rec.owner != null, rec.claimed_at != null, rec.lease_until != null };
    for (of_claim) |has| {
        if (has != (rec.state == .running)) return "a running record without an owner, claimed_at or lease_until, or another one with one";
    }
    const waits = rec.state == .pending or rec.state == .paused;
    if (waits != (rec.run_at != null)) return "a run_at on a record that does not wait, or none on one that does";
    const done = rec.state == .succeeded or rec.state == .failed;
    if (done != (rec.finished_at != null)) return "a finished_at on a record that is not finished, or none on one that is";
    if (!done and rec.expires_at != null) return "an expires_at on a record that is not finished";
    if (rec.fence == 0 and !waits) return "a record of fence 0, never claimed, that does not wait";
    return null;
}

/// Fails unless `rec` keeps the record model; `what` gave it.
pub fn expectShape(r: *Runner, rec: Record, comptime what: []const u8) Error!void {
    if (shape(rec)) |problem| return r.fail(what ++ " gave {s}/{s} ({t}): {s}", .{ rec.job, rec.key, rec.state, problem });
}

/// The harness behind a pointer and a table of its methods.
pub const Harness = struct {
    ptr: *anyopaque,
    set_up: *const fn (ptr: *anyopaque, io: Io, gpa: Allocator) anyerror!Setup,
    tear_down: *const fn (ptr: *anyopaque, io: Io, setup: Setup) void,
    lose_next_reply: ?*const fn (ptr: *anyopaque, io: Io, op: Op) anyerror!void,

    const where = "scheduler: testing.conformance.run: ";

    /// A method of a harness: `fn (self: *H, Params…)` returning `Payload`,
    /// or an error union of it when `may_fail`.
    const Hook = struct {
        name: []const u8,
        required: bool,
        Params: []const type,
        Payload: type,
        may_fail: bool,
        signature: []const u8,
    };

    const hooks = [_]Hook{
        .{ .name = "setUp", .required = true, .Params = &.{ Io, Allocator }, .Payload = Setup, .may_fail = true, .signature = "pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator) !scheduler.testing.conformance.Setup" },
        .{ .name = "tearDown", .required = true, .Params = &.{ Io, Setup }, .Payload = void, .may_fail = false, .signature = "pub fn tearDown(self: *@This(), io: std.Io, setup: scheduler.testing.conformance.Setup) void" },
        .{ .name = "loseNextReply", .required = false, .Params = &.{ Io, Op }, .Payload = void, .may_fail = true, .signature = "pub fn loseNextReply(self: *@This(), io: std.Io, op: scheduler.testing.Op) !void" },
    };

    /// The type `Ptr` points to. Stops the build unless it is a pointer to
    /// one mutable struct with `setUp` and `tearDown`, and every method of
    /// a harness it has takes the form the suite calls, with a message that
    /// names what to write.
    fn expectHarness(comptime Ptr: type) type {
        const not_a_pointer = where ++ "pass a pointer to the harness, e.g. &harness; got " ++ @typeName(Ptr);
        const pointer = switch (@typeInfo(Ptr)) {
            .pointer => |pointer| pointer,
            else => @compileError(not_a_pointer),
        };
        if (pointer.size != .one or @typeInfo(pointer.child) != .@"struct") @compileError(not_a_pointer);
        if (pointer.attrs.@"const") @compileError(where ++ "the harness must be mutable, declared with var; got " ++ @typeName(Ptr));
        const H = pointer.child;
        inline for (hooks) |hook| {
            if (@hasDecl(H, hook.name)) {
                if (!hookFits(H, hook))
                    @compileError(where ++ @typeName(H) ++ "." ++ hook.name ++ " has another signature; expected " ++ hook.signature);
            } else if (hook.required) {
                @compileError(where ++ @typeName(H) ++ " has no method " ++ hook.name ++ "; expected " ++ hook.signature);
            }
        }
        return H;
    }

    /// Whether `H` declares `hook` in the form the suite calls.
    fn hookFits(comptime H: type, comptime hook: Hook) bool {
        const function = switch (@typeInfo(@TypeOf(@field(H, hook.name)))) {
            .@"fn" => |function| function,
            else => return false,
        };
        const params = function.param_types;
        if (params.len != hook.Params.len + 1 or params[0] != *H) return false;
        inline for (params[1..], hook.Params) |param, expected| {
            if (param != expected) return false;
        }
        const Return = function.return_type orelse return false;
        if (Return == hook.Payload) return true;
        if (!hook.may_fail) return false;
        return switch (@typeInfo(Return)) {
            .error_union => |error_union| error_union.payload == hook.Payload,
            else => false,
        };
    }

    fn of(harness: anytype) Harness {
        const Ptr = @TypeOf(harness);
        const H = comptime expectHarness(Ptr);
        const gen = struct {
            fn self(ptr: *anyopaque) Ptr {
                return @ptrCast(@alignCast(ptr));
            }
            fn setUp(ptr: *anyopaque, io: Io, gpa: Allocator) anyerror!Setup {
                return self(ptr).setUp(io, gpa);
            }
            fn tearDown(ptr: *anyopaque, io: Io, setup: Setup) void {
                self(ptr).tearDown(io, setup);
            }
            fn loseNextReply(ptr: *anyopaque, io: Io, op: Op) anyerror!void {
                return self(ptr).loseNextReply(io, op);
            }
        };
        return .{
            .ptr = harness,
            .set_up = gen.setUp,
            .tear_down = gen.tearDown,
            .lose_next_reply = if (@hasDecl(H, "loseNextReply")) gen.loseNextReply else null,
        };
    }
};

/// Counts what one check holds of the caller's allocator, so that memory
/// left after `tearDown` shows as a leak of that check.
const Counting = struct {
    parent: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        const memory = c.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = c.live.fetchAdd(1, .monotonic);
        _ = c.bytes.fetchAdd(len, .monotonic);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        if (!c.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.moved(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        const moved_to = c.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.moved(memory.len, new_len);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        c.parent.rawFree(memory, alignment, ret_addr);
        _ = c.live.fetchSub(1, .monotonic);
        _ = c.bytes.fetchSub(memory.len, .monotonic);
    }

    fn moved(c: *Counting, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            _ = c.bytes.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = c.bytes.fetchSub(old_len - new_len, .monotonic);
        }
    }
};

/// The allocator of one call, for S19: it knows the blocks it gave, and
/// counts what the store does with it once the call has returned. Its
/// memory is an arena over the check's allocator, freed by `deinit`.
pub const Fence = struct {
    arena: std.heap.ArenaAllocator,
    closed: std.atomic.Value(bool) = .init(false),
    late: std.atomic.Value(u32) = .init(0),
    blocks: [256][]u8 = undefined,
    held: usize = 0,

    pub fn init(parent: Allocator) Fence {
        return .{ .arena = .init(parent) };
    }

    pub fn deinit(f: *Fence) void {
        f.arena.deinit();
    }

    pub fn allocator(f: *Fence) Allocator {
        return .{ .ptr = f, .vtable = &fence_vtable };
    }

    /// The call returned: any use from now on is late. Its blocks are
    /// overwritten, so a store that kept a slice of its result reads 0xAA.
    pub fn close(f: *Fence) void {
        for (f.blocks[0..f.held]) |block| @memset(block, 0xAA);
        f.closed.store(true, .release);
    }

    /// How many times the store used the allocator after the call.
    pub fn lateUses(f: *const Fence) u32 {
        return f.late.load(.acquire);
    }

    /// Whether `bytes` lie in a block that the call took and did not free;
    /// an empty slice may lie anywhere.
    pub fn owns(f: *const Fence, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        const start = @intFromPtr(bytes.ptr);
        for (f.blocks[0..f.held]) |block| {
            const from = @intFromPtr(block.ptr);
            if (start >= from and start + bytes.len <= from + block.len) return true;
        }
        return false;
    }

    const fence_vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Counts a use after the call; true when it is one.
    fn touch(f: *Fence) bool {
        if (!f.closed.load(.acquire)) return false;
        _ = f.late.fetchAdd(1, .monotonic);
        return true;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        // A late use is counted, and gets nothing: the arena is the call's.
        if (f.touch()) return null;
        const memory = f.arena.allocator().rawAlloc(len, alignment, ret_addr) orelse return null;
        f.remember(memory[0..len]);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return false;
        if (!f.arena.allocator().rawResize(memory, alignment, new_len, ret_addr)) return false;
        f.forget(memory);
        f.remember(memory.ptr[0..new_len]);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return null;
        const moved_to = f.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        f.forget(memory);
        f.remember(moved_to[0..new_len]);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return;
        f.forget(memory);
        f.arena.allocator().rawFree(memory, alignment, ret_addr);
    }

    /// Past 256 blocks held at once, `owns` does not know the rest.
    fn remember(f: *Fence, block: []u8) void {
        if (f.held == f.blocks.len) return;
        f.blocks[f.held] = block;
        f.held += 1;
    }

    fn forget(f: *Fence, memory: []u8) void {
        for (f.blocks[0..f.held], 0..) |block, i| {
            if (block.ptr == memory.ptr) {
                f.blocks[i] = f.blocks[f.held - 1];
                f.held -= 1;
                return;
            }
        }
    }
};

/// `conformance.run` with the time limit of a check given: the suite's
/// own tests take a short one.
pub fn runLimited(io: Io, gpa: Allocator, harness: anytype, options: conformance.Options, limit: Io.Duration) conformance.RunError!conformance.Report {
    const h: Harness = .of(harness);
    // A Debug allocator may take a cancelable lock: blocked, the work of
    // `run` cannot swallow a cancelation of the caller, which it checks
    // between the checks.
    const outer = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(outer);

    var report: conformance.Report = .{ .arena = .init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();
    for (std.enums.values(Check)) |check| {
        try checkpoint(io, outer);
        const result: conformance.Outcome = if (!selected(options, check))
            .{ .skipped = "not in options.only" }
        else if (skipReason(check, h)) |why|
            .{ .skipped = why }
        else
            try runCheck(io, gpa, arena, h, options, check, limit, &report.store_name);
        report.outcomes.set(check, result);
    }
    return report;
}

/// A cancelation point of the caller between two checks.
fn checkpoint(io: Io, outer: Io.CancelProtection) error{Canceled}!void {
    _ = io.swapCancelProtection(outer);
    defer _ = io.swapCancelProtection(.blocked);
    return io.checkCancel();
}

fn selected(options: conformance.Options, check: Check) bool {
    const only = options.only orelse return true;
    return std.mem.findScalar(Check, only, check) != null;
}

/// Why `check` cannot run with this harness.
fn skipReason(check: Check, h: Harness) ?[]const u8 {
    return switch (check) {
        .s17 => if (h.lose_next_reply == null) "the harness has no loseNextReply" else null,
        else => null,
    };
}

const no_concurrency = "no task for the check: io.concurrent returned error.ConcurrencyUnavailable; the suite needs an std.Io with concurrency";

/// Runs one check in a task of its own, on a setup whose allocator counts
/// what the check holds; writes the store's name into `store_name` once.
fn runCheck(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    h: Harness,
    options: conformance.Options,
    check: Check,
    limit: Io.Duration,
    store_name: *[]const u8,
) error{OutOfMemory}!conformance.Outcome {
    var counting: Counting = .{ .parent = gpa };
    var r: Runner = .{
        .io = io,
        .gpa = counting.allocator(),
        .arena = arena,
        .harness = h,
        .options = options,
        .check = check,
        .body = bodyOf(check),
        .rng = .init(@backingInt(check) + 1),
    };
    var done: Io.Event = .unset;
    var task = io.concurrent(go, .{ &r, &done }) catch return .{ .failed = no_concurrency };
    const hung = !awaitDone(io, &done, limit);
    if (hung) {
        // Said at once: a task that ignores its cancelation would keep the
        // report from ever coming.
        log.warn("conformance: {s} still runs after {f}: it hangs, and its task is canceled", .{ check.label(), limit });
        task.cancel(io);
    } else task.await(io);
    if (store_name.len == 0 and r.store_name.len > 0) store_name.* = try arena.dupe(u8, r.store_name);
    var why = r.failure;
    if (hung) {
        const late = try std.fmt.allocPrint(arena, "it did not end in {f}, and its task was canceled", .{limit});
        why = if (why) |then| try std.fmt.allocPrint(arena, "{s}; then: {s}", .{ late, then }) else late;
    }
    const leaked = counting.live.load(.acquire);
    if (leaked > 0) {
        const leak = try std.fmt.allocPrint(arena, "{d} bytes in {d} allocation(s) were still held after harness.tearDown", .{ counting.bytes.load(.acquire), leaked });
        return .{ .failed = if (why) |failure| try std.fmt.allocPrint(arena, "{s}; {s}", .{ failure, leak }) else leak };
    }
    if (why) |failure| return .{ .failed = failure };
    if (r.skipped) |reason| return .{ .skipped = reason };
    return .passed;
}

/// Waits until `done` is set, for `limit` at most; whether it was set.
fn awaitDone(io: Io, done: *Io.Event, limit: Io.Duration) bool {
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = limit, .clock = .awake });
    while (!done.isSet()) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
        // A wakeup before the deadline that finds `done` unset comes back
        // here.
        done.waitTimeout(io, .{ .deadline = deadline }) catch {};
    }
    return true;
}

fn bodyOf(check: Check) Body {
    return switch (check) {
        .s1 => records.s1,
        .s2 => records.s2,
        .s3 => records.s3,
        .s4 => records.s4,
        .s5 => records.s5,
        .s6 => claims.s6,
        .s7 => claims.s7,
        .s8 => claims.s8,
        .s9 => claims.s9,
        .s10 => claims.s10,
        .s11 => outcomes.s11,
        .s12 => outcomes.s12,
        .s13 => outcomes.s13,
        .s14 => claims.s14,
        .s15 => claims.s15,
        .s16 => outcomes.s16,
        .s17 => outcomes.s17,
        .s18 => records.s18,
        .s19 => records.s19,
        .s20 => outcomes.s20,
        .s21 => claims.s21,
        .s22 => claims.s22,
    };
}
