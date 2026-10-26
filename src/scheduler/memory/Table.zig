//! The records of `scheduler.MemoryStore` and the rows of its history, with
//! their indexes: the operations of the store contract at a moment that the
//! caller gives, without a lock, a clock or I/O. MemoryStore calls them
//! under its mutex. Strings are copies in `gpa`; results are copied into the
//! caller's allocator, each in two allocations at most, so that a failed
//! one leaves nothing behind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const Diagnostics = @import("../Diagnostics.zig");
const Instant = @import("../Instant.zig");
const Store = @import("../Store.zig");
const record = @import("../record.zig");
const Record = record.Record;
const Ref = record.Ref;
const State = record.State;
const StoreError = Store.StoreError;

const Table = @This();

gpa: Allocator,
max_history: u32,
max_finished: u32,
/// The number of the next record or row: it breaks ties in the indexes.
seq: u64 = 0,
/// Every record by (job, key): one a key, in the order of `list`.
records: Refs = .{},
/// The records that may be claimed, by (job, when, seq): a pending one
/// from its `run_at`, a running one from its `lease_until`.
wake: Wakes = .{},
/// The finished records by (finished_at, seq), and how many there are.
finished: Times = .{},
finished_count: u32 = 0,
/// The records with an `expires_at`, by (expires_at, seq).
expiring: Times = .{},
/// Kinds evicted by the limits, and kinds MemoryStore has warned about.
evicted: Evictions = .{},
warned: Evictions = .{},

pub const Evictions = struct { records: bool = false, rows: bool = false };

const Refs = std.Treap(Ref, orderRef);
const Wakes = std.Treap(WakeKey, orderWake);
const Times = std.Treap(TimeKey, orderTime);

const WakeKey = struct { job: []const u8, ms: i64, seq: u64 };
const TimeKey = struct { ms: i64, seq: u64 };

fn orderRef(a: Ref, b: Ref) Order {
    const job = std.mem.order(u8, a.job, b.job);
    return if (job != .eq) job else std.mem.order(u8, a.key, b.key);
}

fn orderWake(a: WakeKey, b: WakeKey) Order {
    const job = std.mem.order(u8, a.job, b.job);
    if (job != .eq) return job;
    return orderTime(.{ .ms = a.ms, .seq = a.seq }, .{ .ms = b.ms, .seq = b.seq });
}

fn orderTime(a: TimeKey, b: TimeKey) Order {
    const ms = std.math.order(a.ms, b.ms);
    return if (ms != .eq) ms else std.math.order(a.seq, b.seq);
}

/// A record and its places in the indexes. `job`, `key`, `tenant`,
/// `payload` and `trace` share the allocation `fixed`; `plan`, `owner` and
/// the error of `last` have one each.
const Entry = struct {
    rec: Record,
    seq: u64,
    fixed: []u8,
    by_ref: Refs.Node = unlinked(Refs),
    wake: Wakes.Node = unlinked(Wakes),
    finished: Times.Node = unlinked(Times),
    expiring: Times.Node = unlinked(Times),
};

fn unlinked(comptime Tree: type) Tree.Node {
    return .{ .key = undefined, .priority = 0, .parent = null, .children = .{ null, null } };
}

/// A node is in its tree while its priority is not 0.
fn linked(node: anytype) bool {
    return node.priority != 0;
}

fn link(tree: anytype, node: anytype, key: anytype) void {
    var slot = tree.getEntryFor(key);
    std.debug.assert(slot.node == null);
    slot.set(node);
}

fn unlink(tree: anytype, node: anytype) void {
    if (!linked(node)) return;
    var slot = tree.getEntryForExisting(node);
    slot.set(null);
}

/// The first node of a tree whose key is after `key`, or at it too when
/// `strict` is false.
fn seek(root: anytype, key: anytype, comptime order: anytype, strict: bool) @TypeOf(root) {
    var node = root;
    var best: @TypeOf(root) = null;
    while (node) |n| {
        const o = order(n.key, key);
        if (o == .gt or (!strict and o == .eq)) {
            best = n;
            node = n.children[0];
        } else node = n.children[1];
    }
    return best;
}

fn entryOf(comptime field: []const u8, node: anytype) *Entry {
    return @alignCast(@fieldParentPtr(field, node));
}

pub fn init(gpa: Allocator, max_history: u32, max_finished: u32) Table {
    return .{ .gpa = gpa, .max_history = max_history, .max_finished = max_finished };
}

pub fn deinit(t: *Table) void {
    while (t.records.getMin()) |node| t.drop(entryOf("by_ref", node));
    t.* = undefined;
}

/// The kinds evicted that MemoryStore has not warned about yet; from now on
/// it has.
pub fn takeEvictions(t: *Table) Evictions {
    const fresh: Evictions = .{
        .records = t.evicted.records and !t.warned.records,
        .rows = t.evicted.rows and !t.warned.rows,
    };
    t.warned = t.evicted;
    return fresh;
}

/// Drops the records whose `expires_at` came.
pub fn purge(t: *Table, now: Instant) void {
    while (t.expiring.getMin()) |node| {
        if (node.key.ms > now.unix_ms) break;
        t.drop(entryOf("expiring", node));
    }
}

fn find(t: *Table, ref: Ref) ?*Entry {
    const slot = t.records.getEntryFor(ref);
    return if (slot.node) |node| entryOf("by_ref", node) else null;
}

fn isFinished(state: State) bool {
    return state == .succeeded or state == .failed;
}

/// Puts the record in the indexes that its fields call for: when it may be
/// claimed (pending: `run_at`, running: `lease_until`, else never), whether
/// it is finished, when it expires.
fn reindex(t: *Table, e: *Entry) void {
    unlink(&t.wake, &e.wake);
    const wake: ?Instant = switch (e.rec.state) {
        .pending => e.rec.run_at,
        .running => e.rec.lease_until,
        .paused, .succeeded, .failed => null,
    };
    if (wake) |at| link(&t.wake, &e.wake, WakeKey{ .job = e.rec.job, .ms = at.unix_ms, .seq = e.seq });
    if (linked(&e.finished)) {
        unlink(&t.finished, &e.finished);
        t.finished_count -= 1;
    }
    if (isFinished(e.rec.state)) {
        link(&t.finished, &e.finished, TimeKey{ .ms = (e.rec.finished_at orelse Instant.invalid).unix_ms, .seq = e.seq });
        t.finished_count += 1;
    }
    unlink(&t.expiring, &e.expiring);
    if (e.rec.expires_at) |at| link(&t.expiring, &e.expiring, TimeKey{ .ms = at.unix_ms, .seq = e.seq });
}

/// Takes the record out of every index and frees it.
fn drop(t: *Table, e: *Entry) void {
    unlink(&t.records, &e.by_ref);
    unlink(&t.wake, &e.wake);
    if (linked(&e.finished)) {
        unlink(&t.finished, &e.finished);
        t.finished_count -= 1;
    }
    unlink(&t.expiring, &e.expiring);
    t.gpa.free(e.fixed);
    t.gpa.free(e.rec.plan);
    if (e.rec.owner) |owner| t.gpa.free(owner);
    if (e.rec.last) |last| if (last.error_name) |text| t.gpa.free(text);
    t.gpa.destroy(e);
}

/// Drops the oldest finished records while there are more than the limit.
fn evictFinished(t: *Table) void {
    while (t.finished_count > t.max_finished) {
        t.drop(entryOf("finished", t.finished.getMin() orelse return));
        t.evicted.records = true;
    }
}

pub fn resolve(now: Instant, moment: Store.Moment) Instant {
    return switch (moment) {
        .at => |at| at,
        .after => |after| now.add(after),
    };
}

fn refuse(d: ?*Diagnostics, comptime format: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, format, args);
    return error.InvalidArgument;
}

pub fn create(t: *Table, now: Instant, request: *const Store.CreateRequest, d: ?*Diagnostics) StoreError!Store.CreateResult {
    if (!record.validJobName(request.job))
        return refuse(d, "create: a job name is 1–64 bytes of a-z, 0-9, '-', '_' and '.', starting with a letter or a digit", .{});
    if (request.key.len != 0 and !record.validKey(request.key)) return refuse(d, "create: a key is 1–256 bytes of UTF-8 without NUL", .{});
    if (request.tenant) |tenant| if (!record.validTenant(tenant)) return refuse(d, "create: a tenant is 1–128 bytes of UTF-8 without NUL", .{});
    const old = t.find(.{ .job = request.job, .key = request.key });
    if (old) |e| if (!isFinished(e.rec.state)) return .existing;

    const len = request.job.len + request.key.len + request.payload.len + optionalLen(request.tenant) + optionalLen(request.trace);
    const fixed = try t.gpa.alloc(u8, len);
    errdefer t.gpa.free(fixed);
    const plan = try t.gpa.dupe(u8, request.plan);
    errdefer t.gpa.free(plan);
    const e = try t.gpa.create(Entry);
    var out: Out = .{ .bytes = fixed };
    const run_at = resolve(now, request.run_at);
    e.* = .{
        .seq = t.seq,
        .fixed = fixed,
        .rec = .{
            .job = out.text(request.job),
            .key = out.text(request.key),
            .tenant = out.optional(request.tenant),
            .state = .pending,
            .plan = plan,
            .payload = out.text(request.payload),
            .scheduled_at = run_at,
            .run_at = run_at,
            .attempt = 0,
            .fence = 0,
            .revision = 0,
            .pause_requested = false,
            .owner = null,
            .claimed_at = null,
            .lease_until = null,
            .last = null,
            .created_at = now,
            .updated_at = now,
            .finished_at = null,
            .expires_at = null,
            .trace = out.optional(request.trace),
            .life = request.life,
            .unreadable_since = null,
        },
    };
    t.seq += 1;
    if (old) |o| t.drop(o);
    link(&t.records, &e.by_ref, Ref{ .job = e.rec.job, .key = e.rec.key });
    t.reindex(e);
    return if (old == null) .created else .replaced;
}

pub fn get(t: *Table, ref: Ref, a: Allocator) StoreError!?Record {
    const e = t.find(ref) orelse return null;
    return try recordOut(a, &e.rec);
}

pub fn update(t: *Table, now: Instant, request: *const Store.UpdateRequest, a: Allocator, d: ?*Diagnostics) StoreError!Store.UpdateResult {
    const set = request.set;
    if (set.state) |state| if (state != .pending and state != .paused)
        return refuse(d, "update: a patch makes a record pending or paused, not {t}", .{state});
    const e = t.find(request.ref) orelse return .not_found;
    if (e.rec.revision != request.expect.revision or e.rec.state != request.expect.state) return .{ .conflict = try recordOut(a, &e.rec) };
    if (e.rec.state == .running and (set.state != null or set.reset))
        return refuse(d, "update: a running record changes its state only by its claim", .{});

    var next = e.rec;
    if (set.state) |state| next.state = state;
    if (set.reset) {
        next.state = set.state orelse .pending;
        next.run_at = now;
        next.attempt = 0;
        next.unreadable_since = null;
    }
    if (set.run_at) |moment| {
        const at = resolve(now, moment);
        next.scheduled_at = at;
        next.attempt = 0;
        if (next.state != .running) next.run_at = at;
    }
    if (set.pause_requested) |requested| next.pause_requested = requested;
    if (!isFinished(next.state)) {
        next.finished_at = null;
        next.expires_at = null;
    }
    if ((next.state == .pending or next.state == .paused) and next.run_at == null)
        return refuse(d, "update: a pending or paused record needs a run_at: set run_at, or reset", .{});
    if (isFinished(next.state) and next.run_at != null)
        return refuse(d, "update: a finished record has no run_at: make it pending or paused too", .{});
    if (set.plan) |plan| {
        const copy = try t.gpa.dupe(u8, plan);
        t.gpa.free(next.plan);
        next.plan = copy;
    }
    next.revision += 1;
    next.updated_at = now;
    e.rec = next;
    t.reindex(e);
    return .{ .updated = next.revision };
}

pub fn remove(t: *Table, ref: Ref) bool {
    t.drop(t.find(ref) orelse return false);
    return true;
}

/// The continuation of `list` is "<job>/<key>" of the last record of a
/// full page: a job name has no '/'.
pub fn list(t: *Table, request: *const Store.ListRequest, a: Allocator, d: ?*Diagnostics) StoreError!record.RecordPage {
    const filter = request.filter;
    const page = request.page;
    if (page.limit == 0) return refuse(d, "list: a page is 1 or more records", .{});
    const start = if (page.after) |after| at: {
        const slash = std.mem.findScalar(u8, after, '/') orelse return refuse(d, "list: page.after is no continuation of this store", .{});
        break :at seek(t.records.root, Ref{ .job = after[0..slash], .key = after[slash + 1 ..] }, orderRef, true);
    } else if (filter.job) |job| seek(t.records.root, Ref{ .job = job, .key = "" }, orderRef, false) else t.records.getMin();

    // Count first, then copy: the same walk twice.
    var walk: ListWalk = .{ .node = start, .filter = filter };
    var n: usize = 0;
    var len: usize = 0;
    var last: ?*Entry = null;
    while (n < page.limit) : (n += 1) {
        const e = walk.next() orelse break;
        len += recordSize(&e.rec);
        last = e;
    }
    const full = n == page.limit;
    if (full) len += last.?.rec.job.len + 1 + last.?.rec.key.len;
    const records = try a.alloc(Record, n);
    errdefer a.free(records);
    var out: Out = .{ .bytes = try a.alloc(u8, len) };
    walk = .{ .node = start, .filter = filter };
    for (records) |*r| r.* = copyRecord(&walk.next().?.rec, &out);
    const next = if (full) out.join(last.?.rec.job, last.?.rec.key) else null;
    return .{ .records = records, .next = next };
}

/// The records of a filter in the order (job, key), from a node on.
const ListWalk = struct {
    node: ?*Refs.Node,
    filter: record.ListFilter,

    fn next(w: *ListWalk) ?*Entry {
        while (w.node) |node| {
            w.node = node.next();
            const e = entryOf("by_ref", node);
            if (w.filter.job) |job| if (!std.mem.eql(u8, job, e.rec.job)) {
                // The records of the job are behind.
                w.node = null;
                return null;
            };
            if (w.filter.state) |state| if (state != e.rec.state) continue;
            if (w.filter.tenant) |tenant| if (!std.mem.eql(u8, tenant, e.rec.tenant orelse continue)) continue;
            return e;
        }
        return null;
    }
};

fn optionalLen(text: ?[]const u8) usize {
    return if (text) |x| x.len else 0;
}

/// Bytes that the copies of a result take, handed out in order.
const Out = struct {
    bytes: []u8,
    used: usize = 0,

    fn text(o: *Out, s: []const u8) []const u8 {
        const copy = o.bytes[o.used..][0..s.len];
        @memcpy(copy, s);
        o.used += s.len;
        return copy;
    }

    fn optional(o: *Out, s: ?[]const u8) ?[]const u8 {
        return if (s) |x| o.text(x) else null;
    }

    /// "<a>/<b>".
    fn join(o: *Out, a: []const u8, b: []const u8) []const u8 {
        const start = o.used;
        _ = o.text(a);
        _ = o.text("/");
        _ = o.text(b);
        return o.bytes[start..o.used];
    }
};

fn recordSize(r: *const Record) usize {
    const last = if (r.last) |l| optionalLen(l.error_name) else 0;
    return r.job.len + r.key.len + r.plan.len + r.payload.len + optionalLen(r.tenant) + optionalLen(r.owner) + optionalLen(r.trace) + last;
}

fn copyRecord(r: *const Record, out: *Out) Record {
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

fn recordOut(a: Allocator, r: *const Record) Allocator.Error!Record {
    var out: Out = .{ .bytes = try a.alloc(u8, recordSize(r)) };
    return copyRecord(r, &out);
}
