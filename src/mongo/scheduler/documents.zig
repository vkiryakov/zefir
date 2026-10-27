//! The documents of `mongo.SchedulerStore`: a record of the collection of
//! jobs and a row of the collection of runs, as the store reads them into
//! the types of zefir-scheduler and copies them into the caller's memory,
//! and the pieces of BSON that its writes share.
//!
//! A record is `{_id: "<job>/<key>", job, key, tenant?, life: <32 hex>,
//! plan, payload, trace?, state, scheduled_at, run_at?, wake_at?, attempt:
//! Int32, fence: Int64, revision: Int64, pause_requested?, owner?, tag?,
//! claimed_at?, lease_until?, prev?: {owner, claimed_at}, last?: {outcome,
//! error?, attempt, started_at, finished_at}, unreadable_since?,
//! created_at, updated_at, finished_at?, expires_at?}`, where `?` marks a
//! field that is left out rather than null. A row is `{_id: "<life>/<fence>",
//! job, key, tenant?, life, fence, attempt, scheduled_at, started_at,
//! finished_at, outcome, error?, instance, expires_at?}`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Duration = std.Io.Duration;
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const Instant = scheduler.Instant;
const Record = scheduler.Record;
const Run = scheduler.Run;
const Store = scheduler.Store;

/// A record as the collection keeps it, read with its strings left in the
/// document.
const RecordDoc = struct {
    job: []const u8,
    key: []const u8,
    tenant: ?[]const u8 = null,
    life: []const u8,
    plan: []const u8,
    payload: []const u8,
    trace: ?[]const u8 = null,
    state: scheduler.State,
    scheduled_at: bson.DateTime,
    run_at: ?bson.DateTime = null,
    attempt: u32,
    fence: i64,
    revision: i64,
    pause_requested: bool = false,
    owner: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    claimed_at: ?bson.DateTime = null,
    lease_until: ?bson.DateTime = null,
    prev: ?struct { owner: []const u8, claimed_at: bson.DateTime } = null,
    last: ?struct {
        outcome: scheduler.RunOutcome,
        @"error": ?[]const u8 = null,
        attempt: u32,
        started_at: bson.DateTime,
        finished_at: bson.DateTime,
    } = null,
    unreadable_since: ?bson.DateTime = null,
    created_at: bson.DateTime,
    updated_at: bson.DateTime,
    finished_at: ?bson.DateTime = null,
    expires_at: ?bson.DateTime = null,
};

const RunDoc = struct {
    job: []const u8,
    key: []const u8,
    tenant: ?[]const u8 = null,
    life: []const u8,
    fence: i64,
    attempt: u32,
    scheduled_at: bson.DateTime,
    started_at: bson.DateTime,
    finished_at: bson.DateTime,
    outcome: scheduler.RunOutcome,
    @"error": ?[]const u8 = null,
    instance: []const u8,
    expires_at: ?bson.DateTime = null,
};

/// A record read from a document, its strings still in the document.
pub const Read = struct {
    record: Record,
    /// The mark of the write that left the record so.
    tag: ?[]const u8,
    /// A claim of a lease that expired: whose the record was.
    took_over: ?Store.TookOver,
};

/// What makes a document no record or no row, for `Diagnostics`.
pub const Problem = struct {
    text: [128]u8 = undefined,
    len: usize = 0,

    pub fn message(p: *const Problem) []const u8 {
        return p.text[0..p.len];
    }

    fn set(p: *Problem, comptime fmt: []const u8, args: anytype) error{Corrupt} {
        const written = std.fmt.bufPrint(&p.text, fmt, args) catch &p.text;
        p.len = written.len;
        return error.Corrupt;
    }
};

pub const ReadError = error{ Corrupt, OutOfMemory };

/// The record that `raw`, a document of the collection of jobs, holds; its
/// strings are slices into `raw`. A field of another type, an Int64 below 0
/// or a life that is not 32 hex digits is `error.Corrupt`, and `problem`
/// says which.
pub fn readRecord(arena: Allocator, raw: bson.RawDocument, problem: *Problem) ReadError!Read {
    var why: bson.DecodeDiagnostics = .{};
    const doc = bson.decode(RecordDoc, arena, raw, .{ .copy_strings = false, .diagnostics = &why }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("field '{s}': error.{t}", .{ why.path(), err }),
    };
    const life = parseLife(doc.life) orelse return problem.set("field 'life': not 32 hex digits", .{});
    const fence = std.math.cast(u64, doc.fence) orelse return problem.set("field 'fence': below 0", .{});
    const revision = std.math.cast(u64, doc.revision) orelse return problem.set("field 'revision': below 0", .{});
    return .{
        .record = .{
            .job = doc.job,
            .key = doc.key,
            .tenant = doc.tenant,
            .state = doc.state,
            .plan = doc.plan,
            .payload = doc.payload,
            .scheduled_at = instant(doc.scheduled_at),
            .run_at = optionalInstant(doc.run_at),
            .attempt = doc.attempt,
            .fence = fence,
            .revision = revision,
            .pause_requested = doc.pause_requested,
            .owner = doc.owner,
            .claimed_at = optionalInstant(doc.claimed_at),
            .lease_until = optionalInstant(doc.lease_until),
            .last = if (doc.last) |last| .{
                .outcome = last.outcome,
                .error_name = last.@"error",
                .attempt = last.attempt,
                .started_at = instant(last.started_at),
                .finished_at = instant(last.finished_at),
            } else null,
            .created_at = instant(doc.created_at),
            .updated_at = instant(doc.updated_at),
            .finished_at = optionalInstant(doc.finished_at),
            .expires_at = optionalInstant(doc.expires_at),
            .trace = doc.trace,
            .life = life,
            .unreadable_since = optionalInstant(doc.unreadable_since),
        },
        .tag = doc.tag,
        .took_over = if (doc.prev) |prev| .{ .owner = prev.owner, .claimed_at = instant(prev.claimed_at) } else null,
    };
}

/// The row that `raw`, a document of the collection of runs, holds; its
/// strings are slices into `raw`.
pub fn readRun(arena: Allocator, raw: bson.RawDocument, problem: *Problem) ReadError!Run {
    var why: bson.DecodeDiagnostics = .{};
    const doc = bson.decode(RunDoc, arena, raw, .{ .copy_strings = false, .diagnostics = &why }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("field '{s}': error.{t}", .{ why.path(), err }),
    };
    return .{
        .job = doc.job,
        .key = doc.key,
        .tenant = doc.tenant,
        .life = parseLife(doc.life) orelse return problem.set("field 'life': not 32 hex digits", .{}),
        .fence = std.math.cast(u64, doc.fence) orelse return problem.set("field 'fence': below 0", .{}),
        .attempt = doc.attempt,
        .scheduled_at = instant(doc.scheduled_at),
        .started_at = instant(doc.started_at),
        .finished_at = instant(doc.finished_at),
        .outcome = doc.outcome,
        .error_name = doc.@"error",
        .instance = doc.instance,
        .expires_at = optionalInstant(doc.expires_at),
    };
}

fn instant(t: bson.DateTime) Instant {
    return .fromUnixMs(t.milliseconds);
}

fn optionalInstant(t: ?bson.DateTime) ?Instant {
    return if (t) |x| instant(x) else null;
}

/// The 16 bytes of a life or a tag as 32 lowercase hex digits.
pub fn hex(bytes: [16]u8) [32]u8 {
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn parseLife(text: []const u8) ?scheduler.Life {
    if (text.len != 32) return null;
    var life: scheduler.Life = undefined;
    _ = std.fmt.hexToBytes(&life, text) catch return null;
    return life;
}

/// The rule of the name of a job (A35): 1–64 bytes of a–z, 0–9, '-', '_'
/// and '.', starting with a letter or a digit. No '/', so "<job>/<key>"
/// names one record.
pub fn validJobName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// The rule of a key and of a tenant: 1 to `most` bytes of UTF-8 without
/// NUL.
pub fn validText(text: []const u8, most: usize) bool {
    if (text.len == 0 or text.len > most) return false;
    if (std.mem.findScalar(u8, text, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(text);
}

/// Milliseconds of `d`, rounded down as `Instant.add` rounds, within i64.
pub fn millis(d: Duration) i64 {
    const ms = @divFloor(d.nanoseconds, std.time.ns_per_ms);
    return @intCast(std.math.clamp(ms, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// `{key: {$literal: text}}`: a string of the user in a stage of a
/// pipeline, where one that starts with `$` would name a field.
pub fn putLiteral(b: *bson.Builder, key: []const u8, text: []const u8) bson.Builder.Error!void {
    try b.beginDocument(key);
    try b.putString("$literal", text);
    try b.end();
}

pub fn putDate(b: *bson.Builder, key: []const u8, at: Instant) bson.Builder.Error!void {
    try b.putDateTime(key, .{ .milliseconds = at.unix_ms });
}

/// `{key: {$add: ["$$NOW", <ms>]}}`: `d` after the server's now.
pub fn putFromNow(b: *bson.Builder, key: []const u8, d: Duration) bson.Builder.Error!void {
    try b.beginDocument(key);
    try b.beginArray("$add");
    try b.putString("", "$$NOW");
    try b.putInt64("", millis(d));
    try b.end();
    try b.end();
}

/// `moment` in a stage: its date, or `.after` from the server's now.
pub fn putMoment(b: *bson.Builder, key: []const u8, moment: Store.Moment) bson.Builder.Error!void {
    switch (moment) {
        .at => |at| try putDate(b, key, at),
        .after => |d| try putFromNow(b, key, d),
    }
}

/// Bytes that the copies of a result take, handed out in order.
pub const Out = struct {
    bytes: []u8,
    used: usize = 0,

    pub fn text(o: *Out, s: []const u8) []const u8 {
        const copy = o.bytes[o.used..][0..s.len];
        @memcpy(copy, s);
        o.used += s.len;
        return copy;
    }

    fn optional(o: *Out, s: ?[]const u8) ?[]const u8 {
        return if (s) |x| o.text(x) else null;
    }
};

fn optionalLen(text: ?[]const u8) usize {
    return if (text) |x| x.len else 0;
}

/// The bytes of the strings of `r`.
pub fn recordSize(r: *const Record) usize {
    const last = if (r.last) |l| optionalLen(l.error_name) else 0;
    return r.job.len + r.key.len + r.plan.len + r.payload.len + optionalLen(r.tenant) + optionalLen(r.owner) + optionalLen(r.trace) + last;
}

/// `r` with its strings in `out`.
pub fn copyRecord(r: *const Record, out: *Out) Record {
    var copy = r.*;
    copy.job = out.text(r.job);
    copy.key = out.text(r.key);
    copy.tenant = out.optional(r.tenant);
    copy.plan = out.text(r.plan);
    copy.payload = out.text(r.payload);
    copy.owner = out.optional(r.owner);
    copy.trace = out.optional(r.trace);
    if (r.last) |last| copy.last.?.error_name = out.optional(last.error_name);
    return copy;
}

/// A copy of `r` in `a`, in one allocation.
pub fn recordOut(a: Allocator, r: *const Record) Allocator.Error!Record {
    var out: Out = .{ .bytes = try a.alloc(u8, recordSize(r)) };
    return copyRecord(r, &out);
}

pub fn runSize(run: *const Run) usize {
    return run.job.len + run.key.len + run.instance.len + optionalLen(run.tenant) + optionalLen(run.error_name);
}

pub fn copyRun(run: *const Run, out: *Out) Run {
    var copy = run.*;
    copy.job = out.text(run.job);
    copy.key = out.text(run.key);
    copy.tenant = out.optional(run.tenant);
    copy.error_name = out.optional(run.error_name);
    copy.instance = out.text(run.instance);
    return copy;
}
