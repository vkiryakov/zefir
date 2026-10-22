//! 10,000 tasks at once on a pool of 32 connections, twice. Each task
//! increments one counter with INCR: the counter ends at 10,000, and the
//! replies are 1 to 10,000, each once, so that no reply went to another
//! call. The pool never holds more than 32 connections, open or opening,
//! and after each round it is at rest, every connection idle; the client's
//! memory stays within its bounds, at the peak and after each round, and
//! all of it comes back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("e2e");
const stress = @import("root.zig");

const tasks = 10_000;
const rounds = 2;
const max_connections = 32;
/// The deadline of each call: a call waits in line behind thousands.
const deadline: Io.Duration = .fromSeconds(120);
const counter = "stress:load:counter";

/// A round of tasks, and what they got.
const Round = struct {
    client: *redis.Client,
    /// How many times each value of the counter came back, by value.
    seen: []std.atomic.Value(u32),
    ok: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),

    fn task(r: *Round, io: Io, i: usize) Io.Cancelable!void {
        defer _ = r.done.fetchAdd(1, .acq_rel);
        var d: redis.Diagnostics = .{};
        const value = r.client.run(io, stress.within(io, deadline), cmd.incr(counter), .{ .diagnostics = &d }) catch |err| {
            if (r.failed.fetchAdd(1, .monotonic) == 0) std.debug.print("  task {d}: {t}: {s}\n", .{ i, err, d.message() });
            return;
        };
        if (value < 1 or value > tasks) {
            if (r.failed.fetchAdd(1, .monotonic) == 0) std.debug.print("  task {d}: INCR gave {d}\n", .{ i, value });
            return;
        }
        _ = r.seen[@intCast(value - 1)].fetchAdd(1, .monotonic);
        _ = r.ok.fetchAdd(1, .monotonic);
    }
};

/// A call that must pass.
fn must(io: Io, client: *redis.Client, command: anytype) !redis.Client.ReplyOf(@TypeOf(command)) {
    var d: redis.Diagnostics = .{};
    return client.run(io, stress.within(io, .fromSeconds(10)), command, .{ .diagnostics = &d }) catch |err| {
        std.debug.print("  {s}: {t}: {s}\n", .{ command.name(), err, d.message() });
        return err;
    };
}

fn tenThousand(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "redis://127.0.0.1:{d}", .{e2e.servers.plain_port});
    var client: redis.Client = undefined;
    try stress.connected(io, &client, &counting, .{ .url = url, .max_connections = max_connections });
    {
        defer client.deinit();
        const seen = try testing.allocator.alloc(std.atomic.Value(u32), tasks);
        defer testing.allocator.free(seen);
        const before = counting.current.load(.monotonic);
        const held_bound = max_connections * stress.bytes_per_connection;
        for (0..rounds) |number| {
            _ = try must(io, &client, cmd.del(&.{counter}));
            @memset(seen, .init(0));
            _ = counting.resetPeak();
            var round: Round = .{ .client = &client, .seen = seen };
            const began = Io.Clock.awake.now(io);
            var peak_connections: usize = 0;
            {
                var group: Io.Group = .init;
                defer group.cancel(io);
                for (0..tasks) |i| try group.concurrent(io, Round.task, .{ &round, io, i });
                // Never more than max_connections connections, open or
                // opening.
                while (round.done.load(.acquire) < tasks) {
                    const stats = client.stats();
                    peak_connections = @max(peak_connections, stats.connections + stats.opening);
                    if (stress.elapsedSince(io, began).toSeconds() >= 200) return error.TestRoundNeverEnded;
                    try io.sleep(.fromMilliseconds(1), .awake);
                }
                try group.await(io);
            }
            const took = stress.elapsedSince(io, began);
            const peak = counting.peak.load(.monotonic) -| before;
            const held = counting.current.load(.monotonic) -| before;
            const stats = client.stats();
            std.debug.print("  10,000 tasks, round {d}: {d} ms, {d} connections at most; client heap: peak {d} KiB, {d} KiB held after (bound {d} KiB); process max RSS {?d} MiB\n", .{
                number + 1, took.toMilliseconds(), peak_connections, peak / 1024, held / 1024, held_bound / 1024, stress.maxRssMiB(),
            });
            if (round.ok.load(.monotonic) != tasks) {
                std.debug.print("  {d} tasks ok, {d} failed\n", .{ round.ok.load(.monotonic), round.failed.load(.monotonic) });
                return error.TestTasksFailed;
            }
            // Each value once: every call got its own reply.
            for (seen, 1..) |*count, value| {
                if (count.load(.monotonic) == 1) continue;
                std.debug.print("  INCR gave {d} {d} times\n", .{ value, count.load(.monotonic) });
                return error.TestRepliesMixed;
            }
            try testing.expectEqual(@as(?i64, tasks), try must(io, &client, cmd.get(i64, counter)));
            try testing.expect(peak_connections <= max_connections);
            try stress.expectAtRest(stats);
            try testing.expectEqual(@as(u64, 0), stats.clears);
            try testing.expect(peak <= held_bound);
            try testing.expect(held <= held_bound);
        }
        _ = try must(io, &client, cmd.del(&.{counter}));
    }
    // deinit gave back all the client held.
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

test "10,000 tasks at once on a pool of 32, twice: the counter ends at 10,000 with each reply once, the pool stays within its size and comes back to rest, and the client's memory stays within its bounds" {
    try stress.onZio(tenThousand);
}
