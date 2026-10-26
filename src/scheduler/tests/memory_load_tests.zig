//! Tests of scheduler.MemoryStore under load: tasks that claim the same
//! records at once, and tasks that mix every operation of the contract for
//! 3 s, after which its rules still hold. The load tasks stop by a flag,
//! and no gate holds them, before their group is cancelled: on macOS, std
//! 0.17 can lose a cancel while std.testing.allocator records a stack
//! trace.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const scheduler = @import("../root.zig");
const Store = scheduler.Store;
const Record = scheduler.Record;
const Instant = scheduler.Instant;
const MemoryStore = scheduler.MemoryStore;

const io = testing.io;

/// The indexes of the store agree with its records.
fn checkIndexes(memory: *MemoryStore) !void {
    memory.mutex.lockUncancelable(io);
    defer memory.mutex.unlock(io);
    if (memory.table.check()) |problem| {
        std.debug.print("MemoryStore: {s}\n", .{problem});
        return error.TestUnexpectedResult;
    }
}

/// Until `counter` reaches `n`; error.Timeout after 30 s.
fn atLeast(counter: *std.atomic.Value(usize), n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(30));
    while (counter.load(.acquire) < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("{d} of {d} tasks done after 30 s\n", .{ counter.load(.acquire), n });
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The key of the i-th record of the claim race: "000" to "199".
fn raceKey(buffer: *[3]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>3}", .{i}) catch unreachable;
}

/// Tasks that claim records of one job, all at once, until none is left.
const Race = struct {
    store: Store,
    gate: Io.Event = .unset,
    /// How many times each record was claimed, and by which task.
    claims: [200]std.atomic.Value(u32) = @splat(.init(0)),
    owners: [200]std.atomic.Value(u8) = @splat(.init(0)),
    errors: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),

    fn run(race: *Race, task: u8) void {
        defer _ = race.done.fetchAdd(1, .release);
        race.gate.wait(io) catch return;
        race.claimAll(task) catch |err| {
            std.debug.print("task {d}: {t}\n", .{ task, err });
            _ = race.errors.fetchAdd(1, .monotonic);
        };
    }

    fn claimAll(race: *Race, task: u8) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const owner = [2]u8{ 'w', '0' + task };
        while (true) {
            _ = arena.reset(.retain_capacity);
            const result = try race.store.claim(io, .root, &.{
                .owner = &owner,
                .any_key = &.{},
                .keyed_only = &.{"a"},
                // Claims of 1 to 4 records.
                .max = 1 + task % 4,
                .lease = .fromSeconds(60),
                .tag = @splat(task),
            }, .{ .allocator = arena.allocator() });
            if (result.claimed.len == 0) return;
            for (result.claimed) |c| {
                const i = try std.fmt.parseInt(usize, c.record.key, 10);
                if (i >= race.claims.len) return error.TestUnexpectedResult;
                _ = race.claims[i].fetchAdd(1, .monotonic);
                race.owners[i].store(task, .monotonic);
            }
        }
    }
};

test "8 tasks claim 200 records at once: each exactly once" {
    var memory: MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const store = memory.store();
    var key: [3]u8 = undefined;
    for (0..200) |i| {
        var life: scheduler.Life = @splat(0);
        std.mem.writeInt(u64, life[0..8], i + 1, .little);
        const request: Store.CreateRequest = .{ .job = "a", .key = raceKey(&key, i), .life = life, .plan = "", .payload = "{}", .run_at = .{ .after = .fromSeconds(-1) } };
        try testing.expectEqual(Store.CreateResult.created, try store.create(io, .root, &request, .{ .allocator = arena.allocator() }));
    }

    var race: Race = .{ .store = store };
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        // On any way out no task waits at the gate.
        defer race.gate.set(io);
        for (0..8) |task| try group.concurrent(io, Race.run, .{ &race, @as(u8, @intCast(task)) });
        race.gate.set(io);
        try atLeast(&race.done, 8);
    }
    try testing.expectEqual(@as(usize, 0), race.errors.load(.monotonic));

    for (&race.claims, &race.owners, 0..) |*claims, *owner, i| {
        try testing.expectEqual(@as(u32, 1), claims.load(.monotonic));
        const r = (try store.get(io, .root, &.{ .job = "a", .key = raceKey(&key, i) }, .{ .allocator = arena.allocator() })) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(scheduler.State.running, r.state);
        try testing.expectEqualDeep(@as(?[]const u8, &[2]u8{ 'w', '0' + owner.load(.monotonic) }), r.owner);
        try testing.expectEqual(@as(u32, 1), r.attempt);
        try testing.expectEqual(@as(u64, 1), r.fence);
    }
    try checkIndexes(&memory);
}

/// The records of the mixed load: 8 keys of job "a", 8 of job "b", and the
/// declared record of "b" (key ""), which only the tasks that declare "b"
/// may claim.
const slots: [17]scheduler.Ref = slots: {
    const keys = [_][]const u8{ "k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7" };
    var all: [17]scheduler.Ref = undefined;
    for (keys, 0..) |k, i| {
        all[i] = .{ .job = "a", .key = k };
        all[keys.len + i] = .{ .job = "b", .key = k };
    }
    all[16] = .{ .job = "b", .key = "" };
    break :slots all;
};

fn slotOf(r: Record) ?u8 {
    for (slots, 0..) |s, i| {
        if (std.mem.eql(u8, s.job, r.job) and std.mem.eql(u8, s.key, r.key)) return @intCast(i);
    }
    return null;
}

fn orderRef(a: scheduler.Ref, b: scheduler.Ref) std.math.Order {
    const job = std.mem.order(u8, a.job, b.job);
    return if (job != .eq) job else std.mem.order(u8, a.key, b.key);
}

/// The first rule of the record model that `r` breaks, or null.
fn shape(r: Record) ?[]const u8 {
    const claimed = r.owner != null and r.claimed_at != null and r.lease_until != null;
    if ((r.state == .running) != claimed) return "a running record without its owner, claim and lease, or another one with them";
    if ((r.state == .pending or r.state == .paused) != (r.run_at != null)) return "run_at on a record that does not wait, or none on one that does";
    if ((r.state == .succeeded or r.state == .failed) != (r.finished_at != null)) return "finished_at on a record that is not finished, or none on one that is";
    return null;
}

/// A claim that a task of the load holds.
const Held = struct { slot: u8, life: scheduler.Life, fence: u64, revision: u64, attempt: u32, scheduled_at: Instant, claimed_at: Instant };

/// A record that a claim gave: its life, fence and revision.
const ClaimNote = struct {
    life: scheduler.Life,
    fence: u64,
    revision: u64,

    fn lessThan(_: void, a: ClaimNote, b: ClaimNote) bool {
        return switch (std.mem.order(u8, &a.life, &b.life)) {
            .lt => true,
            .gt => false,
            .eq => a.fence < b.fence,
        };
    }
};

/// A record of `life` that stopped waiting, paused or finished, at
/// `revision`: only a change of the client, which raises the revision,
/// makes it claimable again, so no later claim may come at that revision.
const Quiet = struct { life: scheduler.Life, revision: u64 };

/// A record made quiet by the finish of its claim `fence`, or by a change
/// of the client (`fence` 0): the claims up to `fence` came before.
const QuietNote = struct { quiet: Quiet, fence: u64 };

const Load = struct {
    store: Store,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(usize) = .init(0),
};

/// One task of the mixed load: every operation of the contract at random,
/// on its own claims, as a worker and a client at once.
const Mixer = struct {
    load: *Load,
    index: u8,
    owner: [3]u8,
    /// Whether the task declares "b": its claims take the declared record.
    declares: bool,
    rng: std.Random.DefaultPrng,
    arena: std.heap.ArenaAllocator,
    held: std.ArrayList(Held) = .empty,
    claims: std.ArrayList(ClaimNote) = .empty,
    quiets: std.ArrayList(QuietNote) = .empty,
    lives: u64 = 0,
    /// The first rule the task saw broken, and how many times one was.
    problem: ?[]const u8 = null,
    problems: usize = 0,

    fn init(load: *Load, index: u8) Mixer {
        return .{
            .load = load,
            .index = index,
            .owner = .{ 'w', '0' + index / 10, '0' + index % 10 },
            .declares = index % 2 == 0,
            .rng = .init(index),
            .arena = .init(testing.allocator),
        };
    }

    fn deinit(m: *Mixer) void {
        m.arena.deinit();
        m.held.deinit(testing.allocator);
        m.claims.deinit(testing.allocator);
        m.quiets.deinit(testing.allocator);
    }

    fn run(m: *Mixer) void {
        defer _ = m.load.done.fetchAdd(1, .release);
        while (!m.load.stop.load(.acquire)) {
            _ = m.arena.reset(.retain_capacity);
            m.step(m.rng.random()) catch |err| m.fail(@errorName(err));
            io.sleep(.fromMicroseconds(50), .awake) catch return;
        }
    }

    fn fail(m: *Mixer, problem: []const u8) void {
        if (m.problem == null) m.problem = problem;
        m.problems += 1;
    }

    fn see(m: *Mixer, r: Record) void {
        if (shape(r)) |problem| m.fail(problem);
    }

    fn options(m: *Mixer) Store.CallOptions {
        return .{ .allocator = m.arena.allocator() };
    }

    fn step(m: *Mixer, r: std.Random) !void {
        const store = m.load.store;
        const slot = &slots[r.uintLessThan(usize, slots.len)];
        const later: Store.Moment = .{ .after = .fromMilliseconds(r.intRangeAtMost(i64, -200, 300)) };
        switch (r.uintLessThan(u8, 15)) {
            0, 1 => {
                m.lives += 1;
                var life: scheduler.Life = @splat(0);
                life[0] = m.index;
                std.mem.writeInt(u64, life[1..9], m.lives, .little);
                _ = try store.create(io, .root, &.{ .job = slot.job, .key = slot.key, .life = life, .plan = "", .payload = "{}", .run_at = later }, m.options());
            },
            2 => if (try store.get(io, .root, slot, m.options())) |rec| m.see(rec),
            3, 4 => try m.update(slot, later, r),
            // Records of "a" are never removed by the client: a claim that a
            // task drops lives until its lease ends, and another claim takes
            // it over.
            5 => _ = try store.remove(io, .root, &slots[8 + r.uintLessThan(usize, 9)], m.options()),
            6 => try m.list(),
            7, 8, 9 => try m.claim(r),
            10 => if (m.held.items.len != 0) {
                const i = r.uintLessThan(usize, m.held.items.len);
                const h = m.held.items[i];
                const renewed = try store.renew(io, .root, &.{ .ref = slots[h.slot], .life = h.life, .owner = &m.owner, .fence = h.fence, .lease = .fromSeconds(1) }, m.options());
                if (renewed != .renewed) _ = m.held.swapRemove(i);
            },
            11, 12, 13 => try m.finish(later, r),
            else => try m.history(slot, r),
        }
    }

    /// A change of the client that fits the state the record has.
    fn update(m: *Mixer, slot: *const scheduler.Ref, later: Store.Moment, r: std.Random) !void {
        const store = m.load.store;
        const now = (try store.get(io, .root, slot, m.options())) orelse return;
        m.see(now);
        const set: Store.Patch = switch (now.state) {
            .pending => switch (r.uintLessThan(u8, 3)) {
                0 => .{ .state = .paused },
                1 => .{ .run_at = later },
                else => .{ .pause_requested = r.boolean() },
            },
            .paused => if (r.boolean()) .{ .state = .pending } else .{ .run_at = later },
            .running => if (r.boolean()) .{ .pause_requested = true } else .{ .run_at = later },
            .succeeded, .failed => if (r.boolean()) .{ .reset = true } else .{ .reset = true, .state = .paused },
        };
        const request: Store.UpdateRequest = .{ .ref = slot.*, .expect = .{ .revision = now.revision, .state = now.state }, .set = set, .tag = @splat(m.index) };
        switch (try store.update(io, .root, &request, m.options())) {
            .updated => |revision| {
                if (revision != now.revision + 1) m.fail("update raised the revision by other than 1");
                const paused = if (set.state) |state| state == .paused else false;
                if (paused) try m.quiets.append(testing.allocator, .{ .quiet = .{ .life = now.life, .revision = revision }, .fence = 0 });
            },
            .conflict => |rec| m.see(rec),
            .not_found => {},
        }
    }

    /// Every page of all the records: each key once, in the order (job, key).
    fn list(m: *Mixer) !void {
        var after: ?[]const u8 = null;
        var previous: ?scheduler.Ref = null;
        while (true) {
            const page = try m.load.store.list(io, .root, &.{ .filter = .{}, .page = .{ .after = after, .limit = 5 } }, m.options());
            for (page.records) |rec| {
                m.see(rec);
                const ref: scheduler.Ref = .{ .job = rec.job, .key = rec.key };
                if (previous) |p| if (orderRef(p, ref) != .lt) m.fail("list gave a key twice or out of the order (job, key)");
                previous = ref;
            }
            after = page.next orelse return;
        }
    }

    fn claim(m: *Mixer, r: std.Random) !void {
        if (m.held.items.len >= 8) return;
        const result = try m.load.store.claim(io, .root, &.{
            .owner = &m.owner,
            .any_key = if (m.declares) &.{ "a", "b" } else &.{"a"},
            .keyed_only = if (m.declares) &.{} else &.{"b"},
            .max = r.intRangeAtMost(u32, 1, 3),
            .lease = .fromSeconds(1),
            .tag = @splat(m.index),
        }, m.options());
        for (result.claimed) |c| {
            const rec = c.record;
            m.see(rec);
            if (rec.state != .running or !std.mem.eql(u8, rec.owner orelse "", &m.owner)) m.fail("a claim gave a record that is not running, or of another owner");
            if (rec.key.len == 0 and !m.declares) m.fail("a claim gave a declared record to a task that does not declare its job");
            const slot = slotOf(rec) orelse {
                m.fail("a claim gave a record of no slot");
                continue;
            };
            try m.claims.append(testing.allocator, .{ .life = rec.life, .fence = rec.fence, .revision = rec.revision });
            try m.held.append(testing.allocator, .{
                .slot = slot,
                .life = rec.life,
                .fence = rec.fence,
                .revision = rec.revision,
                .attempt = rec.attempt,
                .scheduled_at = rec.scheduled_at,
                .claimed_at = rec.claimed_at orelse .fromUnixMs(0),
            });
        }
    }

    /// Ends a held claim with any kind of next, or drops it as a lost
    /// instance would: after its lease, another claim takes it over.
    fn finish(m: *Mixer, later: Store.Moment, r: std.Random) !void {
        if (m.held.items.len == 0) return;
        const i = r.uintLessThan(usize, m.held.items.len);
        const h = m.held.items[i];
        const next: Store.Next = switch (r.uintLessThan(u8, 6)) {
            0 => .{ .wait = .{ .state = .pending, .run_at = later, .scheduled_at = null, .attempt = h.attempt } },
            1 => .{ .wait = .{ .state = .paused, .run_at = later, .scheduled_at = h.scheduled_at, .attempt = 0 } },
            2 => .{ .done = .{ .state = .succeeded, .keep = .{ .keep_for = .fromMilliseconds(300) } } },
            3 => .{ .done = .{ .state = .failed, .keep = .forever } },
            4 => .delete,
            else => {
                _ = m.held.swapRemove(i);
                return;
            },
        };
        const ref = slots[h.slot];
        const row: scheduler.Run = .{
            .job = ref.job,
            .key = ref.key,
            .tenant = null,
            .life = h.life,
            .fence = h.fence,
            .attempt = h.attempt,
            .scheduled_at = h.scheduled_at,
            .started_at = h.claimed_at,
            .finished_at = h.claimed_at,
            .outcome = if (r.boolean()) .succeeded else .abandoned,
            .error_name = null,
            .instance = &m.owner,
            .expires_at = null,
        };
        const result = try m.load.store.finish(io, .root, &.{
            .ref = ref,
            .life = h.life,
            .owner = &m.owner,
            .fence = h.fence,
            .revision = h.revision,
            .tag = @splat(m.index),
            .next = next,
            .last = .{ .outcome = .succeeded, .error_name = null, .attempt = h.attempt, .started_at = h.claimed_at, .finished_at = h.claimed_at },
            .history = .{ .runs = &.{row}, .keep = if (r.boolean()) .{ .keep_for = .fromSeconds(1) } else .forever },
        }, m.options());
        switch (result) {
            .done => {
                _ = m.held.swapRemove(i);
                const quiet = switch (next) {
                    .wait => |w| w.state == .paused,
                    .done => true,
                    .delete => false,
                };
                if (quiet) try m.quiets.append(testing.allocator, .{ .quiet = .{ .life = h.life, .revision = h.revision }, .fence = h.fence });
            },
            .lost => _ = m.held.swapRemove(i),
            .changed => |rec| {
                m.see(rec);
                // A change of the client during the run: finish again on
                // its revision.
                m.held.items[i].revision = rec.revision;
            },
        }
    }

    /// A page of the history: one row a (life, fence).
    fn history(m: *Mixer, slot: *const scheduler.Ref, r: std.Random) !void {
        const filter: scheduler.HistoryFilter = switch (r.uintLessThan(u8, 3)) {
            0 => .{ .job = slot.job, .key = slot.key },
            1 => .{ .job = slot.job },
            else => .{ .outcome = .abandoned },
        };
        const page = try m.load.store.history(io, .root, &.{ .filter = filter, .page = .{ .limit = 20 } }, m.options());
        for (page.runs, 0..) |row, k| {
            for (page.runs[0..k]) |other| {
                if (std.mem.eql(u8, &row.life, &other.life) and row.fence == other.fence) m.fail("two rows of one (life, fence) in a page of the history");
            }
        }
    }
};

/// Sleeps until `duration` has passed on the awake clock.
fn sleepFor(duration: Io.Duration) !void {
    const until = Io.Clock.awake.now(io).addDuration(duration);
    while (true) {
        const left = Io.Clock.awake.now(io).durationTo(until);
        if (left.nanoseconds <= 0) return;
        try io.sleep(left, .awake);
    }
}

test "16 tasks mix every operation for 3 s and the invariants hold" {
    // Small limits evict under the load, and warn about it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var memory: MemoryStore = .init(testing.allocator, io, .{ .max_history = 64, .max_finished = 4 });
    defer memory.deinit();
    var load: Load = .{ .store = memory.store() };
    var mixers: [16]Mixer = undefined;
    for (&mixers, 0..) |*m, i| m.* = .init(&load, @intCast(i));
    defer for (&mixers) |*m| m.deinit();
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        defer load.stop.store(true, .release);
        for (&mixers) |*m| try group.concurrent(io, Mixer.run, .{m});
        try sleepFor(.fromSeconds(3));
        load.stop.store(true, .release);
        try atLeast(&load.done, mixers.len);
    }

    var problems: usize = 0;
    for (&mixers) |*m| {
        const problem = m.problem orelse continue;
        std.debug.print("task {d}: {s} ({d} times)\n", .{ m.index, problem, m.problems });
        problems += m.problems;
    }
    try testing.expectEqual(@as(usize, 0), problems);
    try checkIndexes(&memory);

    // One record a key, each of the model.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page = try load.store.list(io, .root, &.{ .filter = .{}, .page = .{ .limit = 100 } }, .{ .allocator = arena.allocator() });
    try testing.expect(page.records.len <= slots.len);
    for (page.records, 0..) |rec, k| {
        if (shape(rec)) |problem| {
            std.debug.print("{s}/{s}: {s}\n", .{ rec.job, rec.key, problem });
            return error.TestUnexpectedResult;
        }
        if (k > 0) {
            const before = page.records[k - 1];
            try testing.expectEqual(std.math.Order.lt, orderRef(.{ .job = before.job, .key = before.key }, .{ .job = rec.job, .key = rec.key }));
        }
    }

    // Fences never fell: the claims of a life gave the fences 1, 2, 3, …,
    // each once.
    var claims: std.ArrayList(ClaimNote) = .empty;
    defer claims.deinit(testing.allocator);
    for (&mixers) |*m| try claims.appendSlice(testing.allocator, m.claims.items);
    try testing.expect(claims.items.len > 0);
    std.mem.sort(ClaimNote, claims.items, {}, ClaimNote.lessThan);
    for (claims.items, 0..) |c, k| {
        const first = k == 0 or !std.mem.eql(u8, &claims.items[k - 1].life, &c.life);
        const expected = if (first) 1 else claims.items[k - 1].fence + 1;
        if (c.fence != expected) {
            std.debug.print("a claim gave fence {d} where {d} was due\n", .{ c.fence, expected });
            return error.TestUnexpectedResult;
        }
    }

    // No paused or finished record was ever claimed: no claim after the
    // one that made a record quiet came at the revision it had then.
    var quiets: std.AutoHashMapUnmanaged(Quiet, u64) = .empty;
    defer quiets.deinit(testing.allocator);
    for (&mixers) |*m| {
        for (m.quiets.items) |q| {
            const entry = try quiets.getOrPut(testing.allocator, q.quiet);
            entry.value_ptr.* = if (entry.found_existing) @min(entry.value_ptr.*, q.fence) else q.fence;
        }
    }
    try testing.expect(quiets.count() > 0);
    for (claims.items) |c| {
        const fence = quiets.get(.{ .life = c.life, .revision = c.revision }) orelse continue;
        if (c.fence > fence) {
            std.debug.print("claim {d} took a record paused or finished at revision {d}\n", .{ c.fence, c.revision });
            return error.TestUnexpectedResult;
        }
    }
}
