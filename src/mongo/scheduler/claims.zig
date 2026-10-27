//! The claims of `mongo.SchedulerStore` as the worker of zefir-scheduler
//! makes them: claim, renew and finish.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const core = @import("core");
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const SchedulerStore = @import("../SchedulerStore.zig");
const Call = @import("Call.zig");
const Clock = @import("Clock.zig");
const documents = @import("documents.zig");
const records = @import("records.zig");
const Store = scheduler.Store;
const StoreError = Store.StoreError;

const log = std.log.scoped(.mongo);

const by_wake = bson.literal(.{ .wake_at = 1 });

/// Claims one record per findAndModify, the oldest due first, until `max`
/// or none is left; the k-th carries the tag "<tag>-<k>". With fewer than
/// `max`, one aggregation by the same branches says when the next is due.
pub fn claim(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) StoreError!Store.ClaimResult {
    var c: Call = .init(s, io, ctx, options, "claim");
    defer c.deinit();
    try c.check();
    if (request.max == 0) return c.invalid("claim: max is 1 or more", .{});
    if (request.any_key.len == 0 and request.keyed_only.len == 0) return .{ .claimed = &.{}, .next_in = null };
    const branches = branchesOf(c.a(), request) catch |err| return c.built(err);
    // The range bounds the index on any server; $expr is exact by the
    // server's clock (8.5 of the design).
    const hi = s.clock.now(io).add(.fromSeconds(2));
    const filter = claimFilter(c.a(), branches, hi) catch |err| return c.built(err);
    var taken: std.ArrayList(documents.Read) = .empty;
    var ended = false;
    var k: u32 = 1;
    while (taken.items.len < request.max) : (k += 1) {
        const tag = try std.fmt.allocPrint(c.a(), "{s}-{d}", .{ &documents.hex(request.tag), k });
        const stage = claimStage(c.a(), request.owner, tag, documents.millis(request.lease)) catch |err| return c.built(err);
        const before = Clock.local(io);
        var refusal: ?bson.OwnedDocument = null;
        const options_: mongo.Collection.FindOneAndUpdateOptions = .{ .allocator = c.a(), .sort = by_wake, .return_document = .after, .write_concern = s.write_concern, .diagnostics = &c.md, .failure_reply = &refusal };
        // A reply that waited for a write concern it did not get says
        // little of the server's clock.
        var timed = true;
        const doc: ?bson.RawDocument = if (c.jobs().findOneAndUpdate(io, c.op(), filter, &[_]bson.RawDocument{stage}, options_)) |found|
            (if (found) |d| d.raw() else null)
        else |err| doc: {
            // Without its write concern, the claim ran, and its reply holds
            // what it took.
            const modified = Call.modifiedUnconfirmed(refusal) orelse {
                if (try claimLost(&c, request.owner, tag, err, taken.items.len)) |read| try taken.append(c.a(), read);
                ended = true;
                break;
            };
            c.ran(err);
            timed = false;
            break :doc modified.value;
        };
        const read = c.decode(doc orelse break) catch |err| {
            // A record that no longer reads ends the claim; it comes back
            // when its lease ends.
            if (taken.items.len == 0) return err;
            log.warn("SchedulerStore: {s}", .{if (c.d) |x| x.message() else "claim: a claimed record does not read"});
            ended = true;
            break;
        };
        if (timed) if (read.record.claimed_at) |at| s.clock.sample(at, before, Clock.local(io));
        try taken.append(c.a(), read);
    }
    const next_in = if (taken.items.len < request.max and !ended) try nextIn(&c, branches, taken.items.len) else null;
    return .{ .claimed = try claimedOut(c.out, taken.items), .next_in = next_in };
}

/// The k-th findAndModify of a claim failed with `err` after `held`
/// records: the record it may have claimed is the only one with its tag.
/// Found, it is claimed; else the claim ends, an error when it holds none.
fn claimLost(c: *Call, owner: []const u8, tag: []const u8, err: mongo.Error, held: usize) StoreError!?documents.Read {
    switch (Call.classOf(err)) {
        .not_sent => {
            try endsClaim(held, c.nothing(err));
            return null;
        },
        .memory => return error.OutOfMemory,
        .answered, .no_reply => {},
    }
    var md: mongo.Diagnostics = .{};
    const doc = c.jobs().findOne(c.io, c.op(), .{ .owner = owner, .tag = tag, .state = "running" }, .{ .allocator = c.a(), .diagnostics = &md }) catch |e| {
        try endsClaim(held, c.unknown(err, e));
        return null;
    };
    if (doc) |found| {
        c.ran(err);
        const read = c.decode(found.raw()) catch |e| {
            try endsClaim(held, e);
            return null;
        };
        return read;
    }
    try endsClaim(held, if (Call.classOf(err) == .answered) c.refused(err) else c.unknown(err, null));
    return null;
}

/// An error that ends a claim fails it only when it holds no record yet.
fn endsClaim(held: usize, err: StoreError) StoreError!void {
    if (held == 0) return err;
}

/// `$or` of the claim: the jobs of `any_key` with any key, those of
/// `keyed_only` with a key that is not "" (A11).
fn branchesOf(a: std.mem.Allocator, request: *const Store.ClaimRequest) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    for ([_][]const []const u8{ request.any_key, request.keyed_only }, [_]bool{ false, true }, [_][]const u8{ "0", "1" }) |jobs, keyed, index| {
        if (jobs.len == 0) continue;
        try b.beginDocument(if (request.any_key.len == 0) "0" else index);
        try b.beginDocument("job");
        try b.put("$in", jobs);
        try b.end();
        if (keyed) {
            try b.beginDocument("key");
            try b.putString("$ne", "");
            try b.end();
        }
        try b.end();
    }
    return (try b.finish()).raw();
}

fn claimFilter(a: std.mem.Allocator, branches: bson.RawDocument, hi: scheduler.Instant) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putArray("$or", branches);
    try b.put("state", .{ .@"$in" = .{ "pending", "running" } });
    try b.beginDocument("wake_at");
    try documents.putDate(&b, "$lte", hi);
    try b.end();
    try b.put("$expr", .{ .@"$lte" = .{ "$wake_at", "$$NOW" } });
    return (try b.finish()).raw();
}

/// `{$set: …}` of a claim: running, the owner, the tag, attempt and fence
/// one more, the claim and its lease from `$$NOW`, `claim`, the attempt
/// and the moment it gives the run, which a change of the client leaves,
/// and `prev`, the claim of an expired lease that it takes over.
fn claimStage(a: std.mem.Allocator, owner: []const u8, tag: []const u8, lease_ms: i64) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("$set");
    try b.put("prev", .{ .@"$cond" = .{
        .{ .@"$eq" = .{ "$state", "running" } },
        .{ .owner = "$owner", .claimed_at = "$claimed_at", .attempt = "$claim.attempt", .scheduled_at = "$claim.scheduled_at" },
        "$$REMOVE",
    } });
    try b.put("claim", .{ .attempt = .{ .@"$add" = .{ "$attempt", 1 } }, .scheduled_at = "$scheduled_at" });
    try b.putString("state", "running");
    try documents.putLiteral(&b, "owner", owner);
    try b.putString("tag", tag);
    try b.put("attempt", .{ .@"$add" = .{ "$attempt", 1 } });
    try b.put("fence", .{ .@"$add" = .{ "$fence", @as(i64, 1) } });
    try b.putString("claimed_at", "$$NOW");
    try documents.putFromNow(&b, "lease_until", .fromMilliseconds(lease_ms));
    try documents.putFromNow(&b, "wake_at", .fromMilliseconds(lease_ms));
    try b.putString("run_at", "$$REMOVE");
    try b.end();
    return (try b.finish()).raw();
}

/// How soon the nearest record of the branches may be claimed, by the
/// server's clock, which it gives too. An error after records were
/// claimed leaves the claim as it is, without `next_in`.
fn nextIn(c: *Call, branches: bson.RawDocument, held: usize) StoreError!?Duration {
    const match = matchOf(c.a(), branches) catch |err| return c.built(err);
    const project = bson.literal(.{ .@"$project" = .{ ._id = 0, .in_ms = .{ .@"$subtract" = .{ "$wake_at", "$$NOW" } }, .now = "$$NOW" } });
    const pipeline = .{ match, bson.literal(.{ .@"$sort" = .{ .wake_at = 1 } }), bson.literal(.{ .@"$limit" = 1 }), project };
    const before = Clock.local(c.io);
    var cursor = c.jobs().aggregate(c.io, c.op(), pipeline, .{ .allocator = c.a(), .diagnostics = &c.md }) catch |err| {
        try endsClaim(held, c.nothing(err));
        return null;
    };
    defer cursor.deinit(c.io);
    const doc = (cursor.next(c.io, c.op()) catch |err| {
        c.md = cursor.diagnostics().*;
        try endsClaim(held, c.nothing(err));
        return null;
    }) orelse return null;
    const after = Clock.local(c.io);
    const in_ms = (doc.get("in_ms") catch null) orelse return null;
    const ms = in_ms.asI64() catch return null;
    if (doc.get("now") catch null) |now| if (now == .date_time) c.store.clock.sample(.fromUnixMs(now.date_time.milliseconds), before, after);
    return .fromMilliseconds(ms);
}

/// `{$match: {$or: <branches>, wake_at: {$exists: true}}}`.
fn matchOf(a: std.mem.Allocator, branches: bson.RawDocument) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("$match");
    try b.putArray("$or", branches);
    try b.put("wake_at", .{ .@"$exists" = true });
    try b.end();
    return (try b.finish()).raw();
}

/// The claimed records and whose they were, in the caller's memory: one
/// allocation for the list, one for the strings.
fn claimedOut(a: std.mem.Allocator, taken: []const documents.Read) std.mem.Allocator.Error![]const Store.Claimed {
    var size: usize = 0;
    for (taken) |read| size += documents.recordSize(&read.record) + if (read.took_over) |over| over.owner.len else 0;
    const claimed = try a.alloc(Store.Claimed, taken.len);
    errdefer a.free(claimed);
    var out: documents.Out = .{ .bytes = try a.alloc(u8, size) };
    for (claimed, taken) |*c, read| c.* = .{
        .record = documents.copyRecord(&read.record, &out),
        .took_over = if (read.took_over) |over| .{ .owner = out.text(over.owner), .claimed_at = over.claimed_at, .attempt = over.attempt, .scheduled_at = over.scheduled_at } else null,
    };
    return claimed;
}

/// Renews the lease on condition of the claim, `(life, owner, fence)`, and
/// takes the server's time from it. A renew whose reply did not tell goes
/// once more: its condition is the same.
pub fn renew(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.RenewRequest, options: Store.CallOptions) StoreError!Store.RenewResult {
    var c: Call = .init(s, io, ctx, options, "renew");
    defer c.deinit();
    try c.check();
    const fence = std.math.cast(i64, request.fence) orelse return c.invalid("renew: a fence is at most 2^63 - 1", .{});
    const id = (try c.id(request.ref)) orelse return .removed;
    const life = documents.hex(request.life);
    const filter = .{ ._id = id, .life = &life, .owner = request.owner, .fence = fence, .state = "running" };
    const stage = leaseStage(c.a(), request.lease) catch |err| return c.built(err);
    return renewOnce(&c, id, &life, filter, stage, request.lease) catch |err| {
        switch (Call.classOf(err)) {
            .not_sent => return c.nothing(err),
            .memory => return error.OutOfMemory,
            .answered, .no_reply => {},
        }
        return renewOnce(&c, id, &life, filter, stage, request.lease) catch |again| c.unknown(err, again);
    };
}

/// `{$set: {lease_until, wake_at}}`, `lease` from `$$NOW`.
fn leaseStage(a: std.mem.Allocator, lease: Duration) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("$set");
    try documents.putFromNow(&b, "lease_until", lease);
    try documents.putFromNow(&b, "wake_at", lease);
    try b.end();
    return (try b.finish()).raw();
}

fn renewOnce(c: *Call, id: []const u8, life: []const u8, filter: anytype, stage: bson.RawDocument, lease: Duration) mongo.Error!Store.RenewResult {
    const before = Clock.local(c.io);
    var refusal: ?bson.OwnedDocument = null;
    const options: mongo.Collection.FindOneAndUpdateOptions = .{ .allocator = c.a(), .projection = bson.literal(.{ .lease_until = 1 }), .return_document = .after, .write_concern = c.store.write_concern, .diagnostics = &c.md, .failure_reply = &refusal };
    const found = c.jobs().findOneAndUpdate(c.io, c.op(), filter, &[_]bson.RawDocument{stage}, options) catch |err| found: {
        // Without its write concern, the renewal ran, and its reply says
        // whether it held.
        const modified = Call.modifiedUnconfirmed(refusal) orelse return err;
        c.ran(err);
        if (modified.value != null) return .renewed;
        break :found null;
    };
    if (found) |doc| {
        if (doc.raw().get("lease_until") catch null) |until| if (until == .date_time)
            c.store.clock.sample(scheduler.Instant.fromUnixMs(until.date_time.milliseconds).add(.fromNanoseconds(-lease.nanoseconds)), before, Clock.local(c.io));
        return .renewed;
    }
    // Not this claim: the record is gone or of another life, or another
    // claim holds it.
    const now = (try c.jobs().findOne(c.io, c.op(), .{ ._id = id }, .{ .allocator = c.a(), .projection = bson.literal(.{ .life = 1 }), .diagnostics = &c.md })) orelse return .removed;
    const same = if (now.raw().get("life") catch null) |value| value == .string and std.mem.eql(u8, value.string, life) else false;
    return if (same) .lost else .removed;
}

/// Writes the rows of the history, then the transition on condition of
/// the whole claim and the revision; `delete` removes the record so.
pub fn finish(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) StoreError!Store.FinishResult {
    var c: Call = .init(s, io, ctx, options, "finish");
    defer c.deinit();
    try c.check();
    switch (request.next) {
        .wait => |wait| if (wait.state != .pending and wait.state != .paused)
            return c.invalid("finish: a job waits pending or paused, not {t}", .{wait.state}),
        .done => |done| {
            if (done.state != .succeeded and done.state != .failed) return c.invalid("finish: a job is done succeeded or failed, not {t}", .{done.state});
            if (done.keep == .none) return c.invalid("finish: done keeps the record for a time or always; drop it with .delete", .{});
        },
        .delete => {},
    }
    const fence = std.math.cast(i64, request.fence) orelse return c.invalid("finish: a fence is at most 2^63 - 1", .{});
    const revision = std.math.cast(i64, request.revision) orelse return c.invalid("finish: a revision is at most 2^63 - 1", .{});
    if (request.history.keep != .none) for (request.history.runs) |*run| try writeRow(&c, run, request.history.keep);
    const id = (try c.id(request.ref)) orelse return .lost;
    const life = documents.hex(request.life);
    const filter = .{ ._id = id, .life = &life, .owner = request.owner, .fence = fence, .revision = revision, .state = "running" };
    // Without its write concern, the transition ran, and its reply says
    // whether it held.
    const applied = if (request.next == .delete) applied: {
        var known: mongo.Collection.DeleteResult = .{};
        const result = c.jobs().deleteOne(io, c.op(), filter, .{ .allocator = c.a(), .write_concern = s.write_concern, .diagnostics = &c.md, .partial = &known }) catch |err| result: {
            if (!Call.ranUnconfirmed(known)) return finishLost(&c, id, request, err);
            c.ran(err);
            break :result known;
        };
        break :applied result.deleted > 0;
    } else applied: {
        const stages = transitionStages(c.a(), request) catch |err| return c.built(err);
        var known: mongo.Collection.UpdateResult = .{};
        const result = c.jobs().updateOne(io, c.op(), filter, stages, .{ .allocator = c.a(), .write_concern = s.write_concern, .diagnostics = &c.md, .partial = &known }) catch |err| result: {
            if (!Call.ranUnconfirmed(known)) return finishLost(&c, id, request, err);
            c.ran(err);
            break :result known;
        };
        break :applied result.matched > 0;
    };
    if (applied) return .done;
    const now = (c.read(id, &c.md) catch |err| return records.readFailed(&c, err)) orelse return .lost;
    if (!ours(now.record, request)) return .lost;
    return .{ .changed = try documents.recordOut(c.out, &now.record) };
}

/// Our tag: applied; no record after a `delete`: done (A48); our claim at
/// its revision: not applied; else another claim or a change came first.
fn finishLost(c: *Call, id: []const u8, request: *const Store.FinishRequest, err: mongo.Error) StoreError!Store.FinishResult {
    switch (Call.classOf(err)) {
        .not_sent => return c.nothing(err),
        .memory => return error.OutOfMemory,
        .answered, .no_reply => {},
    }
    var md: mongo.Diagnostics = .{};
    const now = (c.read(id, &md) catch |e| return c.unknown(err, e)) orelse {
        if (request.next != .delete) return .lost;
        c.ran(err);
        return .done;
    };
    if (records.sameTag(now.tag, request.tag)) {
        c.ran(err);
        return .done;
    }
    if (!ours(now.record, request)) return .lost;
    if (now.record.revision != request.revision) return .{ .changed = try documents.recordOut(c.out, &now.record) };
    return if (Call.classOf(err) == .answered) c.refused(err) else c.unknown(err, null);
}

/// The record is running under the claim of `request`.
fn ours(r: scheduler.Record, request: *const Store.FinishRequest) bool {
    return r.state == .running and r.fence == request.fence and std.mem.eql(u8, &r.life, &request.life) and std.mem.eql(u8, r.owner orelse "", request.owner);
}

/// `[{$set: …}, {$unset: […]}]` of a transition: the new state with its
/// times from `$$NOW`, the tag, `last`, and `wake_at` by the new state;
/// then the fields of the claim and `pause_requested` go.
fn transitionStages(a: std.mem.Allocator, request: *const Store.FinishRequest) bson.Builder.Error![2]bson.RawDocument {
    var unset: std.ArrayList([]const u8) = .empty;
    try unset.appendSlice(a, &.{ "owner", "claimed_at", "lease_until", "claim", "prev", "pause_requested" });
    var b: bson.Builder = .init(a);
    try b.beginDocument("$set");
    try b.putString("tag", &documents.hex(request.tag));
    if (request.last) |last| {
        // An operator, so that the old `last` goes whole.
        try b.beginDocument("last");
        try b.beginArray("$mergeObjects");
        try b.beginDocument("");
        try b.putString("outcome", @tagName(last.outcome));
        if (last.error_name) |name| try documents.putLiteral(&b, "error", name);
        try putCount(&b, "attempt", last.attempt);
        try documents.putDate(&b, "started_at", last.started_at);
        try b.putString("finished_at", "$$NOW");
        try b.end();
        try b.end();
        try b.end();
    }
    switch (request.next) {
        .wait => |wait| {
            try b.putString("state", @tagName(wait.state));
            try documents.putMoment(&b, "run_at", wait.run_at);
            if (wait.scheduled_at) |at| try documents.putDate(&b, "scheduled_at", at) else try documents.putMoment(&b, "scheduled_at", wait.run_at);
            try putCount(&b, "attempt", wait.attempt);
            if (wait.unreadable_since) |at| try documents.putDate(&b, "unreadable_since", at) else try unset.append(a, "unreadable_since");
            if (wait.state == .pending) try documents.putMoment(&b, "wake_at", wait.run_at) else try unset.append(a, "wake_at");
        },
        .done => |done| {
            try b.putString("state", @tagName(done.state));
            try b.putString("finished_at", "$$NOW");
            switch (done.keep) {
                .keep_for => |d| try documents.putFromNow(&b, "expires_at", d),
                else => try unset.append(a, "expires_at"),
            }
            try unset.appendSlice(a, &.{ "run_at", "unreadable_since", "wake_at" });
        },
        .delete => unreachable,
    }
    try b.end();
    const set = (try b.finish()).raw();
    try b.put("$unset", unset.items);
    return .{ set, (try b.finish()).raw() };
}

/// An attempt as an Int32, an Int64 past it.
fn putCount(b: *bson.Builder, key: []const u8, n: u32) bson.Builder.Error!void {
    if (std.math.cast(i32, n)) |small| return b.putInt32(key, small);
    return b.putInt64(key, n);
}

/// The row of `run`: `_id` "<life>/<fence>", written unless the row is
/// there, but for the owner's row over an abandoned one (A15). A unique
/// key error is a row that a concurrent write made: it is there; so is one
/// written without its write concern.
fn writeRow(c: *Call, run: *const scheduler.Run, keep: scheduler.Retention) StoreError!void {
    const row_id = try std.fmt.allocPrint(c.a(), "{s}/{d}", .{ &documents.hex(run.life), run.fence });
    const stage = rowStage(c.a(), run, keep) catch |err| return c.built(err);
    var known: mongo.Collection.UpdateResult = .{};
    _ = c.runs().updateOne(c.io, c.op(), .{ ._id = row_id }, &[_]bson.RawDocument{stage}, .{ .allocator = c.a(), .upsert = true, .write_concern = c.store.write_concern, .diagnostics = &c.md, .partial = &known }) catch |err| {
        if (Call.code(&c.md)) |code| if (code == 11000) return;
        // Without its write concern, the row is there all the same.
        if (Call.ranUnconfirmed(known)) return c.ran(err);
        // The transition did not go out: the record is as it was.
        return c.nothing(err);
    };
}

const no_row = bson.literal(.{ .@"$eq" = .{ .{ .@"$type" = "$job" }, "missing" } });
const no_row_or_abandoned = bson.literal(.{ .@"$or" = .{
    .{ .@"$eq" = .{ .{ .@"$type" = "$job" }, "missing" } },
    .{ .@"$eq" = .{ "$outcome", "abandoned" } },
} });

fn rowStage(a: std.mem.Allocator, run: *const scheduler.Run, keep: scheduler.Retention) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("$replaceWith");
    try b.beginArray("$cond");
    try b.putDocument("", if (run.outcome == .abandoned) no_row else no_row_or_abandoned);
    try b.beginDocument("");
    try b.putString("_id", "$_id");
    try documents.putLiteral(&b, "job", run.job);
    try documents.putLiteral(&b, "key", run.key);
    if (run.tenant) |tenant| try documents.putLiteral(&b, "tenant", tenant);
    try b.putString("life", &documents.hex(run.life));
    try b.putInt64("fence", std.math.cast(i64, run.fence) orelse std.math.maxInt(i64));
    try putCount(&b, "attempt", run.attempt);
    try documents.putDate(&b, "scheduled_at", run.scheduled_at);
    try documents.putDate(&b, "started_at", run.started_at);
    try b.putString("finished_at", "$$NOW");
    try b.putString("outcome", @tagName(run.outcome));
    if (run.error_name) |name| try documents.putLiteral(&b, "error", name);
    try documents.putLiteral(&b, "instance", run.instance);
    if (keep == .keep_for) try documents.putFromNow(&b, "expires_at", keep.keep_for);
    try b.end();
    try b.putString("", "$$ROOT");
    try b.end();
    try b.end();
    return (try b.finish()).raw();
}
