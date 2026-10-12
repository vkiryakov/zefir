//! The writer thread of the queued mode. It takes the published records
//! off the queue in batches and writes each batch with one write loop,
//! through the logger's own Io. With nothing to do it sleeps until a
//! producer wakes it.

const std = @import("std");
const Engine = @import("Engine.zig");

/// How long the writer sleeps without a wake-up before it looks again: a
/// safety net, producers wake it.
const idle_recheck: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };

pub fn run(engine: *Engine) void {
    const q = &engine.queue.?;
    while (true) {
        const n = q.pop(engine.batch[1..], engine.batch_ends);
        if (n > 0) {
            engine.writeBatch(n);
            continue;
        }
        const reserved = q.reserved();
        if (q.head == reserved and q.isClosed()) return; // closed and drained
        if (q.head != reserved) {
            // A producer is still copying its record in: it publishes soon.
            std.Thread.yield() catch {};
            continue;
        }
        q.waitForWork(idle_recheck);
    }
}
