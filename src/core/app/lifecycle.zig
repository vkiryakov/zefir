//! The lifecycle of zefir.App (design §9–§12): one stop task, one watcher
//! per started bean with `wait`, the start in creation order with its
//! rollback, and the stop in two phases within one deadline. It is not
//! generic over the root: it runs on the entries and the status in App's
//! block, so every application shares this code, and its tasks get the
//! block, never the App value, which may move.
const std = @import("std");
const Deadline = @import("../Deadline.zig");
const Failure = @import("../app.zig").Failure;
const contract = @import("contract.zig");
const untilSet = @import("wait.zig").untilSet;

const Io = std.Io;
const State = contract.State;
const Entry = contract.Entry;

/// One per entry: set once nothing waits in the entry's `wait` any more.
pub const Watch = struct {
    returned: Io.Event = .unset,
};

/// The lifecycle of one App, in its block.
pub const Runtime = struct {
    /// Set once the stop task has returned; a test that opened a gate waits on it.
    ended: Io.Event = .unset,

    // The rest is internal.
    io: Io,
    shutdown_timeout: Io.Duration,
    status: *contract.Status,
    watches: []Watch,
    /// The task that leads the stop; `start` starts it, `deinit` joins it.
    stop_task: ?Io.Future(void) = null,
    /// The watchers: only `start` adds to it, only the stop task cancels it.
    watchers: Io.Group = .init,
    /// How many entries the start loop passed. The stop task reads it after `start_done`.
    started: usize = 0,
    /// Set by `requestStop`, by a breakdown and by a failed start.
    stop_event: Io.Event = .unset,
    /// Set once `start` has passed its loop.
    start_done: Io.Event = .unset,
    /// Set once the stop began; `deadline` is written before it.
    began: Io.Event = .unset,
    deadline: Deadline = .{ .expires = .zero },
    /// The entry the stop task calls or waits for, `none` or `gathering`.
    at: std.atomic.Value(usize) = .init(none),

    /// Guards what follows. Every section under it is short, and no bean is
    /// called under it.
    mutex: Io.Mutex = .init,
    /// The first cause of the stop or of the failure.
    cause: ?Cause = null,
    /// The start failed: the stop rolls back what started.
    rollback: bool = false,
    /// The stop ran out of time, or a bean returned `error.ShutdownTimeout`.
    fatal: bool = false,
    /// A bean returned `error.ShutdownTimeout` itself: its tasks may still
    /// use it, so App never frees the beans.
    timed_out: bool = false,
    /// The entry that did not stop.
    stuck: ?usize = null,
    /// What `wait` returns, once it is known.
    result: ?anyerror!void = null,

    const Cause = struct { entry: usize, step: Failure.Step, err: anyerror };

    const none = std.math.maxInt(usize);
    const gathering = none - 1;

    fn entries(rt: *const Runtime) []const Entry {
        return rt.status.internal.entries;
    }

    fn state(rt: *const Runtime) State {
        return rt.status.internal.state.load(.acquire);
    }

    fn lock(rt: *Runtime) void {
        rt.mutex.lockUncancelable(rt.io);
    }

    fn unlock(rt: *Runtime) void {
        rt.mutex.unlock(rt.io);
    }

    /// `starting` or `running → stopping`, for a cause; false when the stop
    /// began already. Under `mutex`.
    fn stopByCause(rt: *Runtime) bool {
        const s = &rt.status.internal.state;
        var seen = s.load(.acquire);
        while (true) switch (seen) {
            .starting, .running => seen = s.cmpxchgWeak(seen, .stopping, .acq_rel, .acquire) orelse return true,
            .created, .stopping, .stopped, .failed => return false,
        };
    }

    /// Starts the watcher of entry i. Starting a task allocates, which must
    /// not swallow a cancelation of the caller.
    fn watch(rt: *Runtime, i: usize) Io.ConcurrentError!void {
        const protection = rt.io.swapCancelProtection(.blocked);
        defer _ = rt.io.swapCancelProtection(protection);
        rt.watchers.concurrent(rt.io, watcher, .{ rt, i }) catch |err| {
            // No watcher waits on it.
            rt.watches[i].returned.set(rt.io);
            return err;
        };
    }

    /// Entry i did not start, or App could not watch it: the first cause,
    /// and the stop, which rolls back what started.
    fn startFailed(rt: *Runtime, i: usize, err: anyerror) void {
        {
            rt.lock();
            defer rt.unlock();
            if (rt.cause == null) rt.cause = .{ .entry = i, .step = .start, .err = err };
            _ = rt.stopByCause();
        }
        rt.stop_event.set(rt.io);
    }

    /// The shutdown of entry k failed: the first cause; `ShutdownTimeout`
    /// makes the stop fatal.
    fn shutdownFailed(rt: *Runtime, k: usize, err: anyerror) void {
        rt.lock();
        defer rt.unlock();
        if (rt.cause == null) rt.cause = .{ .entry = k, .step = .shutdown, .err = err };
        if (err == error.ShutdownTimeout) {
            rt.fatal = true;
            rt.timed_out = true;
            if (rt.stuck == null) rt.stuck = k;
        }
    }

    /// The deadline came before the `wait` of entry k returned.
    fn didNotStop(rt: *Runtime, k: usize) void {
        rt.lock();
        defer rt.unlock();
        rt.fatal = true;
        if (rt.stuck == null) rt.stuck = k;
        if (rt.cause == null) rt.cause = .{ .entry = k, .step = .shutdown, .err = error.ShutdownTimeout };
    }

    /// The entry the stop task is in: the one it calls, the one whose
    /// watcher it waits for, or, while it gathers the watchers, the first
    /// entry whose watcher has not returned.
    fn current(rt: *Runtime) ?usize {
        const at = rt.at.load(.acquire);
        if (at == none) return null;
        if (at != gathering) return at;
        for (rt.entries()[0..rt.started], 0..) |entry, i| {
            if (entry.vtable.wait != null and !rt.watches[i].returned.isSet()) return i;
        }
        return null;
    }

    /// What `wait` returns once the stop has ended, fixed on the first
    /// call. Under `mutex`.
    fn fix(rt: *Runtime) anyerror!void {
        if (rt.result == null) rt.result = if (rt.fatal) error.ShutdownTimeout else if (rt.cause) |c| c.err else {};
        return rt.result.?;
    }

    /// Waits for the stop to begin, then for its end until the deadline.
    fn awaitStop(rt: *Runtime) anyerror!void {
        try rt.began.wait(rt.io);
        untilSet(&rt.ended, rt.io, rt.deadline) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return rt.late(),
        };
        rt.lock();
        defer rt.unlock();
        return rt.fix();
    }

    /// The deadline passed before the stop ended: one CAS `stopping →
    /// failed`, unless the stop task, ending just now, set the final state
    /// first.
    fn late(rt: *Runtime) anyerror!void {
        rt.lock();
        defer rt.unlock();
        if (rt.result) |result| return result;
        if (rt.status.internal.state.cmpxchgStrong(.stopping, .failed, .acq_rel, .acquire) != null) return rt.fix();
        rt.fatal = true;
        rt.stuck = rt.stuck orelse rt.current();
        if (rt.stuck) |k| if (rt.cause == null) {
            rt.cause = .{ .entry = k, .step = .shutdown, .err = error.ShutdownTimeout };
        };
        rt.result = error.ShutdownTimeout;
        return error.ShutdownTimeout;
    }
};

/// Starts the stop task, then each entry in creation order; returns when
/// all have started. A failed start rolls back what started.
pub fn start(rt: *Runtime) anyerror!void {
    const io = rt.io;
    if (rt.status.internal.state.cmpxchgStrong(.created, .starting, .acq_rel, .acquire) != null) return error.InvalidState;
    // The stop task starts first, so that a stop requested while the beans
    // start is not lost. Starting a task allocates, which must not swallow
    // a cancelation of the caller.
    rt.stop_task = task: {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        break :task io.concurrent(stopTask, .{rt}) catch |err| {
            rt.lock();
            defer rt.unlock();
            rt.result = err;
            rt.status.internal.state.store(.failed, .release);
            return err;
        };
    };
    const list = rt.entries();
    var count: usize = 0;
    const failed = for (list, 0..) |entry, i| {
        // A stop request or a breakdown stops the starting.
        if (rt.state() != .starting) break false;
        if (entry.vtable.start) |startFn| startFn(entry.ptr, io) catch |err| {
            rt.startFailed(i, err);
            break true;
        };
        count = i + 1;
        if (entry.vtable.wait != null) rt.watch(i) catch |err| {
            rt.startFailed(i, err);
            break true;
        };
    } else false;
    const running = !failed and count == list.len and
        rt.status.internal.state.cmpxchgStrong(.starting, .running, .acq_rel, .acquire) == null;
    const rollback = rollback: {
        rt.lock();
        defer rt.unlock();
        rt.rollback = !running and rt.cause != null;
        break :rollback rt.rollback;
    };
    rt.started = count;
    rt.start_done.set(io);
    // A stop request alone: the stop goes on, and `wait` sees its end.
    if (!rollback) return;
    return rt.awaitStop();
}

/// Waits for the end of the stop.
pub fn wait(rt: *Runtime) anyerror!void {
    if (rt.state() == .created) return error.InvalidState;
    {
        rt.lock();
        defer rt.unlock();
        if (rt.result) |result| return result;
    }
    return rt.awaitStop();
}

/// Begins the stop: `starting` or `running → stopping` by one CAS, then the
/// stop task wakes. Never waits; a second call does nothing.
pub fn requestStop(rt: *Runtime) void {
    const s = &rt.status.internal.state;
    var seen = s.load(.acquire);
    while (true) switch (seen) {
        .starting, .running => seen = s.cmpxchgWeak(seen, .stopping, .acq_rel, .acquire) orelse break,
        .created, .stopping, .stopped, .failed => return,
    };
    rt.stop_event.set(rt.io);
}

/// The first cause of the stop or of the failure; null when all went well.
pub fn failure(rt: *Runtime) ?Failure {
    rt.lock();
    defer rt.unlock();
    const cause = rt.cause orelse return null;
    return .{ .bean = rt.entries()[cause.entry].name, .step = cause.step, .err = cause.err };
}

/// Before `deinit` frees the beans: stops an App that runs, and takes back
/// the stop task once it has returned (the Io allocated it). False when the
/// beans must stay: a task of App, or of a bean that returned
/// `error.ShutdownTimeout`, may still use them.
pub fn finish(rt: *Runtime) bool {
    const io = rt.io;
    // No cancelation point: a cancelation request of the caller stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (rt.stop_task) |*task| {
        requestStop(rt);
        wait(rt) catch {};
        if (rt.ended.isSet()) {
            task.await(io);
            rt.stop_task = null;
        }
    }
    rt.lock();
    defer rt.unlock();
    return rt.stop_task == null and !rt.timed_out;
}

/// Waits for a stop and for the end of `start`, then stops what started:
/// `requestStop` to all at once, then `shutdown` one at a time, last
/// created first, within one deadline; gathers the watchers last.
fn stopTask(rt: *Runtime) void {
    const io = rt.io;
    // Nothing cancels this task, and its waits are no cancelation points.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    rt.stop_event.waitUncancelable(io);
    rt.start_done.waitUncancelable(io);
    rt.deadline = .after(Io.Clock.awake.now(io), rt.shutdown_timeout);
    rt.began.set(io);
    const list = rt.entries()[0..rt.started];
    const deadline = rt.deadline.expires.withClock(.awake);
    // Phase 1: no started bean takes new work.
    for (list, 0..) |entry, k| if (entry.vtable.requestStop) |requestStopFn| {
        rt.at.store(k, .release);
        requestStopFn(entry.ptr, io);
    };
    // Phase 2: each finishes its work and closes, last created first.
    var k = list.len;
    while (k > 0) {
        k -= 1;
        const entry = list[k];
        rt.at.store(k, .release);
        if (entry.vtable.shutdown) |shutdownFn| {
            shutdownFn(entry.ptr, io, deadline) catch |err| rt.shutdownFailed(k, err);
        } else if (entry.vtable.wait != null) {
            untilSet(&rt.watches[k].returned, io, rt.deadline) catch rt.didNotStop(k);
        }
    }
    // Nothing may wait in a bean's `wait` once App frees the bean.
    rt.at.store(Runtime.gathering, .release);
    rt.watchers.cancel(io);
    {
        rt.lock();
        defer rt.unlock();
        const final: State = if (rt.fatal or rt.rollback) .failed else .stopped;
        // A `wait` that declared the timeout first keeps its `failed`.
        _ = rt.status.internal.state.cmpxchgStrong(.stopping, final, .acq_rel, .acquire);
    }
    rt.ended.set(io);
}

/// Waits in the `wait` of entry i. A return while App starts or runs is a
/// breakdown: its error, or `error.UnexpectedStop` for `{}`, becomes the
/// cause, and App stops. While App stops, a return is expected, and so is
/// the gathering's `error.Canceled`.
fn watcher(rt: *Runtime, i: usize) void {
    const io = rt.io;
    const entry = rt.entries()[i];
    const result = entry.vtable.wait.?(entry.ptr, io);
    const by_itself = by_itself: {
        rt.lock();
        defer rt.unlock();
        if (!rt.stopByCause()) break :by_itself false;
        if (rt.cause == null) rt.cause = .{ .entry = i, .step = .wait, .err = if (result) |_| error.UnexpectedStop else |err| err };
        break :by_itself true;
    };
    if (by_itself) rt.stop_event.set(io);
    rt.watches[i].returned.set(io);
}
