//! The lifecycle of zefir.App (design §9–§12): one stop task, one watcher
//! per started bean with `wait`, the start in creation order with its
//! rollback, and the stop in two phases within one deadline, with a task
//! per server while the servers shut down together. It is not generic over
//! the root: it runs on the entries and the status in App's block, so every
//! application shares this code, and its tasks get the block, never the App
//! value, which may move.
const std = @import("std");
const Deadline = @import("../Deadline.zig");
const Failure = @import("../app.zig").Failure;
const contract = @import("contract.zig");
const untilSet = @import("wait.zig").untilSet;

const Io = std.Io;
const State = contract.State;
const Entry = contract.Entry;

const log = std.log.scoped(.zefir_app);

/// One per entry: what App's tasks know of it.
pub const Watch = struct {
    /// Set once nothing waits in the entry's `wait` any more.
    returned: Io.Event = .unset,
    /// App could not start the entry's watcher: while App stops, the stop
    /// task waits in the entry's `wait` itself.
    unwatched: bool = false,
    /// A server whose `shutdown` got no task of its own: the stop task
    /// calls it itself. Only the stop task touches it.
    no_task: bool = false,
    /// How the stop of a server ended: what its `shutdown` returned, or
    /// `{}` once its `wait` returned in time; null until then. Under `mutex`.
    outcome: ?anyerror!void = null,
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
    /// The entry the stop task calls or waits for, `none`, `together` or
    /// `gathering`.
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
    /// A bean may still run: it returned `error.ShutdownTimeout` itself, or
    /// App gave up on its `wait` at the deadline. Its tasks may still use
    /// it, so App never frees the beans.
    keep_beans: bool = false,
    /// The entry that did not stop.
    stuck: ?usize = null,
    /// "the stop ran out of time" is in the log: the stop task or `wait`,
    /// whichever saw the deadline first, wrote it.
    timeout_logged: bool = false,
    /// What `wait` returns, once it is known.
    result: ?anyerror!void = null,

    const Cause = struct { entry: usize, step: Failure.Step, err: anyerror };

    const none = std.math.maxInt(usize);
    const gathering = none - 1;
    /// The servers stop together.
    const together = none - 2;

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
            // No watcher waits on it; the stop task waits in the entry's
            // `wait` itself.
            rt.watches[i].unwatched = true;
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
    /// makes the stop fatal. Under `mutex`: the servers' shutdowns may fail
    /// at once.
    fn shutdownFailed(rt: *Runtime, k: usize, err: anyerror) void {
        if (rt.cause == null) rt.cause = .{ .entry = k, .step = .shutdown, .err = err };
        if (err == error.ShutdownTimeout) {
            rt.fatal = true;
            rt.keep_beans = true;
            if (rt.stuck == null) rt.stuck = k;
        }
    }

    /// The deadline came before the `wait` of entry k returned: App gives
    /// up on it. The gathering cancels that `wait`, which ends the wait, not
    /// the bean's work, so App never frees the beans.
    fn didNotStop(rt: *Runtime, k: usize) void {
        const label = label: {
            rt.lock();
            defer rt.unlock();
            rt.fatal = true;
            rt.keep_beans = true;
            if (rt.stuck == null) rt.stuck = k;
            if (rt.cause == null) rt.cause = .{ .entry = k, .step = .shutdown, .err = error.ShutdownTimeout };
            if (rt.timeout_logged) return;
            rt.timeout_logged = true;
            break :label rt.stuckLabel();
        };
        log.warn("the stop ran out of time: {s} did not stop", .{label});
    }

    /// The entry the stop task is in: the one it calls, the one whose
    /// watcher it waits for; while the servers stop together, the last
    /// created server that has not stopped; while it gathers the watchers,
    /// the first entry whose watcher has not returned. Under `mutex`.
    fn current(rt: *Runtime) ?usize {
        const at = rt.at.load(.acquire);
        if (at == none) return null;
        if (at == together) {
            var k = rt.started;
            while (k > 0) {
                k -= 1;
                const vtable = rt.entries()[k].vtable;
                if (vtable.requestStop == null) continue;
                if (vtable.shutdown != null) {
                    if (rt.watches[k].outcome == null) return k;
                } else if (vtable.wait != null) {
                    // No watcher waits in an unwatched server's `wait`: the
                    // stop task does, and sets its outcome once it returns.
                    const w = &rt.watches[k];
                    if (if (w.unwatched) w.outcome == null else !w.returned.isSet()) return k;
                }
            }
            return null;
        }
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
        const label = label: {
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
            if (rt.timeout_logged) return error.ShutdownTimeout;
            rt.timeout_logged = true;
            break :label rt.stuckLabel();
        };
        log.warn("the stop ran out of time: {s} did not stop", .{label});
        return error.ShutdownTimeout;
    }

    /// The bean that did not stop: the one App gave up on, or the one the
    /// stop task is in. Under `mutex`.
    fn stuckLabel(rt: *Runtime) []const u8 {
        const k = rt.stuck orelse rt.current() orelse return "App";
        return rt.entries()[k].name;
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
            {
                rt.lock();
                defer rt.unlock();
                rt.result = err;
                rt.status.internal.state.store(.failed, .release);
            }
            log.warn("the stop task did not start: error.{s}", .{@errorName(err)});
            return err;
        };
    };
    const list = rt.entries();
    var count: usize = 0;
    const failed = for (list, 0..) |entry, i| {
        // A stop request or a breakdown stops the starting.
        if (rt.state() != .starting) break false;
        if (entry.vtable.start) |startFn| startFn(entry.ptr, io) catch |err| {
            log.warn("{s} did not start: error.{s}", .{ entry.name, @errorName(err) });
            rt.startFailed(i, err);
            break true;
        };
        count = i + 1;
        if (entry.vtable.wait != null) rt.watch(i) catch |err| {
            log.warn("{s} started, but App could not watch it: error.{s}", .{ entry.name, @errorName(err) });
            rt.startFailed(i, err);
            break true;
        };
        if (entry.vtable.start != null) log.info("{s} started", .{entry.name});
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
    // `requestStop` before `start`: no stop began, and none will.
    if (rt.stop_task == null) return;
    return rt.awaitStop();
}

/// Begins the stop: `created → stopped`, `starting` or `running →
/// stopping` by one CAS, then the stop task wakes. Never waits; a second
/// call does nothing.
pub fn requestStop(rt: *Runtime) void {
    const s = &rt.status.internal.state;
    var seen = s.load(.acquire);
    while (true) switch (seen) {
        .created => seen = s.cmpxchgWeak(.created, .stopped, .acq_rel, .acquire) orelse return,
        .starting, .running => seen = s.cmpxchgWeak(seen, .stopping, .acq_rel, .acquire) orelse break,
        .stopping, .stopped, .failed => return,
    };
    rt.stop_event.set(rt.io);
}

/// `start`, then `wait`. `error.ShutdownTimeout` from either ends the
/// process with code 1.
pub fn run(rt: *Runtime) anyerror!void {
    start(rt) catch |err| return exitOnTimeout(rt, err);
    wait(rt) catch |err| return exitOnTimeout(rt, err);
}

/// `error.ShutdownTimeout`: tasks may still use the beans, so nothing may
/// be freed, and the process ends with code 1. Any other error is returned.
fn exitOnTimeout(rt: *Runtime, err: anyerror) anyerror {
    if (err != error.ShutdownTimeout) return err;
    const label = label: {
        rt.lock();
        defer rt.unlock();
        break :label rt.stuckLabel();
    };
    log.err("{s} did not stop in time; the process exits with code 1", .{label});
    // Straight to stderr too: a logger's queue may not be written out
    // before the exit.
    std.debug.print("{s} did not stop in time; the process exits with code 1\n", .{label});
    std.process.exit(1);
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
/// beans must stay: a task of App may still use them, or one of a bean that
/// returned `error.ShutdownTimeout` or whose `wait` App gave up on.
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
    const label = label: {
        rt.lock();
        defer rt.unlock();
        if (rt.stop_task == null and !rt.keep_beans) return true;
        break :label rt.stuckLabel();
    };
    log.warn("deinit frees nothing: {s} did not stop", .{label});
    return false;
}

/// Waits for a stop and for the end of `start`, then stops what started
/// within one deadline: `requestStop` to all at once; then `shutdown` to
/// the servers, the beans with `requestStop`, all together, and to the
/// rest one at a time, last created first; gathers the watchers last.
fn stopTask(rt: *Runtime) void {
    const io = rt.io;
    // Nothing cancels this task, and its waits are no cancelation points.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    rt.stop_event.waitUncancelable(io);
    rt.start_done.waitUncancelable(io);
    rt.deadline = .after(Io.Clock.awake.now(io), rt.shutdown_timeout);
    log.info("stopping", .{});
    rt.began.set(io);
    const list = rt.entries()[0..rt.started];
    const deadline = rt.deadline.expires.withClock(.awake);
    // Phase 1: no started bean takes new work.
    for (list, 0..) |entry, k| if (entry.vtable.requestStop) |requestStopFn| {
        rt.at.store(k, .release);
        requestStopFn(entry.ptr, io);
    };
    // Phase 2: each finishes its work and closes. First the servers, all
    // together, so that each cuts its grace by the deadline now.
    stopServers(rt, list, deadline);
    // Then the rest, one at a time, last created first: a bean is built
    // after what it takes, so what the servers use closes after them.
    var k = list.len;
    while (k > 0) {
        k -= 1;
        const entry = list[k];
        if (entry.vtable.requestStop != null) continue;
        rt.at.store(k, .release);
        if (entry.vtable.shutdown) |shutdownFn| {
            if (shutdownFn(entry.ptr, io, deadline)) |_| {
                log.info("{s} stopped", .{entry.name});
            } else |err| {
                log.warn("{s} did not stop cleanly: error.{s}", .{ entry.name, @errorName(err) });
                rt.lock();
                defer rt.unlock();
                rt.shutdownFailed(k, err);
            }
        } else if (entry.vtable.wait != null) {
            if (waitedFor(rt, k)) log.info("{s} stopped", .{entry.name});
        }
    }
    // Nothing may wait in a bean's `wait` once App frees the bean.
    rt.at.store(Runtime.gathering, .release);
    rt.watchers.cancel(io);
    const stopped = stopped: {
        rt.lock();
        defer rt.unlock();
        const final: State = if (rt.fatal or rt.rollback) .failed else .stopped;
        // A `wait` that declared the timeout first keeps its `failed`.
        const set = rt.status.internal.state.cmpxchgStrong(.stopping, final, .acq_rel, .acquire) == null;
        break :stopped set and !rt.fatal;
    };
    if (stopped) log.info("stopped", .{});
    rt.ended.set(io);
}

/// Phase 2 for the servers, the entries with `requestStop`: the `shutdown`
/// of each in a task of its own, all at once, by the one deadline. When the
/// Io has no task for one, the stop task calls that `shutdown` itself, once
/// the others run. A server with `wait` and no `shutdown` is waited for
/// meanwhile. Returns once each has stopped or App gave up on it, then logs
/// them, last created first, whatever order they stopped in.
fn stopServers(rt: *Runtime, list: []const Entry, deadline: Io.Clock.Timestamp) void {
    const io = rt.io;
    rt.at.store(Runtime.together, .release);
    var servers: Io.Group = .init;
    var k = list.len;
    while (k > 0) {
        k -= 1;
        const vtable = list[k].vtable;
        if (vtable.requestStop == null or vtable.shutdown == null) continue;
        servers.concurrent(io, closeServer, .{ rt, k, deadline }) catch {
            rt.watches[k].no_task = true;
        };
    }
    k = list.len;
    while (k > 0) {
        k -= 1;
        if (rt.watches[k].no_task) closeServer(rt, k, deadline);
    }
    k = list.len;
    while (k > 0) {
        k -= 1;
        const vtable = list[k].vtable;
        if (vtable.requestStop == null or vtable.shutdown != null or vtable.wait == null) continue;
        if (waitedFor(rt, k)) {
            rt.lock();
            defer rt.unlock();
            rt.watches[k].outcome = {};
        }
    }
    // Cancelation is blocked in the stop task: this returns once every task
    // of the group has.
    servers.await(io) catch {};
    k = list.len;
    while (k > 0) {
        k -= 1;
        const entry = list[k];
        if (entry.vtable.requestStop == null) continue;
        // Null: no `shutdown` and no `wait`, or App gave up on the `wait`.
        const outcome = outcome: {
            rt.lock();
            defer rt.unlock();
            break :outcome rt.watches[k].outcome;
        } orelse continue;
        if (outcome) |_| {
            log.info("{s} stopped", .{entry.name});
        } else |err| {
            log.warn("{s} did not stop cleanly: error.{s}", .{ entry.name, @errorName(err) });
        }
    }
}

/// The `shutdown` of server k, in a task of the servers' group or, when the
/// Io had none, in the stop task: keeps what it returned for the log, and
/// an error as the first cause.
fn closeServer(rt: *Runtime, k: usize, deadline: Io.Clock.Timestamp) void {
    const io = rt.io;
    // Nothing cancels it, as nothing cancels the stop task.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const entry = rt.entries()[k];
    const outcome = entry.vtable.shutdown.?(entry.ptr, io, deadline);
    rt.lock();
    defer rt.unlock();
    rt.watches[k].outcome = outcome;
    if (outcome) |_| {} else |err| rt.shutdownFailed(k, err);
}

/// Waits for the `wait` of entry k, which has no `shutdown`, by the
/// deadline; true when it returned in time. When the deadline comes first,
/// App gives up on it.
fn waitedFor(rt: *Runtime, k: usize) bool {
    if (rt.watches[k].unwatched) {
        // No watcher waits in its `wait`: the stop task does. A wait deaf to
        // the stop holds it past the deadline, as a deaf shutdown does, and
        // the owner's wait gives up then.
        const entry = rt.entries()[k];
        entry.vtable.wait.?(entry.ptr, rt.io) catch {};
        return true;
    }
    untilSet(&rt.watches[k].returned, rt.io, rt.deadline) catch {
        rt.didNotStop(k);
        return false;
    };
    return true;
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
    if (by_itself) {
        if (result) |_| {
            log.warn("{s} stopped by itself", .{entry.name});
        } else |err| {
            log.warn("{s} stopped by itself: error.{s}", .{ entry.name, @errorName(err) });
        }
        rt.stop_event.set(io);
    }
    rt.watches[i].returned.set(io);
}
