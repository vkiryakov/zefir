//! Stress tests of the queued mode: many producers, an oracle for every
//! record, and counters that must add up.

const std = @import("std");
const log = @import("../root.zig");
const testing = std.testing;

const producers = 8;
const per_producer = 2000;
const max_producers = alphabet.len;
/// One letter per producer, none of them escaped in JSON.
const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";

/// The oracle's mark: producer `p`'s record `i` carries a pattern of its
/// own, so a record mixed with another or cut short shows.
fn pattern(buf: *[64]u8, p: usize, i: usize) []const u8 {
    const len = 1 + (i * 7 + p) % 40;
    @memset(buf[0..len], alphabet[p]);
    return buf[0..len];
}

fn produce(logger: log.Logger, p: usize, count: usize) void {
    var buf: [64]u8 = undefined;
    for (0..count) |i| logger.info("stress", .{ .producer = p, .seq = i, .pattern = pattern(&buf, p, i) });
}

/// Runs `n` producer threads of `count` records each, and waits for them.
fn runProducers(logger: log.Logger, n: usize, count: usize) !void {
    var threads: [max_producers]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (threads[0..n], 0..) |*t, p| {
        t.* = try std.Thread.spawn(.{}, produce, .{ logger, p, count });
        spawned += 1;
    }
}

/// The value of field `name` in a JSON record: a number, or a string
/// without escapes.
fn field(line: []const u8, comptime name: []const u8) ![]const u8 {
    const key = "\"" ++ name ++ "\":";
    const at = std.mem.find(u8, line, key) orelse return error.TestFieldMissing;
    const rest = line[at + key.len ..];
    if (rest.len > 0 and rest[0] == '"') {
        const end = std.mem.findScalar(u8, rest[1..], '"') orelse return error.TestFieldMissing;
        return rest[1..][0..end];
    }
    const end = std.mem.findAny(u8, rest, ",}") orelse return error.TestFieldMissing;
    return rest[0..end];
}

const Oracle = struct {
    next: [max_producers]usize = @splat(0),
    delivered: [max_producers]usize = @splat(0),

    /// Checks one record: valid JSON with its producer's pattern, after
    /// that producer's previous record (`gapless`: right after it).
    fn check(o: *Oracle, line: []const u8, gapless: bool) !void {
        if (!try std.json.validate(testing.allocator, line)) return error.TestInvalidRecord;
        const p = try std.fmt.parseInt(usize, try field(line, "producer"), 10);
        const i = try std.fmt.parseInt(usize, try field(line, "seq"), 10);
        if (p >= max_producers) return error.TestUnknownProducer;
        var buf: [64]u8 = undefined;
        if (!std.mem.eql(u8, pattern(&buf, p, i), try field(line, "pattern"))) return error.TestWrongPattern;
        if (gapless and i != o.next[p]) return error.TestOutOfOrder;
        if (i < o.next[p]) return error.TestOutOfOrder;
        o.next[p] = i + 1;
        o.delivered[p] += 1;
    }

    fn checkAll(o: *Oracle, out: []const u8, gapless: bool) !void {
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) try o.check(line, gapless);
        }
    }

    fn total(o: Oracle) u64 {
        var sum: u64 = 0;
        for (o.delivered) |n| sum += n;
        return sum;
    }
};

/// Records of producer 0, as the logger writes them.
fn records(out: *std.Io.Writer.Allocating, seqs: []const usize) !void {
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{ .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    for (seqs) |i| {
        var buf: [64]u8 = undefined;
        logger.info("stress", .{ .producer = 0, .seq = i, .pattern = pattern(&buf, 0, i) });
    }
}

test "the oracle catches a doubled, a reordered, a cut and a mixed record" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try records(&out, &.{ 0, 1, 2 });
    var good: Oracle = .{};
    try good.checkAll(out.written(), true);
    try testing.expectEqual(@as(u64, 3), good.total());

    out.clearRetainingCapacity();
    try records(&out, &.{ 0, 1, 1 });
    var doubled: Oracle = .{};
    try testing.expectError(error.TestOutOfOrder, doubled.checkAll(out.written(), false));

    out.clearRetainingCapacity();
    try records(&out, &.{ 0, 2, 1 });
    var reordered: Oracle = .{};
    try testing.expectError(error.TestOutOfOrder, reordered.checkAll(out.written(), false));

    out.clearRetainingCapacity();
    try records(&out, &.{ 0, 2 });
    var gap: Oracle = .{};
    try testing.expectError(error.TestOutOfOrder, gap.checkAll(out.written(), true));

    out.clearRetainingCapacity();
    try records(&out, &.{0});
    var cut: Oracle = .{};
    try testing.expectError(error.TestInvalidRecord, cut.checkAll(out.written()[0 .. out.written().len - 5], true));

    var mixed: Oracle = .{};
    try testing.expectError(error.TestWrongPattern, mixed.checkAll("{\"producer\":0,\"seq\":0,\"pattern\":\"b\"}", true));
}

/// `n` producers in block mode: every record comes out once, each
/// producer's in its order.
fn expectBlockDeliversAll(n: usize) !void {
    const count = producers * per_producer / n;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 64, .batch_size = 16, .overflow = .block } },
        .output = .{ .writer = &out.writer },
    });
    defer logger.deinit();
    try runProducers(logger, n, count);
    try logger.flush(.none);
    var oracle: Oracle = .{};
    try oracle.checkAll(out.written(), true);
    for (oracle.delivered[0..n]) |delivered| try testing.expectEqual(count, delivered);
    const s = logger.stats();
    try testing.expectEqual(@as(u64, n * count), s.written);
    try testing.expectEqual(@as(u64, 0), s.dropped.queue_full + s.dropped.closed + s.dropped.write_failed);
}

test "block: 1, 2, 8 and twice as many producers as CPUs lose and double nothing, each in its order" {
    const cpus = std.Thread.getCpuCount() catch 4;
    // Twice the CPUs: producers get preempted between reserving and
    // publishing.
    for ([_]usize{ 1, 2, producers, @min(2 * cpus, max_producers) }) |n| try expectBlockDeliversAll(n);
}

/// Keeps what it is given, after 20 us per write: a slow reader.
const SlowSink = struct {
    out: std.Io.Writer.Allocating,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const sink: *SlowSink = @alignCast(@fieldParentPtr("writer", w));
        testing.io.sleep(.fromMicroseconds(20), .awake) catch {};
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            sink.out.writer.writeAll(bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| sink.out.writer.writeAll(data[data.len - 1]) catch return error.WriteFailed;
        return n + data[data.len - 1].len * splat;
    }
};

test "block with a slow writer: producers wait, and nothing is lost or doubled" {
    var sink: SlowSink = .{ .out = .init(testing.allocator) };
    defer sink.out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 16, .batch_size = 4, .overflow = .block } },
        .output = .{ .writer = &sink.writer },
    });
    defer logger.deinit();
    try runProducers(logger, producers, 250);
    try logger.flush(.none);
    var oracle: Oracle = .{};
    try oracle.checkAll(sink.out.written(), true);
    for (oracle.delivered[0..producers]) |delivered| try testing.expectEqual(@as(usize, 250), delivered);
}

test "drop_new: what came out and what was dropped add up, each producer's records in order" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 16, .batch_size = 4 } },
        .output = .{ .writer = &out.writer },
    });
    defer logger.deinit();
    try runProducers(logger, producers, per_producer);
    try logger.flush(.none);
    var oracle: Oracle = .{};
    try oracle.checkAll(out.written(), false);
    const s = logger.stats();
    try testing.expectEqual(oracle.total(), s.written);
    try testing.expectEqual(@as(u64, producers * per_producer), s.written + s.dropped.queue_full);
}

fn produceAtTwoLevels(logger: log.Logger, p: usize, count: usize) void {
    const handle = logger.scoped("stress.levels");
    var buf: [64]u8 = undefined;
    for (0..count) |i| {
        const fields = .{ .producer = p, .seq = i, .pattern = pattern(&buf, p, i) };
        if (i % 2 == 0) handle.info("stress", fields) else handle.debug("stress", fields);
    }
}

fn changeLevels(logger: log.Logger, done: *std.atomic.Value(bool)) void {
    var round: usize = 0;
    while (!done.load(.seq_cst)) : (round += 1) {
        logger.setLevel(if (round % 2 == 0) .debug else .info);
        logger.setScopeLevel("stress", if (round % 3 == 0) .debug else null) catch {};
        std.Thread.yield() catch {};
    }
}

test "levels change while 8 producers log: nothing that passes is lost, mixed or torn" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 64, .batch_size = 16, .overflow = .block } },
        .output = .{ .writer = &out.writer },
    });
    defer logger.deinit();
    var done: std.atomic.Value(bool) = .init(false);
    const changer = try std.Thread.spawn(.{}, changeLevels, .{ logger, &done });
    {
        defer {
            done.store(true, .seq_cst);
            changer.join();
        }
        var threads: [producers]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        for (&threads, 0..) |*t, p| {
            t.* = try std.Thread.spawn(.{}, produceAtTwoLevels, .{ logger, p, per_producer });
            spawned += 1;
        }
    }
    try logger.flush(.none);
    var oracle: Oracle = .{};
    try oracle.checkAll(out.written(), false);
    const s = logger.stats();
    try testing.expectEqual(s.accepted, s.written);
    try testing.expectEqual(oracle.total(), s.written);
    // Every info record passes: the levels only ever let more through.
    try testing.expect(s.written >= producers * per_producer / 2);
}

test "shutdown while 8 producers log: each producer's records that came out are its first ones" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 64, .batch_size = 16, .overflow = .block } },
        .output = .{ .writer = &out.writer },
    });
    defer logger.deinit();
    {
        var threads: [producers]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        for (&threads, 0..) |*t, p| {
            t.* = try std.Thread.spawn(.{}, produce, .{ logger, p, per_producer });
            spawned += 1;
        }
        while (logger.stats().written < producers * per_producer / 4) std.Thread.yield() catch {};
        try logger.shutdown(.none);
    }
    var oracle: Oracle = .{};
    try oracle.checkAll(out.written(), true);
    const s = logger.stats();
    try testing.expectEqual(oracle.total(), s.written);
    try testing.expectEqual(@as(u64, producers * per_producer), s.written + s.dropped.closed);
    try testing.expectEqual(@as(u64, 0), s.dropped.queue_full + s.dropped.write_failed);
}

test "flush after each record: no wake-up of the writer thread or of flush is lost" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, testing.io, .{
        .mode = .{ .queued = .{ .capacity = 4, .batch_size = 1 } },
        .output = .{ .writer = &out.writer },
    });
    defer logger.deinit();
    // A lost wake-up of the writer thread would sleep until its recheck a
    // second later, past the timeout. One of flush would sleep out the
    // whole timeout and then find the record written, so each flush is
    // timed too.
    const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(900), .clock = .awake } };
    var buf: [64]u8 = undefined;
    for (0..500) |i| {
        logger.info("stress", .{ .producer = 0, .seq = i, .pattern = pattern(&buf, 0, i) });
        const start = std.Io.Clock.awake.now(testing.io);
        try logger.flush(patience);
        try testing.expect(start.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 800 * std.time.ns_per_ms);
    }
    var oracle: Oracle = .{};
    try oracle.checkAll(out.written(), true);
    try testing.expectEqual(@as(usize, 500), oracle.delivered[0]);
}
