//! Tests of the store contract: the table that Store.init builds, and the
//! classes of the errors.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const scheduler = @import("../root.zig");
const Store = scheduler.Store;
const StoreError = scheduler.StoreError;

/// A store that counts the calls of each method and keeps the last request.
const Recorder = struct {
    pub const name = "recorder";

    calls: [10]u32 = @splat(0),
    last_request: ?*const anyopaque = null,
    last_deadline: ?core.Deadline = null,
    last_diagnostics: ?*scheduler.Diagnostics = null,

    fn note(r: *Recorder, method: usize, ctx: core.Context, request: *const anyopaque, options: Store.CallOptions) void {
        r.calls[method] += 1;
        r.last_request = request;
        r.last_deadline = ctx.deadline;
        r.last_diagnostics = options.diagnostics;
    }

    pub fn now(r: *Recorder, io: Io) scheduler.Instant {
        _ = io;
        r.calls[0] += 1;
        return .fromUnixMs(42);
    }
    pub fn create(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) StoreError!Store.CreateResult {
        _ = io;
        r.note(1, ctx, request, options);
        return .replaced;
    }
    pub fn get(r: *Recorder, io: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!?scheduler.Record {
        _ = io;
        r.note(2, ctx, ref, options);
        return error.Corrupt;
    }
    pub fn update(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) StoreError!Store.UpdateResult {
        _ = io;
        r.note(3, ctx, request, options);
        return .{ .updated = 8 };
    }
    pub fn remove(r: *Recorder, io: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) StoreError!bool {
        _ = io;
        r.note(4, ctx, ref, options);
        return true;
    }
    pub fn list(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.ListRequest, options: Store.CallOptions) StoreError!scheduler.RecordPage {
        _ = io;
        r.note(5, ctx, request, options);
        return .{ .records = &.{}, .next = "list-next" };
    }
    pub fn claim(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) StoreError!Store.ClaimResult {
        _ = io;
        r.note(6, ctx, request, options);
        return .{ .claimed = &.{}, .next_in = .fromSeconds(3) };
    }
    pub fn renew(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.RenewRequest, options: Store.CallOptions) StoreError!Store.RenewResult {
        _ = io;
        r.note(7, ctx, request, options);
        return .lost;
    }
    pub fn finish(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) StoreError!Store.FinishResult {
        _ = io;
        r.note(8, ctx, request, options);
        return .done;
    }
    pub fn history(r: *Recorder, io: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) StoreError!scheduler.RunPage {
        _ = io;
        r.note(9, ctx, request, options);
        return .{ .runs = &.{}, .next = "history-next" };
    }
};

test "Store.init routes each wrapper to the method of the type" {
    const io = testing.io;
    var recorder: Recorder = .{};
    const store: Store = .init(&recorder);
    try testing.expectEqualStrings("recorder", store.vtable.name);

    var d: scheduler.Diagnostics = .{};
    const options: Store.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };
    const ctx = core.Context.root.withDeadline(.at(.fromNanoseconds(77)));
    const ref: scheduler.Ref = .{ .job = "send-invoice", .key = "order-42" };
    const life: scheduler.Life = @splat(1);
    const tag: Store.Tag = @splat(2);

    try testing.expectEqual(@as(i64, 42), store.now(io).unix_ms);
    const create: Store.CreateRequest = .{ .job = ref.job, .key = ref.key, .life = life, .plan = "", .payload = "{}", .run_at = .{ .after = .zero } };
    try testing.expectEqual(Store.CreateResult.replaced, try store.create(io, ctx, &create, options));
    try testing.expectEqual(@as(?*const anyopaque, &create), recorder.last_request);
    try testing.expectError(error.Corrupt, store.get(io, ctx, &ref, options));
    try testing.expectEqual(@as(?*const anyopaque, &ref), recorder.last_request);
    const update: Store.UpdateRequest = .{ .ref = ref, .expect = .{ .life = life, .revision = 7, .state = .pending }, .set = .{ .pause_requested = true }, .tag = tag };
    const updated = try store.update(io, ctx, &update, options);
    try testing.expect(updated == .updated and updated.updated == 8);
    try testing.expect(try store.remove(io, ctx, &ref, options));
    const listing: Store.ListRequest = .{ .filter = .{ .job = ref.job }, .page = .{ .limit = 7 } };
    try testing.expectEqualStrings("list-next", (try store.list(io, ctx, &listing, options)).next orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(?*const anyopaque, &listing), recorder.last_request);
    const claim: Store.ClaimRequest = .{ .owner = "shop/1", .any_key = &.{}, .keyed_only = &.{ref.job}, .max = 4, .lease = .fromSeconds(60), .tag = tag };
    const claimed = try store.claim(io, ctx, &claim, options);
    try testing.expectEqual(@as(?Io.Duration, .fromSeconds(3)), claimed.next_in);
    const renew: Store.RenewRequest = .{ .ref = ref, .life = life, .owner = "shop/1", .fence = 1, .lease = .fromSeconds(60) };
    try testing.expectEqual(Store.RenewResult.lost, try store.renew(io, ctx, &renew, options));
    const finish: Store.FinishRequest = .{ .ref = ref, .life = life, .owner = "shop/1", .fence = 1, .revision = 0, .tag = tag, .next = .delete, .last = null };
    try testing.expect(try store.finish(io, ctx, &finish, options) == .done);
    try testing.expectEqual(@as(?*const anyopaque, &finish), recorder.last_request);
    const history: Store.HistoryRequest = .{ .filter = .{ .outcome = .abandoned }, .page = .{} };
    try testing.expectEqualStrings("history-next", (try store.history(io, ctx, &history, options)).next orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(?*const anyopaque, &history), recorder.last_request);

    // Each method once, with the caller's context and options.
    try testing.expectEqualSlices(u32, &@as([10]u32, @splat(1)), &recorder.calls);
    try testing.expectEqual(ctx.deadline, recorder.last_deadline);
    try testing.expectEqual(@as(?*scheduler.Diagnostics, &d), recorder.last_diagnostics);
}

test "outcome classes the names of Error" {
    // A record that does not read may come of a change that applied: a
    // claim that took it before reading it.
    const unknown = [_]scheduler.Error{ error.OutcomeUnknown, error.Corrupt, error.OutOfMemory };
    const not_applied = [_]scheduler.Error{
        error.InvalidArgument,
        error.Unavailable,
        error.DeadlineExceeded,
        error.Cancelled,
        error.Refused,
        error.Contended,
    };
    for (unknown) |err| try testing.expectEqual(scheduler.Outcome.unknown, scheduler.outcome(err));
    for (not_applied) |err| try testing.expectEqual(scheduler.Outcome.not_applied, scheduler.outcome(err));
    try testing.expectEqual(8, @typeInfo(StoreError).error_set.error_names.?.len);
    try testing.expectEqual(9, @typeInfo(scheduler.Error).error_set.error_names.?.len);
    try testing.expectEqual(unknown.len + not_applied.len, @typeInfo(scheduler.Error).error_set.error_names.?.len);
}
