//! 10,000 tasks at once on a pool of 100 connections, twice. Each task
//! inserts a document, reads it back and pings, and every 50th also reads
//! a collection of 1,000 documents through a cursor of batches of 100.
//! Every call succeeds; the pool never holds more than 100 connections,
//! open or opening, and after each round it is at rest, every connection
//! idle; the client's memory stays within its bounds, at the peak and
//! after each round, and all of it comes back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("e2e");
const stress = @import("root.zig");

const tasks = 10_000;
const rounds = 2;
const max_pool_size = 100;
/// Every this many tasks reads `cursor_docs` documents through a cursor.
const reader_every = 50;
const cursor_docs = 1_000;
const cursor_batch = 100;
/// The deadline of each call: a call waits in line behind thousands.
const deadline: Io.Duration = .fromSeconds(120);

/// What a cursor holds of the client's memory besides its batch: its
/// state, its namespace and the reply of its batch, with a margin.
const bytes_per_cursor = 64 * 1024;

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

fn within(io: Io) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), deadline)));
}

/// A round of tasks, and what they got.
const Round = struct {
    db: mongo.Database,
    number: usize,
    ok: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),

    fn task(r: *Round, io: Io, i: usize) Io.Cancelable!void {
        defer _ = r.done.fetchAdd(1, .acq_rel);
        var d: mongo.Diagnostics = .{};
        r.calls(io, i, &d) catch |err| {
            if (r.failed.fetchAdd(1, .monotonic) == 0) std.debug.print("  task {d}: {t}: {s}\n", .{ i, err, d.message() });
            return;
        };
        _ = r.ok.fetchAdd(1, .monotonic);
    }

    fn calls(r: *Round, io: Io, i: usize, d: *mongo.Diagnostics) !void {
        const id: i64 = @intCast(r.number * tasks + i);
        const docs = r.db.collection("load");
        var inserted = try docs.insertOne(io, within(io), .{ ._id = id, .n = id }, .{ .allocator = testing.allocator, .diagnostics = d });
        inserted.deinit(testing.allocator);
        const found = (try docs.findOne(io, within(io), .{ ._id = id }, .{ .allocator = testing.allocator, .diagnostics = d })) orelse return error.TestNotFound;
        defer found.deinit();
        const n = (try found.raw().get("n")) orelse return error.TestNoField;
        if (try n.asI64() != id) return error.TestWrongDocument;
        const pong = try r.db.client.runCommand(io, within(io), ping, .{ .allocator = testing.allocator, .diagnostics = d });
        pong.deinit();
        if (i % reader_every != 0) return;
        const op = within(io);
        const cursor = try r.db.collection("cursor").find(io, op, .{}, .{ .allocator = testing.allocator, .batch_size = cursor_batch, .diagnostics = d });
        defer cursor.deinit(io);
        var count: usize = 0;
        // The cursor keeps the errors of its getMores.
        while (cursor.next(io, op) catch |err| {
            d.* = cursor.diagnostics().*;
            return err;
        }) |_| count += 1;
        if (count != cursor_docs) return error.TestWrongCount;
    }
};

fn tenThousand(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var buffer: [128]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}/?appName=zefir-stress-load&maxPoolSize={d}&serverSelectionTimeoutMS=120000", .{ e2e.servers.plain_port, max_pool_size });
    var client: mongo.Client = try .init(counting.allocator(), io, .{ .uri = uri });
    var d: mongo.Diagnostics = .{};
    client.connect(io, within(io).ctx, &d) catch |err| {
        std.debug.print("  connect: {t}: {s}\n", .{ err, d.message() });
        client.deinit();
        return err;
    };
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(&client, "zefir_stress", &ids);
    {
        defer client.deinit();
        try db.drop(io, within(io), .{ .allocator = testing.allocator });
        defer db.drop(io, within(io), .{ .allocator = testing.allocator }) catch {};
        try fill(io, db);

        const before = counting.current.load(.monotonic);
        const held_bound = max_pool_size * stress.bytes_per_connection;
        const peak_bound = held_bound + (tasks / reader_every) * bytes_per_cursor;
        for (0..rounds) |number| {
            _ = counting.resetPeak();
            var round: Round = .{ .db = db, .number = number };
            const began = Io.Clock.awake.now(io);
            var peak_connections: usize = 0;
            {
                var group: Io.Group = .init;
                defer group.cancel(io);
                for (0..tasks) |i| try group.concurrent(io, Round.task, .{ &round, io, i });
                // Never more than maxPoolSize connections, open or opening.
                while (round.done.load(.acquire) < tasks) {
                    const stats = client.stats();
                    peak_connections = @max(peak_connections, stats.connections + stats.opening);
                    if (stress.elapsedSince(io, began).toSeconds() >= 300) return error.TestRoundNeverEnded;
                    try io.sleep(.fromMilliseconds(1), .awake);
                }
                try group.await(io);
            }
            const took = stress.elapsedSince(io, began);
            const peak = counting.peak.load(.monotonic) -| before;
            const held = counting.current.load(.monotonic) -| before;
            const stats = client.stats();
            std.debug.print("  10,000 tasks, round {d}: {d} ms, {d} connections at most; client heap: peak {d} KiB (bound {d} KiB), {d} KiB held after (bound {d} KiB); process max RSS {?d} MiB\n", .{
                number + 1, took.toMilliseconds(), peak_connections, peak / 1024, peak_bound / 1024, held / 1024, held_bound / 1024, stress.maxRssMiB(),
            });
            if (round.ok.load(.monotonic) != tasks) {
                std.debug.print("  {d} tasks ok, {d} failed\n", .{ round.ok.load(.monotonic), round.failed.load(.monotonic) });
                return error.TestTasksFailed;
            }
            try testing.expect(peak_connections <= max_pool_size);
            try testing.expectEqual(stats.connections, stats.idle);
            try testing.expectEqual(@as(usize, 0), stats.in_use + stats.opening + stats.waiting + stats.open_cursors);
            try testing.expectEqual(@as(u64, 0), stats.clears);
            try testing.expect(peak <= peak_bound);
            try testing.expect(held <= held_bound);
        }
        const count = try db.collection("load").countDocuments(io, within(io), .{}, .{ .allocator = testing.allocator });
        try testing.expectEqual(@as(u64, tasks * rounds), count);
    }
    // deinit gave back all the client held.
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

/// The collection that the readers read: `cursor_docs` documents.
fn fill(io: Io, db: mongo.Database) !void {
    const Doc = struct { _id: i64, n: i64 };
    var docs: [cursor_docs]Doc = undefined;
    for (&docs, 0..) |*doc, i| doc.* = .{ ._id = @intCast(i), .n = @intCast(i) };
    var result = try db.collection("cursor").insertMany(io, within(io), @as([]const Doc, &docs), .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, cursor_docs), result.inserted);
}

test "10,000 tasks at once on a pool of 100, twice: every call succeeds, the pool stays within its size and comes back to rest, and the client's memory stays within its bounds" {
    try stress.onZio(tenThousand);
}
