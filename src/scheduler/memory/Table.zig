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
/// The rows of the history by (life, fence): one a claim.
rows: Rows = .{},
/// The rows by (finished_at, seq), and how many there are.
row_order: Times = .{},
row_count: u32 = 0,
/// The rows with an `expires_at`, by (expires_at, seq).
row_expiring: Times = .{},
/// Kinds evicted by the limits, and kinds MemoryStore has warned about.
evicted: Evictions = .{},
warned: Evictions = .{},

pub const Evictions = struct { records: bool = false, rows: bool = false };

const Refs = std.Treap(Ref, orderRef);
const Wakes = std.Treap(WakeKey, orderWake);
const Times = std.Treap(TimeKey, orderTime);
const Rows = std.Treap(RowKey, orderRow);

const WakeKey = struct { job: []const u8, ms: i64, seq: u64 };
const TimeKey = struct { ms: i64, seq: u64 };
const RowKey = struct { life: record.Life, fence: u64 };

fn orderRow(a: RowKey, b: RowKey) Order {
    const life = std.mem.order(u8, &a.life, &b.life);
    return if (life != .eq) life else std.math.order(a.fence, b.fence);
}

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

/// A row of the history and its places in the indexes; its strings share
/// the allocation `fixed`.
const Row = struct {
    run: record.Run,
    seq: u64,
    fixed: []u8,
    by_id: Rows.Node = unlinked(Rows),
    order: Times.Node = unlinked(Times),
    expiring: Times.Node = unlinked(Times),
};

fn rowOf(comptime field: []const u8, node: anytype) *Row {
    return @alignCast(@fieldParentPtr(field, node));
}

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
    while (t.row_order.getMin()) |node| t.dropRow(rowOf("order", node));
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

/// Drops the records and the rows whose `expires_at` came.
pub fn purge(t: *Table, now: Instant) void {
    while (t.expiring.getMin()) |node| {
        if (node.key.ms > now.unix_ms) break;
        t.drop(entryOf("expiring", node));
    }
    while (t.row_expiring.getMin()) |node| {
        if (node.key.ms > now.unix_ms) break;
        t.dropRow(rowOf("expiring", node));
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

fn dropRow(t: *Table, row: *Row) void {
    unlink(&t.rows, &row.by_id);
    unlink(&t.row_order, &row.order);
    unlink(&t.row_expiring, &row.expiring);
    t.row_count -= 1;
    t.gpa.free(row.fixed);
    t.gpa.destroy(row);
}

/// Drops the oldest rows while there are more than the limit.
fn evictRows(t: *Table) void {
    while (t.row_count > t.max_history) {
        t.dropRow(rowOf("order", t.row_order.getMin() orelse return));
        t.evicted.rows = true;
    }
}

/// Writes the row of a claim, unless its (life, fence) has one: then only
/// the owner's row over an abandoned one replaces it.
fn writeRow(t: *Table, now: Instant, run: *const record.Run, keep: record.Retention) Allocator.Error!void {
    const slot = t.rows.getEntryFor(.{ .life = run.life, .fence = run.fence });
    const old = if (slot.node) |node| rowOf("by_id", node) else null;
    if (old) |o| if (o.run.outcome != .abandoned or run.outcome == .abandoned) return;
    const fixed = try t.gpa.alloc(u8, runSize(run));
    errdefer t.gpa.free(fixed);
    const row = try t.gpa.create(Row);
    var out: Out = .{ .bytes = fixed };
    row.* = .{ .run = copyRun(run, &out), .seq = t.seq, .fixed = fixed };
    row.run.finished_at = now;
    row.run.expires_at = expiry(now, keep);
    t.seq += 1;
    if (old) |o| t.dropRow(o);
    link(&t.rows, &row.by_id, RowKey{ .life = row.run.life, .fence = row.run.fence });
    link(&t.row_order, &row.order, TimeKey{ .ms = now.unix_ms, .seq = row.seq });
    if (row.run.expires_at) |at| link(&t.row_expiring, &row.expiring, TimeKey{ .ms = at.unix_ms, .seq = row.seq });
    t.row_count += 1;
}

/// When what is kept by `keep` from `now` expires; null: never.
fn expiry(now: Instant, keep: record.Retention) ?Instant {
    return switch (keep) {
        .keep_for => |d| now.add(d),
        .none, .forever => null,
    };
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
    const expect = request.expect;
    if (!std.mem.eql(u8, &e.rec.life, &expect.life) or e.rec.revision != expect.revision or e.rec.state != expect.state)
        return .{ .conflict = try recordOut(a, &e.rec) };
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

/// Claims by the index of when records may be claimed: the heads of the
/// request's jobs merge by time, so k records cost O(k log n), and of a
/// `keyed_only` job only its one declared record is passed over.
pub fn claim(t: *Table, now: Instant, request: *const Store.ClaimRequest, a: Allocator, d: ?*Diagnostics) StoreError!Store.ClaimResult {
    if (request.max == 0) return refuse(d, "claim: max is 1 or more", .{});
    const heads = try t.gpa.alloc(Head, request.any_key.len + request.keyed_only.len);
    defer t.gpa.free(heads);
    var jobs: usize = 0;
    for ([_][]const []const u8{ request.any_key, request.keyed_only }, [_]bool{ false, true }) |names, keyed_only| {
        names: for (names) |job| {
            for (heads[0..jobs]) |h| if (std.mem.eql(u8, h.job, job)) continue :names;
            heads[jobs] = .{ .job = job, .keyed_only = keyed_only, .node = null };
            jobs += 1;
        }
    }
    const used = heads[0..jobs];
    for (used) |*h| h.start(t);
    var picked: std.ArrayList(*Entry) = .empty;
    defer picked.deinit(t.gpa);
    while (picked.items.len < request.max) {
        const h = earliest(used) orelse break;
        if (h.node.?.key.ms > now.unix_ms) break;
        try picked.append(t.gpa, entryOf("wake", h.node.?));
        h.advance();
    }

    // Everything that may fail first, so that running out of memory claims
    // nothing.
    const owners = try t.gpa.alloc([]u8, picked.items.len);
    defer t.gpa.free(owners);
    var made: usize = 0;
    errdefer for (owners[0..made]) |owner| t.gpa.free(owner);
    for (owners) |*owner| {
        owner.* = try t.gpa.dupe(u8, request.owner);
        made += 1;
    }
    var len: usize = 0;
    // The old owner goes to took_over, the new one into the record.
    for (picked.items) |e| len += recordSize(&e.rec) + request.owner.len;
    const claimed = try a.alloc(Store.Claimed, picked.items.len);
    errdefer a.free(claimed);
    var out: Out = .{ .bytes = try a.alloc(u8, len) };

    for (picked.items, owners, claimed) |e, owner, *c| {
        const took_over: ?Store.TookOver = if (e.rec.state == .running) .{
            .owner = out.text(e.rec.owner orelse ""),
            .claimed_at = e.rec.claimed_at orelse Instant.invalid,
        } else null;
        if (e.rec.owner) |old| t.gpa.free(old);
        e.rec.state = .running;
        e.rec.owner = owner;
        e.rec.attempt += 1;
        e.rec.fence += 1;
        e.rec.claimed_at = now;
        e.rec.lease_until = now.add(request.lease);
        e.rec.run_at = null;
        t.reindex(e);
        c.* = .{ .record = copyRecord(&e.rec, &out), .took_over = took_over };
    }
    var next_in: ?std.Io.Duration = null;
    if (picked.items.len < request.max) {
        for (used) |*h| h.start(t);
        if (earliest(used)) |h| next_in = .fromNanoseconds((@as(i96, h.node.?.key.ms) - now.unix_ms) * std.time.ns_per_ms);
    }
    return .{ .claimed = claimed, .next_in = next_in };
}

/// Where a claim stands in the records of one job.
const Head = struct {
    job: []const u8,
    keyed_only: bool,
    node: ?*Wakes.Node,

    fn start(h: *Head, t: *Table) void {
        h.node = seek(t.wake.root, WakeKey{ .job = h.job, .ms = std.math.minInt(i64), .seq = 0 }, orderWake, false);
        h.skip();
    }

    fn advance(h: *Head) void {
        h.node = h.node.?.next();
        h.skip();
    }

    /// Stops at the end of the job's records, and passes over the declared
    /// record of a `keyed_only` job.
    fn skip(h: *Head) void {
        while (h.node) |node| {
            if (!std.mem.eql(u8, node.key.job, h.job)) {
                h.node = null;
                return;
            }
            if (!h.keyed_only or entryOf("wake", node).rec.key.len != 0) return;
            h.node = node.next();
        }
    }
};

/// The head whose record may be claimed first.
fn earliest(heads: []Head) ?*Head {
    var best: ?*Head = null;
    for (heads) |*h| {
        const node = h.node orelse continue;
        if (best) |b| if (orderTime(.{ .ms = node.key.ms, .seq = node.key.seq }, .{ .ms = b.node.?.key.ms, .seq = b.node.?.key.seq }) != .lt) continue;
        best = h;
    }
    return best;
}

/// The claim holds while the record is of its life, owner and fence,
/// however late (A6): an expired lease only lets another claim take it.
pub fn renew(t: *Table, now: Instant, request: *const Store.RenewRequest) Store.RenewResult {
    const e = t.find(request.ref) orelse return .removed;
    if (!std.mem.eql(u8, &e.rec.life, &request.life)) return .removed;
    if (!t.holds(e, request.owner, request.fence)) return .lost;
    e.rec.lease_until = now.add(request.lease);
    t.reindex(e);
    return .renewed;
}

fn holds(_: *const Table, e: *const Entry, owner: []const u8, fence: u64) bool {
    return e.rec.state == .running and e.rec.fence == fence and std.mem.eql(u8, e.rec.owner orelse "", owner);
}

/// The rows first, also when the transition is refused; then the
/// transition, which clears `pause_requested`.
pub fn finish(t: *Table, now: Instant, request: *const Store.FinishRequest, a: Allocator, d: ?*Diagnostics) StoreError!Store.FinishResult {
    switch (request.next) {
        .wait => |wait| if (wait.state != .pending and wait.state != .paused)
            return refuse(d, "finish: a job waits pending or paused, not {t}", .{wait.state}),
        .done => |done| {
            if (!isFinished(done.state)) return refuse(d, "finish: a job is done succeeded or failed, not {t}", .{done.state});
            if (done.keep == .none) return refuse(d, "finish: done keeps the record for a time or always; drop it with .delete", .{});
        },
        .delete => {},
    }
    if (request.history.keep != .none) {
        for (request.history.runs) |*run| try t.writeRow(now, run, request.history.keep);
        t.evictRows();
    }
    const e = t.find(request.ref) orelse return .lost;
    if (!std.mem.eql(u8, &e.rec.life, &request.life) or !t.holds(e, request.owner, request.fence)) return .lost;
    if (e.rec.revision != request.revision) return .{ .changed = try recordOut(a, &e.rec) };
    if (request.next == .delete) {
        t.drop(e);
        return .done;
    }
    const last_error: ?[]u8 = if (request.last) |last| (if (last.error_name) |text| try t.gpa.dupe(u8, text) else null) else null;
    if (request.last) |last| {
        if (e.rec.last) |old| if (old.error_name) |text| t.gpa.free(text);
        e.rec.last = last;
        e.rec.last.?.error_name = last_error;
        e.rec.last.?.finished_at = now;
    }
    if (e.rec.owner) |owner| t.gpa.free(owner);
    e.rec.owner = null;
    e.rec.claimed_at = null;
    e.rec.lease_until = null;
    e.rec.pause_requested = false;
    switch (request.next) {
        .wait => |wait| {
            const at = resolve(now, wait.run_at);
            e.rec.state = wait.state;
            e.rec.run_at = at;
            e.rec.scheduled_at = wait.scheduled_at orelse at;
            e.rec.attempt = wait.attempt;
            e.rec.unreadable_since = wait.unreadable_since;
        },
        .done => |done| {
            e.rec.state = done.state;
            e.rec.run_at = null;
            e.rec.finished_at = now;
            e.rec.expires_at = expiry(now, done.keep);
            e.rec.unreadable_since = null;
        },
        .delete => {},
    }
    t.reindex(e);
    t.evictFinished();
    return .done;
}

/// The continuation of `history` is "<finished_at in ms>/<seq>" of the last
/// row of a full page.
pub fn history(t: *Table, request: *const Store.HistoryRequest, a: Allocator, d: ?*Diagnostics) StoreError!record.RunPage {
    const page = request.page;
    if (page.limit == 0) return refuse(d, "history: a page is 1 or more rows", .{});
    const start = if (page.after) |after| at: {
        const key = parseTimeKey(after) orelse return refuse(d, "history: page.after is no continuation of this store", .{});
        // The last row before the continuation.
        var node = t.row_order.root;
        var best: ?*Times.Node = null;
        while (node) |n| {
            if (orderTime(n.key, key) == .lt) {
                best = n;
                node = n.children[1];
            } else node = n.children[0];
        }
        break :at best;
    } else t.row_order.getMax();

    var walk: HistoryWalk = .{ .node = start, .filter = request.filter };
    var n: usize = 0;
    var len: usize = 0;
    var last: ?*Row = null;
    while (n < page.limit) : (n += 1) {
        const row = walk.next() orelse break;
        len += runSize(&row.run);
        last = row;
    }
    const full = n == page.limit;
    if (full) len += std.fmt.count("{d}/{d}", .{ last.?.order.key.ms, last.?.seq });
    const runs = try a.alloc(record.Run, n);
    errdefer a.free(runs);
    var out: Out = .{ .bytes = try a.alloc(u8, len) };
    walk = .{ .node = start, .filter = request.filter };
    for (runs) |*run| run.* = copyRun(&walk.next().?.run, &out);
    const next = if (full) std.fmt.bufPrint(out.bytes[out.used..], "{d}/{d}", .{ last.?.order.key.ms, last.?.seq }) catch unreachable else null;
    return .{ .runs = runs, .next = next };
}

fn parseTimeKey(text: []const u8) ?TimeKey {
    const slash = std.mem.findScalar(u8, text, '/') orelse return null;
    return .{
        .ms = std.fmt.parseInt(i64, text[0..slash], 10) catch return null,
        .seq = std.fmt.parseInt(u64, text[slash + 1 ..], 10) catch return null,
    };
}

/// The rows of a filter, the newest first, from a node on.
const HistoryWalk = struct {
    node: ?*Times.Node,
    filter: record.HistoryFilter,

    fn next(w: *HistoryWalk) ?*Row {
        while (w.node) |node| {
            w.node = node.prev();
            const row = rowOf("order", node);
            const run = &row.run;
            if (w.filter.job) |job| if (!std.mem.eql(u8, job, run.job)) continue;
            if (w.filter.key) |key| if (!std.mem.eql(u8, key, run.key)) continue;
            if (w.filter.tenant) |tenant| if (!std.mem.eql(u8, tenant, run.tenant orelse continue)) continue;
            if (w.filter.outcome) |outcome| if (outcome != run.outcome) continue;
            return row;
        }
        return null;
    }
};

/// The first rule of the indexes that the records and rows break, for the
/// tests; null when they keep them all.
pub fn check(t: *Table) ?[]const u8 {
    var finished: u32 = 0;
    var waking: usize = 0;
    var node = t.records.getMin();
    while (node) |n| : (node = n.next()) {
        const e = entryOf("by_ref", n);
        const r = &e.rec;
        if (!std.mem.eql(u8, n.key.job, r.job) or !std.mem.eql(u8, n.key.key, r.key)) return "a record under another key";
        if ((r.state == .running) != (r.owner != null and r.claimed_at != null and r.lease_until != null))
            return "a running record without its owner, claim and lease, or another one with them";
        if ((r.state == .pending or r.state == .paused) != (r.run_at != null)) return "run_at on a record that neither waits nor is paused";
        const wake: ?Instant = switch (r.state) {
            .pending => r.run_at,
            .running => r.lease_until,
            .paused, .succeeded, .failed => null,
        };
        if ((wake != null) != linked(&e.wake)) return "the index of claims and the state disagree";
        if (wake) |w| {
            if (e.wake.key.ms != w.unix_ms) return "a record in the index of claims at another time";
            waking += 1;
        }
        if (isFinished(r.state) != linked(&e.finished) or isFinished(r.state) != (r.finished_at != null))
            return "a finished record without finished_at or out of its index, or another one in it";
        if ((r.expires_at != null) != linked(&e.expiring)) return "expires_at and its index disagree";
        if (isFinished(r.state)) finished += 1;
    }
    if (finished != t.finished_count or finished > t.max_finished) return "the count of finished records";
    var wakes: usize = 0;
    var wake = t.wake.getMin();
    while (wake) |n| : (wake = n.next()) wakes += 1;
    if (wakes != waking) return "the index of claims holds records that it should not";
    var rows: u32 = 0;
    var row = t.rows.getMin();
    while (row) |n| : (row = n.next()) rows += 1;
    if (rows != t.row_count or rows > t.max_history) return "the count of rows";
    return null;
}

fn optionalLen(text: ?[]const u8) usize {
    return if (text) |x| x.len else 0;
}

fn runSize(run: *const record.Run) usize {
    return run.job.len + run.key.len + run.instance.len + optionalLen(run.tenant) + optionalLen(run.error_name);
}

fn copyRun(run: *const record.Run, out: *Out) record.Run {
    var copy = run.*;
    copy.job = out.text(run.job);
    copy.key = out.text(run.key);
    copy.tenant = out.optional(run.tenant);
    copy.error_name = out.optional(run.error_name);
    copy.instance = out.text(run.instance);
    return copy;
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
