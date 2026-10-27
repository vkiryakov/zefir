//! Tests of scheduler.testing.conformance: MemoryStore passes it, also when
//! a pause of the mix of S20 meets a new life of its record; a store that
//! breaks a rule fails the check of that rule, and a check past its time
//! limit fails while the run goes on.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const scheduler = @import("../root.zig");
const runner = @import("../testing/checks/runner.zig");
const conformance = scheduler.testing.conformance;
const Store = scheduler.Store;
const MemoryStore = scheduler.MemoryStore;
const StalledPause = @import("stalled_pause_fixture.zig").StalledPause;

/// A MemoryStore for each check.
const MemoryHarness = struct {
    memory: MemoryStore = undefined,

    pub fn setUp(h: *MemoryHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        return .{ .store = h.memory.store(), .expiry_lag = .zero };
    }

    pub fn tearDown(h: *MemoryHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }
};

/// A MemoryStore behind a table of its own, whose methods a test may
/// replace with flawed ones.
const PatchedHarness = struct {
    patch: *const fn (vtable: *Store.VTable) void,
    memory: MemoryStore = undefined,
    vtable: Store.VTable = undefined,

    pub fn setUp(h: *PatchedHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        const inner = h.memory.store();
        h.vtable = inner.vtable.*;
        h.patch(&h.vtable);
        return .{ .store = .{ .ptr = inner.ptr, .vtable = &h.vtable }, .expiry_lag = .zero };
    }

    pub fn tearDown(h: *PatchedHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }
};

fn memoryOf(ptr: *anyopaque) *MemoryStore {
    return @ptrCast(@alignCast(ptr));
}

/// What a report says of a check that failed; a test of another outcome
/// fails.
fn failedWhy(outcome: conformance.Outcome) ![]const u8 {
    return switch (outcome) {
        .failed => |why| why,
        else => error.TestUnexpectedResult,
    };
}

fn skippedWhy(outcome: conformance.Outcome) ![]const u8 {
    return switch (outcome) {
        .skipped => |why| why,
        else => error.TestUnexpectedResult,
    };
}

fn expectNoFailures(report: *const conformance.Report) !void {
    if (report.failedCount() == 0) return;
    std.debug.print("{f}", .{report});
    return error.TestUnexpectedResult;
}

test "a run reports every check" {
    var harness: MemoryHarness = .{};
    const only = [_]conformance.Check{ .s3, .s15 };
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &only });
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqualStrings("memory", report.store_name);
    try testing.expectEqual(only.len, report.passedCount());
    try testing.expectEqual(22 - only.len, report.skippedCount());
    for (std.enums.values(conformance.Check)) |check| {
        if (std.mem.findScalar(conformance.Check, &only, check) != null) {
            try testing.expect(report.outcome(check) == .passed);
        } else {
            try testing.expectEqualStrings("not in options.only", try skippedWhy(report.outcome(check)));
        }
    }
    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&report});
    defer testing.allocator.free(text);
    var totals: [80]u8 = undefined;
    try testing.expectStringStartsWith(text, try std.fmt.bufPrint(&totals, "scheduler conformance of \"memory\": {d} passed, 0 failed, {d} skipped\n", .{ only.len, 22 - only.len }));
    try testing.expect(std.mem.find(u8, text, "\n  passed   S3   get of a record and of none; remove is true, then false\n") != null);
    try testing.expect(std.mem.find(u8, text, "\n  skipped  S17  lost replies of create, update, claim, renew and finish: a right answer or OutcomeUnknown, never a false one: not in options.only\n") != null);
    // The totals, then a line a check.
    try testing.expectEqual(@as(usize, 23), std.mem.count(u8, text, "\n"));
}

test "MemoryStore passes the conformance suite" {
    // With the default limits, the mix of S20 may evict rows of the
    // history, and MemoryStore warns about it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var harness: MemoryHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqual(@as(usize, 21), report.passedCount());
    try testing.expectEqualStrings("the harness has no loseNextReply", try skippedWhy(report.outcome(.s17)));
}

/// A MemoryStore whose pause of a pending record stalls until a claim took
/// the record and it has a new life: `stalled_pause_fixture.zig`.
const StalledHarness = struct {
    stalled: StalledPause = undefined,

    pub fn setUp(h: *StalledHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.stalled.init(gpa, io, .{});
        return .{ .store = h.stalled.store(), .expiry_lag = .zero };
    }

    pub fn tearDown(h: *StalledHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.stalled.deinit();
    }
};

test "S20 holds when a pause of the mix meets a new life of its record" {
    // With the default limits, the mix of S20 may evict rows of the
    // history, and MemoryStore warns about it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var harness: StalledHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{.s20} });
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expect(report.outcome(.s20) == .passed);
    try testing.expect(harness.stalled.refused.load(.acquire));
}

/// A MemoryStore behind a FaultyStore, which loses the reply of a call on
/// demand: every answer after a lost reply is OutcomeUnknown.
const LosingHarness = struct {
    memory: MemoryStore = undefined,
    faulty: scheduler.testing.FaultyStore = undefined,

    pub fn setUp(h: *LosingHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        h.faulty = .init(h.memory.store());
        return .{ .store = h.faulty.store(), .expiry_lag = .zero };
    }

    pub fn tearDown(h: *LosingHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }

    pub fn loseNextReply(h: *LosingHarness, io: Io, op: scheduler.testing.Op) !void {
        h.faulty.loseNextReply(io, op);
    }
};

/// A MemoryStore whose replies are never lost: every answer of S17 is
/// definite.
const SureHarness = struct {
    inner: MemoryHarness = .{},

    pub fn setUp(h: *SureHarness, io: Io, gpa: Allocator) !conformance.Setup {
        return h.inner.setUp(io, gpa);
    }

    pub fn tearDown(h: *SureHarness, io: Io, setup: conformance.Setup) void {
        h.inner.tearDown(io, setup);
    }

    pub fn loseNextReply(h: *SureHarness, io: Io, op: scheduler.testing.Op) !void {
        _ = h;
        _ = io;
        _ = op;
    }
};

test "S17 takes a right answer or OutcomeUnknown after a lost reply" {
    var losing: LosingHarness = .{};
    var unknown = try conformance.run(testing.io, testing.allocator, &losing, .{ .only = &.{.s17} });
    defer unknown.deinit();
    try expectNoFailures(&unknown);
    try testing.expect(unknown.outcome(.s17) == .passed);
    try testing.expectEqualStrings("faulty", unknown.store_name);
    var sure: SureHarness = .{};
    var definite = try conformance.run(testing.io, testing.allocator, &sure, .{ .only = &.{.s17} });
    defer definite.deinit();
    try expectNoFailures(&definite);
    try testing.expect(definite.outcome(.s17) == .passed);
}

/// A MemoryStore whose claim of two records or more, after
/// `loseNextReply(.claim)`, gives the first record it took in place of the
/// second, as a store that resolves the lost reply by "a running record of
/// the owner" rather than by its mark would; every other reply is whole.
const TwiceHarness = struct {
    memory: MemoryStore = undefined,
    vtable: Store.VTable = undefined,
    armed: bool = false,

    pub fn setUp(h: *TwiceHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        h.vtable = h.memory.store().vtable.*;
        h.vtable.name = "twice";
        h.vtable.claim = claim;
        h.armed = false;
        return .{ .store = .{ .ptr = &h.memory, .vtable = &h.vtable }, .expiry_lag = .zero };
    }

    pub fn tearDown(h: *TwiceHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }

    pub fn loseNextReply(h: *TwiceHarness, io: Io, op: scheduler.testing.Op) !void {
        _ = io;
        if (op == .claim) h.armed = true;
    }

    fn claim(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.ClaimRequest, options: Store.CallOptions) scheduler.StoreError!Store.ClaimResult {
        const h: *TwiceHarness = @fieldParentPtr("memory", memoryOf(ptr));
        const result = try memoryOf(ptr).claim(io, ctx, request, options);
        if (!h.armed or result.claimed.len < 2) return result;
        h.armed = false;
        const twice = try options.allocator.alloc(Store.Claimed, result.claimed.len);
        @memcpy(twice, result.claimed);
        twice[1] = twice[0];
        return .{ .claimed = twice, .next_in = result.next_in };
    }
};

test "S17 fails a claim that gives a record twice after a lost reply" {
    var harness: TwiceHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{.s17} });
    defer report.deinit();
    try testing.expectEqualStrings("a claim with its reply lost gave s17-three/t1 twice", try failedWhy(report.outcome(.s17)));
}

/// A MemoryStore whose history reads as if an `abandoned` row replaced the
/// row of its claim whenever it came last, the owner's row too; a row of
/// the owner that comes after it replaces it again.
const AbandonedLastHarness = struct {
    memory: MemoryStore = undefined,
    vtable: Store.VTable = undefined,
    /// The claims whose last row was abandoned.
    claims: [16]Claim = undefined,
    len: usize = 0,

    const Claim = struct { life: scheduler.Life, fence: u64 };

    pub fn setUp(h: *AbandonedLastHarness, io: Io, gpa: Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        h.vtable = h.memory.store().vtable.*;
        h.vtable.name = "abandoned-last";
        h.vtable.finish = finish;
        h.vtable.history = history;
        h.len = 0;
        return .{ .store = .{ .ptr = &h.memory, .vtable = &h.vtable }, .expiry_lag = .zero };
    }

    pub fn tearDown(h: *AbandonedLastHarness, io: Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }

    fn find(h: *const AbandonedLastHarness, life: scheduler.Life, fence: u64) ?usize {
        for (h.claims[0..h.len], 0..) |c, i| {
            if (std.mem.eql(u8, &c.life, &life) and c.fence == fence) return i;
        }
        return null;
    }

    fn finish(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.FinishRequest, options: Store.CallOptions) scheduler.StoreError!Store.FinishResult {
        const h: *AbandonedLastHarness = @fieldParentPtr("memory", memoryOf(ptr));
        if (request.history.keep != .none) for (request.history.runs) |run| {
            const at = h.find(run.life, run.fence);
            if (run.outcome == .abandoned) {
                if (at == null and h.len < h.claims.len) {
                    h.claims[h.len] = .{ .life = run.life, .fence = run.fence };
                    h.len += 1;
                }
            } else if (at) |i| {
                h.claims[i] = h.claims[h.len - 1];
                h.len -= 1;
            }
        };
        return memoryOf(ptr).finish(io, ctx, request, options);
    }

    fn history(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.HistoryRequest, options: Store.CallOptions) scheduler.StoreError!scheduler.RunPage {
        const h: *AbandonedLastHarness = @fieldParentPtr("memory", memoryOf(ptr));
        const page = try memoryOf(ptr).history(io, ctx, request, options);
        const runs = try options.allocator.dupe(scheduler.Run, page.runs);
        for (runs) |*run| {
            if (h.find(run.life, run.fence) != null) run.outcome = .abandoned;
        }
        return .{ .runs = runs, .next = page.next };
    }
};

test "S12 fails a store whose abandoned row replaces the owner's" {
    var harness: AbandonedLastHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{.s12} });
    defer report.deinit();
    try testing.expectEqualStrings("the row of fence 1 is abandoned of s12-w1, not the owner's succeeded one", try failedWhy(report.outcome(.s12)));
}

/// A get that sleeps 10 s first: S3, which starts with one, cannot end in
/// time.
fn sleepyGet(vtable: *Store.VTable) void {
    vtable.name = "sleepy";
    vtable.get = struct {
        fn get(ptr: *anyopaque, io: Io, ctx: core.Context, ref: *const scheduler.Ref, options: Store.CallOptions) scheduler.StoreError!?scheduler.Record {
            io.sleep(.fromSeconds(10), .awake) catch {
                io.recancel();
                return error.Cancelled;
            };
            return memoryOf(ptr).get(io, ctx, ref, options);
        }
    }.get;
}

test "a check past its time limit fails" {
    // The run warns about the check that hangs.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var harness: PatchedHarness = .{ .patch = sleepyGet };
    const only = [_]conformance.Check{.s3};
    const start = Io.Clock.awake.now(testing.io);
    var report = try runner.runLimited(testing.io, testing.allocator, &harness, .{ .only = &only }, .fromSeconds(1));
    defer report.deinit();
    // The run did not wait for the sleep: the check's task was canceled.
    try testing.expect(start.durationTo(Io.Clock.awake.now(testing.io)).nanoseconds < Io.Duration.fromSeconds(8).nanoseconds);
    try testing.expectEqualStrings("sleepy", report.store_name);
    try testing.expectStringStartsWith(try failedWhy(report.outcome(.s3)), "it did not end in 1s, and its task was canceled");
    try testing.expectEqual(@as(usize, 1), report.failedCount());
}

/// A create of a live key that answers created, though it changed nothing.
fn createdTwice(vtable: *Store.VTable) void {
    vtable.name = "created-twice";
    vtable.create = struct {
        fn create(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.CreateRequest, options: Store.CallOptions) scheduler.StoreError!Store.CreateResult {
            const result = try memoryOf(ptr).create(io, ctx, request, options);
            return if (result == .existing) .created else result;
        }
    }.create;
}

test "a store that breaks a rule fails its check" {
    var harness: PatchedHarness = .{ .patch = createdTwice };
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{ .s1, .s3 } });
    defer report.deinit();
    try testing.expectEqualStrings("create of a pending key answered created, not existing", try failedWhy(report.outcome(.s1)));
    try testing.expect(report.outcome(.s3) == .passed);
    try testing.expectEqual(@as(usize, 1), report.failedCount());
}

/// An update that holds on the revision and state alone: the life the
/// record has now stands in for the life the change read.
fn lifeBlind(vtable: *Store.VTable) void {
    vtable.name = "life-blind";
    vtable.update = struct {
        fn update(ptr: *anyopaque, io: Io, ctx: core.Context, request: *const Store.UpdateRequest, options: Store.CallOptions) scheduler.StoreError!Store.UpdateResult {
            var blind = request.*;
            if (try memoryOf(ptr).get(io, ctx, &request.ref, options)) |now| blind.expect.life = now.life;
            return memoryOf(ptr).update(io, ctx, &blind, options);
        }
    }.update;
}

test "a store whose update does not hold on the life fails S4" {
    var harness: PatchedHarness = .{ .patch = lifeBlind };
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .only = &.{.s4} });
    defer report.deinit();
    try testing.expectEqualStrings("update of a life that was removed, on the revision and state of the new life of its key, answered updated, not conflict", try failedWhy(report.outcome(.s4)));
}
