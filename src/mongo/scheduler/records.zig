//! The records of `mongo.SchedulerStore` as the client of zefir-scheduler
//! changes them: create, get, update, remove, list and history.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const SchedulerStore = @import("../SchedulerStore.zig");
const Call = @import("Call.zig");
const documents = @import("documents.zig");
const Store = scheduler.Store;
const StoreError = Store.StoreError;
const State = scheduler.State;
const Record = scheduler.Record;

/// Creates the record in one upsert whose pipeline keeps a live record as
/// it is and replaces a finished one, so that the three cases are atomic.
pub fn create(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) StoreError!Store.CreateResult {
    var c: Call = .init(s, io, ctx, options, "create");
    defer c.deinit();
    try c.check();
    if (!documents.validJobName(request.job))
        return c.invalid("create: a job name is 1–64 bytes of a-z, 0-9, '-', '_' and '.', starting with a letter or a digit", .{});
    if (request.key.len != 0 and !documents.validText(request.key, 256)) return c.invalid("create: a key is 1–256 bytes of UTF-8 without NUL", .{});
    if (request.tenant) |tenant| if (!documents.validText(tenant, 128)) return c.invalid("create: a tenant is 1–128 bytes of UTF-8 without NUL", .{});
    const id = (try c.id(.{ .job = request.job, .key = request.key })).?;
    const stage = createStage(c.a(), request) catch |err| return c.built(err);
    const result = upsert(&c, id, stage) catch |err| return createLost(&c, id, stage, request, err);
    return createdBy(result);
}

fn upsert(c: *Call, id: []const u8, stage: bson.RawDocument) mongo.Error!mongo.Collection.UpdateResult {
    return c.jobs().updateOne(c.io, c.op(), .{ ._id = id }, &[_]bson.RawDocument{stage}, .{ .allocator = c.a(), .upsert = true, .write_concern = c.store.write_concern, .diagnostics = &c.md });
}

fn createdBy(result: mongo.Collection.UpdateResult) Store.CreateResult {
    if (result.upserted_id != null) return .created;
    return if (result.modified > 0) .replaced else .existing;
}

/// A record of our life is ours; a live one of another is `existing`; else
/// an upsert without a reply goes once more, as it makes only our life.
fn createLost(c: *Call, id: []const u8, stage: bson.RawDocument, request: *const Store.CreateRequest, err: mongo.Error) StoreError!Store.CreateResult {
    switch (Call.classOf(err)) {
        .not_sent => return c.nothing(err),
        .memory => return error.OutOfMemory,
        .answered, .no_reply => {},
    }
    var md: mongo.Diagnostics = .{};
    if (c.read(id, &md) catch |e| return c.unknown(err, e)) |now| {
        if (std.mem.eql(u8, &now.record.life, &request.life)) {
            c.ran(err);
            return .created;
        }
        if (live(now.record.state)) return .existing;
    }
    if (Call.classOf(err) == .answered) return c.refused(err);
    const again = upsert(c, id, stage) catch |e| return c.unknown(err, e);
    if (createdBy(again) != .existing) return createdBy(again);
    // The first upsert may have come in between.
    const now = (c.read(id, &md) catch |e| return c.unknown(err, e)) orelse return c.unknown(err, null);
    return if (std.mem.eql(u8, &now.record.life, &request.life)) .created else .existing;
}

fn live(state: State) bool {
    return state == .pending or state == .running or state == .paused;
}

/// The condition of a new record: none, or a finished one.
const vacant = bson.literal(.{ .@"$or" = .{
    .{ .@"$eq" = .{ .{ .@"$type" = "$job" }, "missing" } },
    .{ .@"$in" = .{ "$state", .{ "succeeded", "failed" } } },
} });

/// `{$replaceWith: {$cond: [vacant, <record>, "$$ROOT"]}}`, the strings in
/// `$literal`, the times from `$$NOW`.
fn createStage(a: std.mem.Allocator, request: *const Store.CreateRequest) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("$replaceWith");
    try b.beginArray("$cond");
    try b.putDocument("", vacant);
    try b.beginDocument("");
    try b.putString("_id", "$_id");
    try documents.putLiteral(&b, "job", request.job);
    try documents.putLiteral(&b, "key", request.key);
    if (request.tenant) |tenant| try documents.putLiteral(&b, "tenant", tenant);
    try b.putString("life", &documents.hex(request.life));
    try documents.putLiteral(&b, "plan", request.plan);
    try documents.putLiteral(&b, "payload", request.payload);
    if (request.trace) |trace| try documents.putLiteral(&b, "trace", trace);
    try b.putString("state", "pending");
    for ([_][]const u8{ "scheduled_at", "run_at", "wake_at" }) |field| try documents.putMoment(&b, field, request.run_at);
    try b.putInt32("attempt", 0);
    try b.putInt64("fence", 0);
    try b.putInt64("revision", 0);
    try b.putString("created_at", "$$NOW");
    try b.putString("updated_at", "$$NOW");
    try b.end();
    try b.putString("", "$$ROOT");
    try b.end();
    try b.end();
    return (try b.finish()).raw();
}

pub fn get(s: *SchedulerStore, io: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!?Record {
    var c: Call = .init(s, io, ctx, options, "get");
    defer c.deinit();
    try c.check();
    const id = (try c.id(ref.*)) orelse return null;
    const doc = c.jobs().findOne(io, c.op(), .{ ._id = id }, .{ .allocator = c.a(), .diagnostics = &c.md }) catch |err| return c.nothing(err);
    return try c.record((doc orelse return null).raw());
}

/// Changes the record on condition of its life, revision and state, in one
/// pipeline: a plain update has no `$$NOW`.
pub fn update(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) StoreError!Store.UpdateResult {
    var c: Call = .init(s, io, ctx, options, "update");
    defer c.deinit();
    try c.check();
    try checkPatch(&c, request);
    const revision = std.math.cast(i64, request.expect.revision) orelse return c.invalid("update: a revision is at most 2^63 - 1", .{});
    const id = (try c.id(request.ref)) orelse return .not_found;
    const stage = updateStage(c.a(), request) catch |err| return c.built(err);
    const life = documents.hex(request.expect.life);
    const filter = .{ ._id = id, .life = &life, .revision = revision, .state = @tagName(request.expect.state) };
    const result = c.jobs().updateOne(io, c.op(), filter, &[_]bson.RawDocument{stage}, .{ .allocator = c.a(), .write_concern = s.write_concern, .diagnostics = &c.md }) catch |err|
        return updateLost(&c, request, id, err);
    if (result.matched > 0) return .{ .updated = request.expect.revision + 1 };
    const now = (c.read(id, &c.md) catch |err| return readFailed(&c, err)) orelse return .not_found;
    return .{ .conflict = try documents.recordOut(c.out, &now.record) };
}

/// After a definite answer, an error of the read that tells the rest.
pub fn readFailed(c: *Call, err: (mongo.Error || documents.ReadError)) StoreError {
    return switch (err) {
        error.Corrupt => error.Corrupt,
        error.OutOfMemory => error.OutOfMemory,
        else => |e| c.nothing(@errorCast(e)),
    };
}

/// Our tag: applied. A record of another life: never applied, as the
/// filter holds the life. The same life at the revision expected: not
/// applied, since the change raises it; as expected in its state too, it
/// was refused or may still arrive. Past that revision under another tag:
/// the change may have applied and a claim, a finish or another change
/// written over its tag since, which the store cannot tell from another
/// change that came first.
fn updateLost(c: *Call, request: *const Store.UpdateRequest, id: []const u8, err: mongo.Error) StoreError!Store.UpdateResult {
    switch (Call.classOf(err)) {
        .not_sent => return c.nothing(err),
        .memory => return error.OutOfMemory,
        .answered, .no_reply => {},
    }
    var md: mongo.Diagnostics = .{};
    const now = (c.read(id, &md) catch |e| return c.unknown(err, e)) orelse return .not_found;
    if (sameTag(now.tag, request.tag)) {
        c.ran(err);
        return .{ .updated = request.expect.revision + 1 };
    }
    if (std.mem.eql(u8, &now.record.life, &request.expect.life)) {
        if (now.record.revision > request.expect.revision) return c.unknown(err, null);
        if (now.record.revision == request.expect.revision and now.record.state == request.expect.state)
            return if (Call.classOf(err) == .answered) c.refused(err) else c.unknown(err, null);
    }
    return .{ .conflict = try documents.recordOut(c.out, &now.record) };
}

pub fn sameTag(text: ?[]const u8, tag: Store.Tag) bool {
    return std.mem.eql(u8, text orelse return false, &documents.hex(tag));
}

/// The state after the patch.
fn nextState(request: *const Store.UpdateRequest) State {
    return request.set.state orelse if (request.set.reset) .pending else request.expect.state;
}

fn waits(state: State) bool {
    return state == .pending or state == .paused;
}

fn finished(state: State) bool {
    return state == .succeeded or state == .failed;
}

/// The rules of a patch, by the state it expects: the record changes only
/// when it is in that state.
fn checkPatch(c: *Call, request: *const Store.UpdateRequest) error{InvalidArgument}!void {
    const set = request.set;
    const expect = request.expect.state;
    if (set.state) |state| if (!waits(state)) return c.invalid("update: a patch makes a record pending or paused, not {t}", .{state});
    if (expect == .running and (set.state != null or set.reset)) return c.invalid("update: a running record changes its state only by its claim", .{});
    const next = nextState(request);
    const has_run_at = waits(expect) or set.reset or (set.run_at != null and next != .running);
    if (waits(next) and !has_run_at) return c.invalid("update: a pending or paused record needs a run_at: set run_at, or reset", .{});
    if (finished(next) and set.run_at != null) return c.invalid("update: a finished record has no run_at: make it pending or paused too", .{});
}

/// `{$set: …}`: revision + 1, the tag, `updated_at`, the fields of the
/// patch, and `wake_at` by the state after it: `run_at` of a pending
/// record, none of a paused or finished one, the lease of a running one.
fn updateStage(a: std.mem.Allocator, request: *const Store.UpdateRequest) bson.Builder.Error!bson.RawDocument {
    const set = request.set;
    const next = nextState(request);
    var b: bson.Builder = .init(a);
    try b.beginDocument("$set");
    try b.beginDocument("revision");
    try b.beginArray("$add");
    try b.putString("", "$revision");
    try b.putInt64("", 1);
    try b.end();
    try b.end();
    try b.putString("tag", &documents.hex(request.tag));
    try b.putString("updated_at", "$$NOW");
    if (set.state != null or set.reset) try b.putString("state", @tagName(next));
    if (set.plan) |plan| try documents.putLiteral(&b, "plan", plan);
    if (set.pause_requested) |asked| {
        if (asked) try putTrue(&b, "pause_requested") else try b.putString("pause_requested", "$$REMOVE");
    }
    if (set.run_at) |moment| {
        try documents.putMoment(&b, "scheduled_at", moment);
        if (next != .running) try documents.putMoment(&b, "run_at", moment);
    } else if (set.reset) try b.putString("run_at", "$$NOW");
    if (set.run_at != null or set.reset) try b.putInt32("attempt", 0);
    if (set.reset) try b.putString("unreadable_since", "$$REMOVE");
    if (finished(request.expect.state) and !finished(next)) {
        try b.putString("finished_at", "$$REMOVE");
        try b.putString("expires_at", "$$REMOVE");
    }
    switch (next) {
        .pending => if (set.run_at) |moment| try documents.putMoment(&b, "wake_at", moment) else try b.putString("wake_at", if (set.reset) "$$NOW" else "$run_at"),
        .running => {},
        .paused, .succeeded, .failed => try b.putString("wake_at", "$$REMOVE"),
    }
    try b.end();
    return (try b.finish()).raw();
}

/// `{key: {$literal: true}}`.
fn putTrue(b: *bson.Builder, key: []const u8) bson.Builder.Error!void {
    try b.beginDocument(key);
    try b.putBoolean("$literal", true);
    try b.end();
}

pub fn remove(s: *SchedulerStore, io: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!bool {
    var c: Call = .init(s, io, ctx, options, "remove");
    defer c.deinit();
    try c.check();
    const id = (try c.id(ref.*)) orelse return false;
    const result = c.jobs().deleteOne(io, c.op(), .{ ._id = id }, .{ .allocator = c.a(), .write_concern = s.write_concern, .diagnostics = &c.md }) catch |err| {
        switch (Call.classOf(err)) {
            .not_sent => return c.nothing(err),
            .memory => return error.OutOfMemory,
            .answered, .no_reply => {},
        }
        var md: mongo.Diagnostics = .{};
        if (c.read(id, &md) catch |e| return c.unknown(err, e)) |_| {
            return if (Call.classOf(err) == .answered) c.refused(err) else c.unknown(err, null);
        }
        c.ran(err);
        return true;
    };
    return result.deleted > 0;
}

/// The records of the filter in the order of their `_id`, "<job>/<key>":
/// the records of a job together, by key. A job is the range of `_id`s
/// from "<job>/" to "<job>0", '0' coming right after '/'. The continuation
/// is the last `_id` of a full page.
pub fn list(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.ListRequest, options: Store.CallOptions) StoreError!scheduler.RecordPage {
    var c: Call = .init(s, io, ctx, options, "list");
    defer c.deinit();
    try c.check();
    const filter = request.filter;
    const page = request.page;
    if (page.limit == 0) return c.invalid("list: a page is 1 or more records", .{});
    if (filter.job) |job| if (!documents.validJobName(job)) return .{ .records = &.{}, .next = null };
    const query = listQuery(c.a(), request) catch |err| return c.built(err);
    var cursor = c.jobs().find(io, c.op(), query, .{ .allocator = c.a(), .sort = bson.literal(.{ ._id = 1 }), .limit = page.limit, .diagnostics = &c.md }) catch |err|
        return c.nothing(err);
    defer cursor.deinit(io);
    var found: std.ArrayList(Record) = .empty;
    var size: usize = 0;
    while (cursor.next(io, c.op()) catch |err| return cursorFailed(&c, cursor, err)) |doc| {
        // A copy in the scratch: the batch goes with the next one.
        const rec = try documents.recordOut(c.a(), &(try c.decode(doc)).record);
        try found.append(c.a(), rec);
        size += documents.recordSize(&rec);
    }
    const full = found.items.len == page.limit;
    // The continuation: "<job>/<key>" of the last record.
    if (full) size += found.items[found.items.len - 1].job.len + 1 + found.items[found.items.len - 1].key.len;
    const records = try c.out.alloc(Record, found.items.len);
    errdefer c.out.free(records);
    var out: documents.Out = .{ .bytes = try c.out.alloc(u8, size) };
    for (records, found.items) |*r, rec| r.* = documents.copyRecord(&rec, &out);
    return .{ .records = records, .next = if (full) idOf(&out, found.items[found.items.len - 1]) else null };
}

/// "<job>/<key>" of `rec` in `out`.
fn idOf(out: *documents.Out, rec: Record) []const u8 {
    const start = out.used;
    _ = out.text(rec.job);
    _ = out.text("/");
    _ = out.text(rec.key);
    return out.bytes[start..out.used];
}

fn listQuery(a: std.mem.Allocator, request: *const Store.ListRequest) bson.Builder.Error!bson.RawDocument {
    const filter = request.filter;
    var b: bson.Builder = .init(a);
    if (filter.job != null or request.page.after != null) {
        try b.beginDocument("_id");
        if (filter.job) |job| {
            try b.putString("$gte", try std.fmt.allocPrint(a, "{s}/", .{job}));
            try b.putString("$lt", try std.fmt.allocPrint(a, "{s}0", .{job}));
        }
        if (request.page.after) |after| try b.putString("$gt", after);
        try b.end();
    }
    if (filter.tenant) |tenant| try b.putString("tenant", tenant);
    if (filter.state) |state| try b.putString("state", @tagName(state));
    return (try b.finish()).raw();
}

/// An error of `next` of a cursor of a read, with the cursor's details.
fn cursorFailed(c: *Call, cursor: mongo.Cursor, err: mongo.Error) StoreError {
    c.md = cursor.diagnostics().*;
    return c.nothing(err);
}

/// The rows of the filter, the newest first: by `finished_at` and `_id`,
/// both descending. The continuation is "<finished_at in ms>/<_id>" of the
/// last row of a full page.
pub fn history(s: *SchedulerStore, io: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) StoreError!scheduler.RunPage {
    var c: Call = .init(s, io, ctx, options, "history");
    defer c.deinit();
    try c.check();
    const page = request.page;
    if (page.limit == 0) return c.invalid("history: a page is 1 or more rows", .{});
    const query = historyQuery(c.a(), request) catch |err| switch (err) {
        error.Continuation => return c.invalid("history: page.after is no continuation of this store", .{}),
        else => |e| return c.built(e),
    };
    const sort = bson.literal(.{ .finished_at = -1, ._id = -1 });
    var cursor = c.runs().find(io, c.op(), query, .{ .allocator = c.a(), .sort = sort, .limit = page.limit, .diagnostics = &c.md }) catch |err|
        return c.nothing(err);
    defer cursor.deinit(io);
    var found: std.ArrayList(scheduler.Run) = .empty;
    var last_id: []const u8 = "";
    var size: usize = 0;
    while (cursor.next(io, c.op()) catch |err| return cursorFailed(&c, cursor, err)) |doc| {
        var problem: documents.Problem = .{};
        const row = documents.readRun(c.a(), doc, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Corrupt => return c.corrupt(doc, &problem),
        };
        var copy: documents.Out = .{ .bytes = try c.a().alloc(u8, documents.runSize(&row)) };
        try found.append(c.a(), documents.copyRun(&row, &copy));
        size += documents.runSize(&row);
        last_id = if (doc.get("_id") catch null) |value| (if (value == .string) try c.a().dupe(u8, value.string) else "") else "";
    }
    const full = found.items.len == page.limit;
    var next_buffer: [64]u8 = undefined;
    const next: []const u8 = if (full) std.fmt.bufPrint(&next_buffer, "{d}/", .{found.items[found.items.len - 1].finished_at.unix_ms}) catch unreachable else "";
    const runs = try c.out.alloc(scheduler.Run, found.items.len);
    errdefer c.out.free(runs);
    var out: documents.Out = .{ .bytes = try c.out.alloc(u8, size + if (full) next.len + last_id.len else 0) };
    for (runs, found.items) |*r, row| r.* = documents.copyRun(&row, &out);
    if (!full) return .{ .runs = runs, .next = null };
    const start = out.used;
    _ = out.text(next);
    _ = out.text(last_id);
    return .{ .runs = runs, .next = out.bytes[start..out.used] };
}

fn historyQuery(a: std.mem.Allocator, request: *const Store.HistoryRequest) (bson.Builder.Error || error{Continuation})!bson.RawDocument {
    const filter = request.filter;
    var b: bson.Builder = .init(a);
    if (filter.job) |job| try b.putString("job", job);
    if (filter.key) |key| try b.putString("key", key);
    if (filter.tenant) |tenant| try b.putString("tenant", tenant);
    if (filter.outcome) |outcome| try b.putString("outcome", @tagName(outcome));
    if (request.page.after) |after| {
        const slash = std.mem.findScalar(u8, after, '/') orelse return error.Continuation;
        const ms = std.fmt.parseInt(i64, after[0..slash], 10) catch return error.Continuation;
        const row_id = after[slash + 1 ..];
        // Older, or as old with a smaller _id.
        try b.beginArray("$or");
        try b.beginDocument("");
        try b.beginDocument("finished_at");
        try b.putDateTime("$lt", .{ .milliseconds = ms });
        try b.end();
        try b.end();
        try b.beginDocument("");
        try b.putDateTime("finished_at", .{ .milliseconds = ms });
        try b.beginDocument("_id");
        try b.putString("$lt", row_id);
        try b.end();
        try b.end();
        try b.end();
    }
    return (try b.finish()).raw();
}
