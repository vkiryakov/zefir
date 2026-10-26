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
const Check = conformance.Check;
const Setup = conformance.Setup;
const Record = model.Record;

const Runner = @This();

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

/// The first rule of the record model that `rec` breaks, or null: a
/// running record and only it has an owner, `claimed_at` and
/// `lease_until`; a pending or paused one and only it has a `run_at`; a
/// finished one and only it has a `finished_at`, and an `expires_at` if
/// any; a record never claimed (fence 0) waits.
pub fn shape(rec: Record) ?[]const u8 {
    const claim = [_]bool{ rec.owner != null, rec.claimed_at != null, rec.lease_until != null };
    const running = rec.state == .running;
    for (claim) |has| {
        if (has != running) return "a running record without an owner, claimed_at or lease_until, or another one with one";
    }
    const waits = rec.state == .pending or rec.state == .paused;
    if (waits != (rec.run_at != null)) return "a run_at on a record that does not wait, or none on one that does";
    const finished = rec.state == .succeeded or rec.state == .failed;
    if (finished != (rec.finished_at != null)) return "a finished_at on a record that is not finished, or none on one that is";
    if (!finished and rec.expires_at != null) return "an expires_at on a record that is not finished";
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
    if (bodyOf(check) == null) return "not written yet";
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
        .body = bodyOf(check).?,
        .rng = .init(@backingInt(check) + 1),
    };
    var done: Io.Event = .unset;
    var task = io.concurrent(go, .{ &r, &done }) catch return .{ .failed = no_concurrency };
    const hung = !awaitDone(io, &done, limit);
    if (hung) {
        // Said at once: a task that ignores its cancelation would keep the
        // report from ever coming.
        std.debug.print("scheduler conformance: {s} still runs after {f}: it hangs, and its task is canceled\n", .{ check.label(), limit });
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

fn bodyOf(check: Check) ?Body {
    return switch (check) {
        .s3 => records.s3,
        else => null,
    };
}
