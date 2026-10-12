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

/// Yields to a producer that copies its record in before the writer sleeps
/// until it publishes: a producer preempted there takes a while.
const filling_yields = 64;

pub fn run(engine: *Engine) void {
    thread_of = engine;
    const q = &engine.queue.?;
    var yields: u32 = 0;
    while (!engine.abandon.load(.acquire)) {
        const n = q.pop(engine.batch[1..], engine.batch_ends);
        if (n > 0) {
            yields = 0;
            engine.writeBatch(n);
            // Before the batch counts as done, so a flush waiting for it
            // finds the summary of the error records dropped so far
            // written; one dropped after this check is reported after the
            // next batch, before the writer sleeps, or by shutdown.
            engine.reportDroppedErrors();
            engine.markProcessed(n);
            continue;
        }
        engine.reportDroppedErrors();
        switch (q.idle()) {
            .closed => return,
            .empty => q.waitForWork(idle_recheck),
            .filling => if (yields < filling_yields) {
                yields += 1;
                std.Thread.yield() catch {};
            } else {
                q.waitForPublish(idle_recheck, &engine.abandon);
            },
        }
    }
}
