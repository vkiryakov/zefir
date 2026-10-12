//! The writer thread of the queued mode. It takes the published records
//! off the queue in batches and writes each batch with one write loop,
//! through the logger's own Io. With nothing to do it sleeps until a
//! producer wakes it.

const std = @import("std");
const Engine = @import("Engine.zig");

/// How long the writer sleeps without a wake-up before it looks again: a
/// safety net, producers wake it.
const idle_recheck: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };

/// The engine whose writer thread this is: `flush` and `shutdown` called
/// on it would wait for the thread itself.
pub threadlocal var thread_of: ?*const Engine = null;

pub fn run(engine: *Engine) void {
    thread_of = engine;
    const q = &engine.queue.?;
    while (!engine.abandon.load(.acquire)) {
        const n = q.pop(engine.batch[1..], engine.batch_ends);
        if (n > 0) {
            engine.writeBatch(n);
            engine.markProcessed(n);
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
