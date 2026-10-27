//! The conformance suite of the stores of the scheduler, run as the tests
//! of a store of your own run it: a harness gives each check a new, empty
//! store and takes it back. Here the store is `scheduler.MemoryStore`; a
//! store of your own runs the suite in the tests of its package, against
//! its server. `zig build test-scheduler` runs it.

const std = @import("std");
const scheduler = @import("scheduler");
const conformance = scheduler.testing.conformance;

/// What the suite calls for each check.
const Harness = struct {
    memory: scheduler.MemoryStore = undefined,

    /// A new, empty store, and how long after its `expires_at` a record or
    /// a row may still be there: none for MemoryStore, which drops them at
    /// its next call; MongoDB's TTL monitor wakes once a minute.
    pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !conformance.Setup {
        h.memory = .init(gpa, io, .{});
        return .{ .store = h.memory.store(), .expiry_lag = .zero };
    }

    /// Frees what `setUp` made: memory the store keeps after this fails the
    /// check as a leak.
    pub fn tearDown(h: *Harness, io: std.Io, setup: conformance.Setup) void {
        _ = io;
        _ = setup;
        h.memory.deinit();
    }
};

test "MemoryStore keeps the contract of the scheduler" {
    var harness: Harness = .{};
    var report = try conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // S17 needs `loseNextReply`, a hook to lose a reply: MemoryStore never
    // loses one, so its harness has none, and the check is skipped.
    try std.testing.expectEqual(1, report.skippedCount());
    try std.testing.expect(report.outcome(.s17) == .skipped);
}
