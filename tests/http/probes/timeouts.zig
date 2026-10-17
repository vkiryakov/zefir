//! How to time out a read or a write on a socket, the two ways zefir-http
//! can choose from: `io.operateTimeout`, where zio runs one operation with
//! a timer of its own, and a race of the operation with a sleep in an
//! `Io.Select`. The operateTimeout cases must all pass on every system for
//! zefir-http to use that way. On Windows, zio has an open issue (#785):
//! a timed read may end canceled without a timeout, which zio logs as
//! "timed ... canceled without a timeout (#785)" or "net_recv aborted
//! without a cancel request (#785)", and the read then fails.
//!
//! zio arms a timer from the time its loop read at the start of the scan,
//! which can be a fraction of a millisecond before the call: the lower
//! bounds below allow one millisecond for that.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const runtime = @import("runtime");
const probes = @import("root.zig");

const timeout_ms = 200;

test "operateTimeout read: an idle peer times out at 200 ms" {
    try runtime.forEachRuntime(testing.allocator, idleReadTimesOut);
}

fn idleReadTimesOut(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    var buffer: [64]u8 = undefined;
    const start = probes.now(io);
    const result = probes.readTimeout(io, pair.server, &buffer, probes.timeout(timeout_ms));
    const took = probes.since(io, start);
    probes.report("operateTimeout read of an idle peer: {s} after {d:.2} ms", .{ outcome(result), probes.ms(took) });
    try testing.expectError(error.Timeout, result);
    try probes.expectWithin(took, timeout_ms - 1, timeout_ms + 50);
}

test "operateTimeout read: data that comes first is read, and the socket reads again after a timeout" {
    try runtime.forEachRuntime(testing.allocator, dataThenTimeoutThenData);
}

fn dataThenTimeoutThenData(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    var buffer: [64]u8 = undefined;
    // Rounds of a read that gets data at once, then one that times out:
    // a timeout must leave the socket as it was.
    for (0..5) |_| {
        try probes.send(io, pair.client, "ping");
        const start = probes.now(io);
        const n = try probes.readTimeout(io, pair.server, &buffer, probes.timeout(timeout_ms));
        try testing.expectEqualStrings("ping", buffer[0..n]);
        try testing.expect(probes.ms(probes.since(io, start)) < 50);
        try testing.expectError(error.Timeout, probes.readTimeout(io, pair.server, &buffer, probes.timeout(20)));
    }
    try probes.send(io, pair.client, "pong");
    const n = try probes.readTimeout(io, pair.server, &buffer, probes.timeout(timeout_ms));
    try testing.expectEqualStrings("pong", buffer[0..n]);
    probes.report("operateTimeout read: 5 rounds of data, then a timeout; the socket reads after them", .{});
}

test "operateTimeout read: canceling the task returns Canceled within 5 ms" {
    try runtime.forEachRuntime(testing.allocator, cancelTimedRead);
}

fn cancelTimedRead(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    var buffer: [64]u8 = undefined;
    var reader = try io.concurrent(probes.readTimeout, .{ io, pair.server, &buffer, probes.timeout(10_000) });
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = probes.now(io);
    const result = reader.cancel(io);
    const took = probes.since(io, start);
    probes.report("operateTimeout read canceled: {s} after {d:.2} ms", .{ outcome(result), probes.ms(took) });
    try testing.expectError(error.Canceled, result);
    try testing.expect(probes.ms(took) < 5);
}

test "operateTimeout write: a peer that never reads times out" {
    try runtime.forEachRuntime(testing.allocator, writeToIdlePeer);
}

/// What the writes send, until the socket buffers are full.
const chunk: [64 * 1024]u8 = @splat('x');

fn writeToIdlePeer(io: Io) !void {
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    var written: usize = 0;
    while (written < 1 << 30) {
        const start = probes.now(io);
        written += probes.writeTimeout(io, pair.server, &chunk, probes.timeout(timeout_ms)) catch |err| switch (err) {
            error.Timeout => {
                const took = probes.since(io, start);
                probes.report("operateTimeout write to a peer that never reads: Timeout after {d:.2} ms, {d} KiB written before", .{ probes.ms(took), written / 1024 });
                return probes.expectWithin(took, timeout_ms - 1, timeout_ms + 100);
            },
            else => |e| return e,
        };
    }
    return error.TestNoTimeout;
}

test "select race read: the same three cases" {
    try runtime.forEachRuntime(testing.allocator, raceCases);
}

fn raceCases(io: Io) !void {
    var buffer: [64]u8 = undefined;
    {
        const pair = try probes.loopbackPair(io);
        defer pair.close(io);
        const start = probes.now(io);
        const result = probes.raceRead(io, pair.server, &buffer, .fromMilliseconds(timeout_ms));
        const took = probes.since(io, start);
        probes.report("select race read of an idle peer: {s} after {d:.2} ms", .{ outcome(result), probes.ms(took) });
        try testing.expectError(error.Timeout, result);
        try probes.expectWithin(took, timeout_ms - 1, timeout_ms + 50);
    }
    {
        const pair = try probes.loopbackPair(io);
        defer pair.close(io);
        for (0..5) |_| {
            try probes.send(io, pair.client, "ping");
            const start = probes.now(io);
            const n = try probes.raceRead(io, pair.server, &buffer, .fromMilliseconds(timeout_ms));
            try testing.expectEqualStrings("ping", buffer[0..n]);
            try testing.expect(probes.ms(probes.since(io, start)) < 50);
            try testing.expectError(error.Timeout, probes.raceRead(io, pair.server, &buffer, .fromMilliseconds(20)));
        }
        try probes.send(io, pair.client, "pong");
        const n = try probes.raceRead(io, pair.server, &buffer, .fromMilliseconds(timeout_ms));
        try testing.expectEqualStrings("pong", buffer[0..n]);
        probes.report("select race read: 5 rounds of data, then a timeout; the socket reads after them", .{});
    }
    {
        const pair = try probes.loopbackPair(io);
        defer pair.close(io);
        var reader = try io.concurrent(probes.raceRead, .{ io, pair.server, &buffer, .fromSeconds(10) });
        try io.sleep(.fromMilliseconds(50), .awake);
        const start = probes.now(io);
        const result = reader.cancel(io);
        const took = probes.since(io, start);
        probes.report("select race read canceled: {s} after {d:.2} ms", .{ outcome(result), probes.ms(took) });
        try testing.expectError(error.Canceled, result);
        try testing.expect(probes.ms(took) < 5);
    }
    try costPerRead(io);
}

/// What one read costs when the data is there, by way of timing it: a byte
/// is sent and read back `rounds` times, with a plain read, with
/// operateTimeout and with the select race, after a round of plain reads
/// that warms the connection up.
fn costPerRead(io: Io) !void {
    const rounds = 1000;
    const pair = try probes.loopbackPair(io);
    defer pair.close(io);
    var buffer: [64]u8 = undefined;
    for (0..rounds) |_| {
        try probes.send(io, pair.client, "x");
        try testing.expectEqual(1, try probes.readSome(io, pair.server, &buffer));
    }
    var per_read: [3]f64 = undefined;
    for (&per_read, 0..) |*cost, way| {
        const start = probes.now(io);
        for (0..rounds) |_| {
            try probes.send(io, pair.client, "x");
            const n = switch (way) {
                0 => try probes.readSome(io, pair.server, &buffer),
                1 => try probes.readTimeout(io, pair.server, &buffer, probes.timeout(30_000)),
                else => try probes.raceRead(io, pair.server, &buffer, .fromSeconds(30)),
            };
            try testing.expectEqual(1, n);
        }
        cost.* = probes.ms(probes.since(io, start)) * 1000 / rounds;
    }
    probes.report("cost of a byte sent and read, per round of {d}: plain read {d:.1} us, operateTimeout {d:.1} us, select race {d:.1} us", .{ rounds, per_read[0], per_read[1], per_read[2] });
}

/// The name of what a read or a write ended with, for `report`.
fn outcome(result: anytype) []const u8 {
    return if (result) |_| "data" else |err| @errorName(err);
}
