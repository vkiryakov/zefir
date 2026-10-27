//! The record of a declaration, the key "", on mongod between two
//! instances of a service (9.9 of the design): only the instance that
//! declares the job with `.repeat` runs it. Once that instance stopped,
//! the record is parked: pending and due, the polls of the other instance
//! pass it over and their `next_in` does not see it, until
//! `client.cancel(.declared(T))` removes it.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const e2e = @import("root.zig");
const fixture = @import("fixture.zig");

/// The job as the instance that declares it knows it: its record runs
/// every second.
const Tick = struct {
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-tick", .repeat = .everySeconds(1) };

    pub fn run(self: *Tick, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, false);
    }
};

/// The same job as the code of another version knows it, without
/// `.repeat`: that instance runs only its records with a key.
const TickKeyed = struct {
    probe: *fixture.Probe,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-tick" };

    pub fn run(self: *TickKeyed, ctx: *scheduler.Context) !void {
        try self.probe.run(ctx, false);
    }
};

test "a declared record runs only where it is declared and parks where none is" {
    try e2e.onZio(parks);
}

fn parks(io: Io) !void {
    var scene: fixture.Scene = undefined;
    try scene.open(io, e2e.servers.plain, "declared");
    defer scene.close(io);
    var a: fixture.Node = undefined;
    try a.open(io, e2e.servers.plain, scene.database);
    defer a.close();
    var b: fixture.Node = undefined;
    try b.open(io, e2e.servers.plain, scene.database);
    defer b.close();
    // Counts the polls of B.
    var b_store: scheduler.testing.FaultyStore = .init(b.store.store());
    var declares: fixture.Probe = .{};
    var knows: fixture.Probe = .{};
    var tick: Tick = .{ .probe = &declares };
    var keyed: TickKeyed = .{ .probe = &knows };
    var wa: scheduler.Worker(struct { tick: *Tick }) = try .init(testing.allocator, io, a.store.store(), .{ .tick = &tick }, fixture.options("declares", 2));
    defer wa.deinit(io);
    var wb: scheduler.Worker(struct { tick: *TickKeyed }) = try .init(testing.allocator, io, b_store.store(), .{ .tick = &keyed }, fixture.options("knows", 2));
    defer wb.deinit(io);
    try wa.start(io);
    try wb.start(io);

    // A writes the record and runs it every second; B never does.
    var limit: fixture.Limit = .of(io, 30, "two runs of the declared record");
    while (declares.began.load(.acquire) < 2) try limit.tick(io);
    try fixture.stop(io, &wa);
    try testing.expectEqual(@as(u32, 0), knows.began.load(.acquire));

    // A is gone: its record waits, pending, and becomes due.
    const client: scheduler.Client = .init(testing.allocator, io, b.store.store(), .{});
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ref: scheduler.Ref = .declared(TickKeyed);
    limit = .of(io, 30, "the declared record to be pending and due");
    const parked = while (true) {
        if (try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{})) |r| {
            const due = if (r.run_at) |at| at.unix_ms <= b.store.now(io).unix_ms else false;
            if (r.state == .pending and due) break r;
        }
        try limit.tick(io);
    };

    // Ten polls of B later it is as it was: B passes it over.
    const polls = b_store.calls(io, .claim);
    limit = .of(io, 30, "ten polls of B");
    while (b_store.calls(io, .claim) < polls + 10) try limit.tick(io);
    const still = (try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.State.pending, still.state);
    try testing.expectEqual(parked.fence, still.fence);
    try testing.expectEqual(parked.revision, still.revision);
    try testing.expectEqual(@as(u32, 0), knows.began.load(.acquire));
    try testing.expectEqual(@as(u64, 0), wb.stats().claimed);
    // A claim of B's jobs neither takes it nor counts it in next_in.
    var tag: scheduler.Store.Tag = undefined;
    io.random(&tag);
    const claim = try b.store.store().claim(io, e2e.within(io, .fromSeconds(10)), &.{
        .owner = "e2e-declared/probe",
        .any_key = &.{},
        .keyed_only = &.{TickKeyed.scheduler_job.name},
        .max = 1,
        .lease = .fromSeconds(3),
        .tag = tag,
    }, .{ .allocator = arena });
    try testing.expectEqual(@as(usize, 0), claim.claimed.len);
    try testing.expect(claim.next_in == null);

    // Only an explicit cancel removes it.
    try testing.expect(try client.cancel(io, e2e.within(io, .fromSeconds(10)), ref, .{}));
    try testing.expect(try client.get(io, e2e.within(io, .fromSeconds(10)), ref, arena, .{}) == null);
    try fixture.stop(io, &wb);
}
