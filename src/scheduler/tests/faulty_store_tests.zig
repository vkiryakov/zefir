//! Tests of scheduler.testing.FaultyStore over a MemoryStore: errors,
//! stalls and lost replies on demand, and the count of the calls that
//! reached the store.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const scheduler = @import("../root.zig");
const Store = scheduler.Store;
const Record = scheduler.Record;
const FaultyStore = scheduler.testing.FaultyStore;

const io = testing.io;

const ref: scheduler.Ref = .{ .job = "send-invoice", .key = "order-42" };

/// A MemoryStore behind a FaultyStore, and an arena for the results. Made
/// in place, since the FaultyStore points at the MemoryStore.
const Fixture = struct {
    memory: scheduler.MemoryStore,
    faulty: FaultyStore,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) void {
        f.memory = .init(testing.allocator, io, .{});
        f.faulty = .init(f.memory.store());
        f.arena = .init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.memory.deinit();
        f.arena.deinit();
    }

    fn store(f: *Fixture) Store {
        return f.faulty.store();
    }

    fn options(f: *Fixture, d: ?*scheduler.Diagnostics) Store.CallOptions {
        return .{ .allocator = f.arena.allocator(), .diagnostics = d };
    }

    /// A create of `key` through the FaultyStore, due in a minute.
    fn create(f: *Fixture, ctx: core.Context, key: []const u8, d: ?*scheduler.Diagnostics) scheduler.StoreError!Store.CreateResult {
        return f.store().create(io, ctx, &.{ .job = "send-invoice", .key = key, .life = @splat(1), .plan = "", .payload = "{}", .run_at = .{ .after = .fromSeconds(60) } }, f.options(d));
    }

    /// The record of `key` as the MemoryStore has it, past the faults.
    fn inner(f: *Fixture, key: []const u8) !?Record {
        return f.memory.store().get(io, .root, &.{ .job = "send-invoice", .key = key }, f.options(null));
    }
};

/// A context whose deadline is `budget` from now.
fn within(budget: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), budget));
}

test "failNext fails the next calls, then passes through" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    f.faulty.failNext(io, .create, error.Unavailable, 2);
    for (0..2) |_| {
        d = .{};
        try testing.expectError(error.Unavailable, f.create(.root, "order-42", &d));
        try testing.expect(d.message().len > 0);
    }
    // Nothing reached the store; the third call does.
    try testing.expectEqual(@as(?Record, null), try f.inner("order-42"));
    try testing.expectEqual(Store.CreateResult.created, try f.create(.root, "order-42", null));

    // The faults of an operation come in the order they were asked for.
    f.faulty.failNext(io, .get, error.Unavailable, 1);
    f.faulty.failNext(io, .get, error.Corrupt, 1);
    try testing.expectError(error.Unavailable, f.store().get(io, .root, &ref, f.options(null)));
    try testing.expectError(error.Corrupt, f.store().get(io, .root, &ref, f.options(null)));
    const r = (try f.store().get(io, .root, &ref, f.options(null))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("order-42", r.key);

    // A fault of one operation leaves the others alone, and `now` never
    // fails.
    f.faulty.failNext(io, .claim, error.Unavailable, 1);
    const before = f.memory.store().now(io);
    try testing.expect(f.store().now(io).unix_ms >= before.unix_ms);
    try testing.expect(try f.store().remove(io, .root, &ref, f.options(null)));
    const claim: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{}, .keyed_only = &.{"send-invoice"}, .max = 1, .lease = .fromSeconds(60), .tag = @splat(0) };
    try testing.expectError(error.Unavailable, f.store().claim(io, .root, &claim, f.options(null)));
    try testing.expectEqual(@as(usize, 0), (try f.store().claim(io, .root, &claim, f.options(null))).claimed.len);
}

test "stallNext runs into the deadline with OutcomeUnknown and leaves the store alone" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    f.faulty.stallNext(io, .create, .fromSeconds(5));
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.OutcomeUnknown, f.create(within(.fromMilliseconds(300)), "order-42", &d));
    const took = start.durationTo(Io.Clock.awake.now(io));
    try testing.expect(d.message().len > 0);
    // Not before the deadline, and not the whole stall.
    try testing.expect(took.nanoseconds >= 300 * std.time.ns_per_ms);
    try testing.expect(took.nanoseconds < 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(?Record, null), try f.inner("order-42"));
    try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, .create));
    // The stall was for one call.
    try testing.expectEqual(Store.CreateResult.created, try f.create(within(.fromSeconds(10)), "order-42", null));
}

test "stallNext shorter than the deadline lets the call through" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.faulty.stallNext(io, .create, .fromMilliseconds(300));
    const start = Io.Clock.awake.now(io);
    try testing.expectEqual(Store.CreateResult.created, try f.create(within(.fromSeconds(10)), "order-42", null));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 300 * std.time.ns_per_ms);
    _ = (try f.inner("order-42")) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), f.faulty.calls(io, .create));

    // A call without a deadline waits the whole stall.
    f.faulty.stallNext(io, .get, .fromMilliseconds(100));
    const r = (try f.store().get(io, .root, &ref, f.options(null))) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("order-42", r.key);
}

/// What the stalled call of a task gave, and whether the task was still
/// cancelled after it.
const Stalled = struct {
    result: ?scheduler.StoreError!Store.CreateResult = null,
    cancelled_after: bool = false,

    fn run(s: *Stalled, f: *Fixture) void {
        // A deadline far behind the cancel, so that a lost cancel fails the
        // test instead of hanging it.
        s.result = f.create(within(.fromSeconds(30)), "order-42", null);
        if (io.checkCancel()) |_| {} else |_| s.cancelled_after = true;
    }
};

test "stallNext of a task that is cancelled answers OutcomeUnknown, and the task stays cancelled" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.faulty.stallNext(io, .create, .fromSeconds(60));
    var stalled: Stalled = .{};
    // The stalled call allocates nothing before its wait, so the cancel
    // cannot come during a stack trace of std.testing.allocator.
    var task = try io.concurrent(Stalled.run, .{ &stalled, &f });
    task.cancel(io);
    try testing.expectError(error.OutcomeUnknown, stalled.result orelse return error.TestUnexpectedResult);
    try testing.expect(stalled.cancelled_after);
    try testing.expectEqual(@as(?Record, null), try f.inner("order-42"));
    try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, .create));
}

test "loseNextReply applies the change and answers OutcomeUnknown" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var d: scheduler.Diagnostics = .{};
    f.faulty.loseNextReply(io, .create);
    try testing.expectError(error.OutcomeUnknown, f.create(.root, "order-42", &d));
    try testing.expect(d.message().len > 0);
    const r = (try f.inner("order-42")) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.pending, r.state);
    // The next call has its reply.
    try testing.expectEqual(Store.CreateResult.existing, try f.create(.root, "order-42", null));

    // A lost claim claimed all the same. Its result is dropped whole: the
    // caller's allocator, which checks for leaks, gives none of it.
    _ = try f.memory.store().update(io, .root, &.{ .ref = ref, .expect = .{ .revision = 0, .state = .pending }, .set = .{ .run_at = .{ .after = .fromSeconds(-1) } }, .tag = @splat(0) }, f.options(null));
    f.faulty.loseNextReply(io, .claim);
    const claim: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{}, .keyed_only = &.{"send-invoice"}, .max = 1, .lease = .fromSeconds(60), .tag = @splat(0) };
    try testing.expectError(error.OutcomeUnknown, f.store().claim(io, .root, &claim, .{ .allocator = testing.allocator }));
    const claimed = (try f.inner("order-42")) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.running, claimed.state);
    try testing.expectEqualDeep(@as(?[]const u8, "w1"), claimed.owner);
}

test "calls counts what reached the store" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    for (std.enums.values(scheduler.testing.Op)) |op| try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, op));

    // A failed call reaches no store; a call with its reply, a lost reply
    // and a stall that ends before the deadline do.
    f.faulty.failNext(io, .create, error.Unavailable, 1);
    try testing.expectError(error.Unavailable, f.create(.root, "a", null));
    try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, .create));
    try testing.expectEqual(Store.CreateResult.created, try f.create(.root, "a", null));
    f.faulty.loseNextReply(io, .create);
    try testing.expectError(error.OutcomeUnknown, f.create(.root, "b", null));
    // A stall that runs into its deadline does not.
    f.faulty.stallNext(io, .create, .fromSeconds(5));
    try testing.expectError(error.OutcomeUnknown, f.create(within(.fromMilliseconds(300)), "c", null));
    f.faulty.stallNext(io, .create, .fromMilliseconds(1));
    try testing.expectEqual(Store.CreateResult.created, try f.create(.root, "c", null));
    try testing.expectEqual(@as(u32, 3), f.faulty.calls(io, .create));

    // Each operation counts its own.
    _ = try f.store().get(io, .root, &ref, f.options(null));
    try testing.expectEqual(@as(u32, 1), f.faulty.calls(io, .get));
    try testing.expectEqual(@as(u32, 0), f.faulty.calls(io, .remove));
    try testing.expectEqual(@as(u32, 3), f.faulty.calls(io, .create));
}
