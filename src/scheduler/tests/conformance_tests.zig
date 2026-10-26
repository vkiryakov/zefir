//! Tests of scheduler.testing.conformance: MemoryStore passes it, a store
//! that breaks a rule fails the check of that rule, and a check past its
//! time limit fails while the run goes on.

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
    const only = [_]conformance.Check{ .s1, .s2, .s3, .s4, .s5, .s18, .s19 };
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
    // The totals, then a line a check.
    try testing.expectEqual(@as(usize, 23), std.mem.count(u8, text, "\n"));
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
