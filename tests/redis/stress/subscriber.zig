//! A subscriber under a stream of 100,000 messages: a publisher sends them
//! to a channel in pipelines of 1,000 PUBLISH commands, and the
//! subscriber, in a task of its own, gets every one of them, in order and
//! byte for byte: most a few dozen bytes, and every 1,000th 100 KiB,
//! larger than its read buffer. Each PUBLISH reaches the one subscriber;
//! the publisher keeps at most 20,000 messages ahead of it, far below the
//! server's client-output-buffer-limit for subscribers. The client's
//! memory stays within its bound and comes back at deinit.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("e2e");
const stress = @import("root.zig");

const messages = 100_000;
const batch = 1_000;
/// How far the publisher may run ahead of the subscriber, in messages.
const ahead = 20_000;
const big_every = 1_000;
const big_len = 100 * 1024;
const channel = "stress:subscriber:stream";

/// The length of the payload of message `i`.
fn lengthOf(i: usize) usize {
    return if (i % big_every == big_every - 1) big_len else 8 + i % 57;
}

/// The payload of message `i`: its number in 8 bytes, then bytes that
/// depend on it.
fn fill(payload: []u8, i: usize) void {
    std.mem.writeInt(u64, payload[0..8], i, .little);
    for (payload[8..], 8..) |*b, j| b.* = @truncate(i *% 31 +% j);
}

/// The subscriber's side: every message, checked against the one the
/// publisher made.
const Reading = struct {
    sub: *redis.Subscriber,
    /// Messages that came as they should.
    got: std.atomic.Value(usize) = .init(0),

    fn run(r: *Reading, io: Io) anyerror!void {
        const expected = try testing.allocator.alloc(u8, big_len);
        defer testing.allocator.free(expected);
        for (0..messages) |i| {
            const message = r.sub.next(io) catch |err| {
                std.debug.print("  message {d}: {t}: {s}\n", .{ i, err, r.sub.diagnostics().message() });
                return err;
            } orelse return error.TestSubscriberClosed;
            const want = expected[0..lengthOf(i)];
            fill(want, i);
            if (!std.mem.eql(u8, channel, message.channel) or message.pattern != null or !std.mem.eql(u8, want, message.payload)) {
                const number = if (message.payload.len >= 8) std.mem.readInt(u64, message.payload[0..8], .little) else 0;
                std.debug.print("  message {d}: {d} bytes of channel {s}, numbered {d}\n", .{ i, message.payload.len, message.channel, number });
                return error.TestWrongMessage;
            }
            r.got.store(i + 1, .release);
        }
    }
};

fn hundredThousand(io: Io) !void {
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "redis://127.0.0.1:{d}", .{e2e.servers.plain_port});
    var client: redis.Client = undefined;
    try stress.connected(io, &client, &counting, .{ .url = url });
    {
        defer client.deinit();
        const before = counting.resetPeak();
        var d: redis.Diagnostics = .{};
        var sub = client.subscribe(io, stress.within(io, .fromSeconds(10)), .{ .channels = &.{channel}, .diagnostics = &d }) catch |err| {
            std.debug.print("  subscribe: {t}: {s}\n", .{ err, d.message() });
            return err;
        };
        defer sub.close(io);
        var reading: Reading = .{ .sub = &sub };
        var reader = try io.concurrent(Reading.run, .{ &reading, io });
        defer if (reader.cancel(io)) |_| {} else |_| {};

        const began = Io.Clock.awake.now(io);
        const payloads = try testing.allocator.alloc(u8, big_len + batch * (8 + 57));
        defer testing.allocator.free(payloads);
        var commands: [batch]cmd.Publish = undefined;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var sent: usize = 0;
        while (sent < messages) : (sent += batch) {
            // The subscriber within `ahead` messages, or a wait for it.
            const waited = Io.Clock.awake.now(io);
            while (sent - reading.got.load(.acquire) > ahead) {
                if (stress.elapsedSince(io, waited).toSeconds() >= 30) {
                    std.debug.print("  the subscriber got no further than message {d} in 30 s\n", .{reading.got.load(.acquire)});
                    return error.TestSubscriberStuck;
                }
                try io.sleep(.fromMilliseconds(1), .awake);
            }
            var at: usize = 0;
            for (&commands, sent..) |*command, i| {
                const payload = payloads[at..][0..lengthOf(i)];
                at += payload.len;
                fill(payload, i);
                command.* = cmd.publish(channel, payload);
            }
            _ = arena.reset(.retain_capacity);
            const results = client.pipeline(io, stress.within(io, .fromSeconds(30)), @as([]const cmd.Publish, &commands), .{ .allocator = arena.allocator(), .diagnostics = &d }) catch |err| {
                std.debug.print("  the pipeline of messages {d}..: {t}: {s}\n", .{ sent, err, d.message() });
                return err;
            };
            for (results) |result| try testing.expectEqual(@as(u64, 1), try result);
        }
        try stress.awaitCount(io, &reading.got, messages, .fromSeconds(60));
        try reader.await(io);
        const took = stress.elapsedSince(io, began);
        const peak = counting.peak.load(.monotonic) -| before;
        // The pool's connection, the subscriber's, and its buffer, which
        // grows to hold the largest message.
        const peak_bound = 2 * stress.bytes_per_connection + 2 * big_len;
        std.debug.print("  100,000 messages in {d} ms; client heap: peak {d} KiB (bound {d} KiB); process max RSS {?d} MiB\n", .{ took.toMilliseconds(), peak / 1024, peak_bound / 1024, stress.maxRssMiB() });
        try testing.expect(peak <= peak_bound);
        try testing.expectEqual(@as(usize, 1), client.stats().subscribers);
    }
    // deinit gave back all the client held.
    try testing.expectEqual(@as(usize, 0), counting.current.load(.monotonic));
}

test "a subscriber under 100,000 messages published in pipelines: every message comes, in order and byte for byte, those larger than its read buffer too, and the client's memory stays within its bound" {
    try stress.onZio(hundredThousand);
}
