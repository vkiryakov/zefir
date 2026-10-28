//! `scheduler.Client`: puts jobs on a time by a key and manages them. It
//! is a value without resources of its own: copy it and share it between
//! tasks; every call comes on the `io` of `init`, and the client is as
//! thread-safe as its store.
//!
//! ```zig
//! const result = try client.schedule(io, ctx, SendInvoice, .{
//!     .key = "order-42",
//!     .when = .{ .after = .fromSeconds(3 * 24 * 60 * 60) },
//!     .payload = .{ .order_id = 42, .amount_cents = 1999 },
//!     .tenant = "acme",
//! }, .{});
//! // Each tenant's report, every Monday at 9 AM.
//! _ = try client.schedule(io, ctx, WeeklyReport, .{ .key = "acme", .when = .{ .repeat = .weeklyOn(.monday, 9, 0, 0, .am) } }, .{});
//! _ = try client.pause(io, ctx, .of(WeeklyReport, "acme"), .{});
//! ```
//!
//! A call checks what it was given before it calls the store, and answers
//! error.InvalidArgument with a text that names the field: `key: …`,
//! `tenant: …`, `payload: …`, `when: …`. No text holds the payload.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = @import("Diagnostics.zig");
const Instant = @import("Instant.zig");
const Store = @import("Store.zig");
const When = @import("root.zig").When;
const job_type = @import("Job.zig");
const payload = @import("payload.zig");
const record = @import("record.zig");
const Error = Store.Error;
const CallOptions = record.CallOptions;

const Client = @This();

gpa: Allocator,
io: Io,
store: Store,
options: Options,

pub const Options = struct {
    /// The largest JSON of a payload; a larger one is
    /// error.InvalidArgument.
    max_payload_bytes: u32 = 64 * 1024,
};

/// Without I/O. `store` outlives the client; `gpa` holds the scratch memory
/// of each call, freed before it returns, and must be thread-safe when
/// tasks share the client.
pub fn init(gpa: Allocator, io: Io, store: Store, options: Options) Client {
    return .{ .gpa = gpa, .io = io, .store = store, .options = options };
}

/// What `schedule` takes for the job `J`: the field `payload` is there
/// only when `J` has a `Payload`, and the compiler checks the literal
/// against it.
pub fn Request(comptime J: type) type {
    job_type.assertJob(J);
    if (job_type.hasPayload(J)) return struct {
        /// 1–256 bytes of UTF-8 without NUL: one job of `J` for each key.
        key: []const u8,
        when: When,
        payload: J.Payload,
        /// 1–128 bytes of UTF-8 without NUL; a field and a filter of
        /// `list` and `history`, not a security boundary.
        tenant: ?[]const u8 = null,
    };
    return struct {
        key: []const u8,
        when: When,
        tenant: ?[]const u8 = null,
    };
}

pub const Scheduled = enum {
    /// No job had the key (or a finished one, kept for its history): it
    /// was created.
    created,
    /// A live job of the key is there; it was not changed.
    existing,
};

/// Puts the job `J` on a time. A job with the key already there answers
/// `.existing` and stays as it is, so a request may be repeated safely;
/// to change a live job, `reschedule` it. The caller's trace goes into the
/// record, and the run goes on with it.
pub fn schedule(c: *const Client, io: Io, ctx: core.Context, comptime J: type, request: Request(J), options: CallOptions) Error!Scheduled {
    const d = options.diagnostics;
    try checkText("key", request.key, 256, d);
    if (request.tenant) |tenant| try checkText("tenant", tenant, 128, d);
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const value = if (comptime job_type.hasPayload(J)) request.payload else {};
    const not_utf8 = "payload: a string in it is not UTF-8, which JSON must be";
    if (!payload.validUtf8(value)) return refuse(d, not_utf8, .{});
    const json = try payload.encode(J, a, value);
    if (json.len > c.options.max_payload_bytes)
        return refuse(d, "payload: its JSON is {d} bytes; at most {d}, as Client.Options.max_payload_bytes says", .{ json.len, c.options.max_payload_bytes });
    // A jsonStringify of the application may write bytes of its own.
    if (!std.unicode.utf8ValidateSlice(json)) return refuse(d, not_utf8, .{});
    const start = try c.startOf(io, a, request.when, d);
    var life: record.Life = undefined;
    io.random(&life);
    var traceparent: [core.w3c.traceparent_len]u8 = undefined;
    const trace: ?[]const u8 = if (ctx.trace) |t| if (t.isValid()) core.w3c.formatTraceparent(t, &traceparent) else null else null;
    const created = try c.store.create(io, ctx, &.{
        .job = J.scheduler_job.name,
        .key = request.key,
        .tenant = request.tenant,
        .life = life,
        .plan = start.plan,
        .payload = json,
        .trace = trace,
        .run_at = start.moment,
    }, .{ .allocator = a, .diagnostics = d });
    return switch (created) {
        .created, .replaced => .created,
        .existing => .existing,
    };
}

pub const Changed = enum {
    changed,
    /// It already was so: a pause of a paused job, an unpause of a pending
    /// one.
    unchanged,
    /// The job finished (its record is kept for its history): the change
    /// does not apply to it. Give a failed job its attempts back with
    /// `retry`, or schedule the key again.
    finished,
    /// No job had the key, or the one the call read was cancelled before
    /// the change: a job scheduled again with the key since is another
    /// one, which the change leaves alone.
    not_found,
};

/// Removes the job in any state. A run of it goes on until its owner
/// renews the lease, within `renew_every`, and then stops. true: the
/// record was there.
pub fn cancel(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, options: CallOptions) Error!bool {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    return c.store.remove(io, ctx, &ref, .{ .allocator = arena.allocator(), .diagnostics = options.diagnostics });
}

/// A pending job pauses; a running one pauses when its run ends, or, when
/// the instance of the run was lost, when another takes it over, without a
/// run, for the same run. When that lost run was its last attempt, the job
/// ends as after a last attempt: a one-shot job is failed, and a repeating
/// one pauses at its next run.
pub fn pause(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, options: CallOptions) Error!Changed {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    return c.change(io, ctx, arena.allocator(), ref, .pause, options.diagnostics);
}

/// The job waits again for the time it had: a time already past runs at
/// once, and a repeating job's missed runs go by its misfire policy.
pub fn unpause(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, options: CallOptions) Error!Changed {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    return c.change(io, ctx, arena.allocator(), ref, .unpause, options.diagnostics);
}

/// A one-shot job moves. For a repeating job `.at` and `.after` move its
/// next run, and `.repeat` changes its schedule; `.repeat` makes a one-shot
/// job a repeating one. `when` is checked as `schedule` checks it. A
/// change during a run wins over the outcome of that run, and over a run
/// whose instance was lost: the instance that takes it over does not run
/// it before the new time.
pub fn reschedule(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, when: When, options: CallOptions) Error!Changed {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const start = try c.startOf(io, arena.allocator(), when, options.diagnostics);
    const plan: ?[]const u8 = if (when == .repeat) start.plan else null;
    return c.change(io, ctx, arena.allocator(), ref, .{ .move = .{ .run_at = start.moment, .plan = plan } }, options.diagnostics);
}

/// A failed job waits again, due at once, with all its attempts and the
/// same run key. A live job is `.unchanged`, a succeeded one `.finished`.
pub fn retry(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, options: CallOptions) Error!Changed {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    return c.change(io, ctx, arena.allocator(), ref, .retry, options.diagnostics);
}

/// The record of `ref`, or null; its strings are in `arena`.
pub fn get(c: *const Client, io: Io, ctx: core.Context, ref: record.Ref, arena: Allocator, options: CallOptions) Error!?record.Record {
    return c.store.get(io, ctx, &ref, .{ .allocator = arena, .diagnostics = options.diagnostics });
}

/// The records of `filter`, a page at a time: those of a job together,
/// their keys in order; which job comes first is the store's choice.
/// Their strings are in `arena`. A record of a job type that no instance
/// knows shows here too.
pub fn list(c: *const Client, io: Io, ctx: core.Context, filter: record.ListFilter, page: record.Page, arena: Allocator, options: CallOptions) Error!record.RecordPage {
    return c.store.list(io, ctx, &.{ .filter = filter, .page = page }, .{ .allocator = arena, .diagnostics = options.diagnostics });
}

/// The rows of the history of `filter`, the newest first, a page at a time;
/// their strings are in `arena`. `.outcome = .abandoned` finds the attempts
/// whose effects are unknown.
pub fn history(c: *const Client, io: Io, ctx: core.Context, filter: record.HistoryFilter, page: record.Page, arena: Allocator, options: CallOptions) Error!record.RunPage {
    return c.store.history(io, ctx, &.{ .filter = filter, .page = page }, .{ .allocator = arena, .diagnostics = options.diagnostics });
}

/// A change of the client, by the state of the record it finds.
const Change = union(enum) {
    pause,
    unpause,
    /// reschedule: the new time, and the plan of `.repeat`.
    move: struct { run_at: Store.Moment, plan: ?[]const u8 },
    retry,

    const Step = union(enum) {
        set: Store.Patch,
        answer: Changed,
    };

    /// The patch of `r`, or the answer when it needs none.
    fn step(what: Change, r: record.Record) Step {
        if (r.state == .succeeded or (r.state == .failed and what != .retry)) return .{ .answer = .finished };
        return switch (what) {
            .pause => switch (r.state) {
                .pending => .{ .set = .{ .state = .paused } },
                .running => if (r.pause_requested) .{ .answer = .unchanged } else .{ .set = .{ .pause_requested = true } },
                else => .{ .answer = .unchanged },
            },
            .unpause => switch (r.state) {
                .paused => .{ .set = .{ .state = .pending } },
                .running => if (r.pause_requested) .{ .set = .{ .pause_requested = false } } else .{ .answer = .unchanged },
                else => .{ .answer = .unchanged },
            },
            .move => |move| .{ .set = .{ .run_at = move.run_at, .plan = move.plan } },
            .retry => if (r.state == .failed) .{ .set = .{ .state = .pending, .reset = true } } else .{ .answer = .unchanged },
        };
    }
};

/// How many races a change may lose in a row before error.Contended.
const max_lost = 8;

/// Reads the record, computes the patch by its state and writes it on
/// condition of its life, revision and state. A race lost to another
/// change of the record is computed again from the record the store
/// returns with it; a record of another life is a job scheduled again with
/// the key since the read, which the change leaves alone.
fn change(c: *const Client, io: Io, ctx: core.Context, a: Allocator, ref: record.Ref, what: Change, d: ?*Diagnostics) Error!Changed {
    const options: Store.CallOptions = .{ .allocator = a, .diagnostics = d };
    var current = (try c.store.get(io, ctx, &ref, options)) orelse return .not_found;
    const life = current.life;
    var lost: u32 = 0;
    while (true) {
        const set = switch (what.step(current)) {
            .set => |set| set,
            .answer => |answer| return answer,
        };
        if (lost == max_lost) {
            if (d) |x| x.set(null, "{d} other changes of the record came first, one after another; try again", .{max_lost});
            return error.Contended;
        }
        var tag: Store.Tag = undefined;
        io.random(&tag);
        const request: Store.UpdateRequest = .{ .ref = ref, .expect = .{ .life = life, .revision = current.revision, .state = current.state }, .set = set, .tag = tag };
        switch (try c.store.update(io, ctx, &request, options)) {
            .updated => return .changed,
            .not_found => return .not_found,
            .conflict => |now| {
                if (!std.mem.eql(u8, &now.life, &life)) return .not_found;
                current = now;
                lost += 1;
            },
        }
    }
}

/// The last moment of `.at`: 9999-12-31T23:59:59.999Z.
const last_ms = 253_402_300_799_999;
/// The longest `.after`: 100 years of 365.25 days.
const max_after_ns: i96 = 3_155_760_000 * std.time.ns_per_s;

/// The plan of a record and the moment it waits for.
const Start = struct { plan: []const u8, moment: Store.Moment };

/// The plan and the first moment of `when`: "" and the moment for a
/// one-shot job; the canonical text and its first moment after the
/// store's now (`fixedDelay`: its delay) for a repeating one.
fn startOf(c: *const Client, io: Io, a: Allocator, when: When, d: ?*Diagnostics) Error!Start {
    switch (when) {
        .at => |at| {
            if (at.unix_ms == Instant.invalid.unix_ms)
                return refuse(d, "when: .at is Instant.invalid, which Instant.fromUtc gives for values that are no moment", .{});
            if (at.unix_ms < 0 or at.unix_ms > last_ms)
                return refuse(d, "when: .at is {f}; a moment is 1970-01-01T00:00:00.000Z to 9999-12-31T23:59:59.999Z", .{at});
            return .{ .plan = "", .moment = .{ .at = at } };
        },
        .after => |after| {
            if (after.nanoseconds < 0 or after.nanoseconds > max_after_ns)
                return refuse(d, "when: .after is {f}; a delay is 0 to 100 years", .{after});
            return .{ .plan = "", .moment = .{ .after = after } };
        },
        .repeat => |s| {
            s.check(d) catch {
                if (d) |x| x.set(null, "when: {s}", .{x.message()});
                return error.InvalidArgument;
            };
            const plan = try std.fmt.allocPrint(a, "{f}", .{s});
            const moment: Store.Moment = switch (s.internal) {
                .delay => |ms| .{ .after = .fromMilliseconds(@intCast(ms)) },
                else => .{ .at = s.next(c.store.now(io)) orelse return refuse(d, "when: no run within 9 years", .{}) },
            };
            return .{ .plan = plan, .moment = moment };
        },
    }
}

/// error.InvalidArgument unless `text` is 1 to `most` bytes of UTF-8
/// without NUL; `field` names it. The text itself is never quoted.
fn checkText(comptime field: []const u8, text: []const u8, comptime most: usize, d: ?*Diagnostics) error{InvalidArgument}!void {
    const rule = "a " ++ field ++ " is 1–" ++ std.fmt.comptimePrint("{d}", .{most}) ++ " bytes of UTF-8 without NUL";
    if (text.len == 0) return refuse(d, field ++ ": empty; " ++ rule, .{});
    if (text.len > most) return refuse(d, field ++ ": {d} bytes; " ++ rule, .{text.len});
    if (std.mem.findScalar(u8, text, 0) != null) return refuse(d, field ++ ": it holds a NUL; " ++ rule, .{});
    if (!std.unicode.utf8ValidateSlice(text)) return refuse(d, field ++ ": not UTF-8; " ++ rule, .{});
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, format, args);
    return error.InvalidArgument;
}
