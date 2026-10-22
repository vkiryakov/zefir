//! Beans with gates for the lifecycle tests of zefir.App. Each records into
//! a rig what App calls, and the deadline its shutdown got. The test holds a
//! bean at its gate (in its start, its shutdown or its wait) and opens it,
//! always also in `defer`, so that no task stays blocked when a test fails.
//! The rig is a value of the root and outlives the App: opening a gate never
//! touches App's memory.
const std = @import("std");
const names = @import("../names.zig");
const mocks = @import("mocks.zig");
const untilSet = @import("../wait.zig").untilSet;

const Io = std.Io;
const Timestamp = Io.Clock.Timestamp;

/// What a bean's `start` does once it has recorded.
pub const Start = enum {
    ok,
    /// Waits on the gate: a Starter.
    held,
    /// Sleeps `sleep`, then returns `error.StartFailed`: a Failing.
    fails,
};

/// What a bean's `shutdown` does once it has recorded and kept the deadline.
pub const Shutdown = enum {
    ok,
    /// Waits on the gate, deaf to cancelation: a Deaf.
    deaf,
    /// Returns `error.ShutdownFailed`: a Fragile.
    fails,
    /// Waits on the gate, deaf to cancelation, then returns `error.ShutdownFailed`.
    fails_late,
    /// Returns `error.ShutdownTimeout`, as a server whose handlers outlive its stop.
    times_out,
};

/// One bean's script and what the bean saw. The test writes the script
/// before the App starts.
pub const Slot = struct {
    who: []const u8 = "",
    start: Start = .ok,
    shutdown: Shutdown = .ok,
    /// A failing start sleeps this long first; a Lingering's wait returns
    /// this long after its requestStop.
    sleep: Io.Duration = .zero,
    /// What a Waiter's wait returns when the test ends it (`Rig.end`).
    result: anyerror!void = {},
    /// The test opens it: a held start, a deaf shutdown, a deaf wait.
    gate: Io.Event = .unset,
    /// Set when the bean enters the call its gate holds.
    entered: Io.Event = .unset,
    /// Ends a Waiter's or a Lingering's wait: the test sets it, and so do
    /// the bean's own requestStop and shutdown. A Worker's task sets it
    /// when it ends.
    wake: Io.Event = .unset,
    /// A Worker's task; `Rig.release` awaits it.
    task: ?Io.Future(void) = null,
    /// Set by the bean's own requestStop and shutdown: its wait returns {}.
    stopped: std.atomic.Value(bool) = .init(false),
    /// The deadline the bean's shutdown got.
    deadline: ?Timestamp = null,
    /// When a failing start returned.
    failed_at: ?Io.Timestamp = null,
};

/// What the gated beans of one App share: the recorder of their events and
/// a slot per bean, found by the bean's name.
pub const Rig = struct {
    io: Io,
    rec: mocks.Recorder,
    mutex: Io.Mutex = .init,
    slots: [capacity]Slot = @splat(.{}),
    len: usize = 0,
    /// Where beans go past `capacity`; `expect` then fails.
    spare: Slot = .{},

    pub const capacity = 16;

    pub fn init(io: Io) Rig {
        return .{ .io = io, .rec = .init(io) };
    }

    /// The slot of the bean `who`, claimed on first use.
    pub fn of(rig: *Rig, who: []const u8) *Slot {
        rig.mutex.lockUncancelable(rig.io);
        defer rig.mutex.unlock(rig.io);
        for (rig.slots[0..rig.len]) |*slot| if (std.mem.eql(u8, slot.who, who)) return slot;
        if (rig.len == capacity) return &rig.spare;
        rig.slots[rig.len] = .{ .who = who };
        rig.len += 1;
        return &rig.slots[rig.len - 1];
    }

    /// Opens every gate and ends every wait: in `defer`, so that no task
    /// stays blocked on a bean when a test fails. Then awaits the Workers'
    /// tasks, which end once their gates are open.
    pub fn release(rig: *Rig) void {
        const len = len: {
            rig.mutex.lockUncancelable(rig.io);
            defer rig.mutex.unlock(rig.io);
            for (rig.slots[0..rig.len]) |*slot| {
                slot.gate.set(rig.io);
                slot.wake.set(rig.io);
            }
            break :len rig.len;
        };
        for (rig.slots[0..len]) |*slot| if (slot.task) |*task| {
            task.await(rig.io);
            slot.task = null;
        };
    }

    /// Opens the gate of `who`.
    pub fn open(rig: *Rig, who: []const u8) void {
        rig.of(who).gate.set(rig.io);
    }

    /// Ends the wait of the Waiter `who` with `result`, as a server that
    /// breaks (an error) or stops by itself (`{}`).
    pub fn end(rig: *Rig, who: []const u8, result: anyerror!void) void {
        const slot = rig.of(who);
        slot.result = result;
        slot.wake.set(rig.io);
    }

    /// Waits, ten seconds at most, until `who` enters the call its gate holds.
    pub fn entered(rig: *Rig, who: []const u8) !void {
        return within(&rig.of(who).entered, rig.io, .fromSeconds(10));
    }

    /// Checks the `who` of every event `what`, in order.
    pub fn expect(rig: *Rig, what: []const u8, expected: []const []const u8) !void {
        const full = full: {
            rig.mutex.lockUncancelable(rig.io);
            defer rig.mutex.unlock(rig.io);
            break :full rig.len == capacity;
        };
        if (full) return error.TestUnexpectedResult;
        return rig.rec.expect(what, expected);
    }

    /// Checks the `who` of every event `what`, in any order: the shutdowns
    /// of the servers, which App runs together.
    pub fn expectUnordered(rig: *Rig, what: []const u8, expected: []const []const u8) !void {
        const full = full: {
            rig.mutex.lockUncancelable(rig.io);
            defer rig.mutex.unlock(rig.io);
            break :full rig.len == capacity;
        };
        if (full) return error.TestUnexpectedResult;
        rig.rec.mutex.lockUncancelable(rig.io);
        defer rig.rec.mutex.unlock(rig.io);
        var n: usize = 0;
        for (rig.rec.events[0..rig.rec.len]) |e| if (std.mem.eql(u8, e.what, what)) {
            n += 1;
        };
        errdefer {
            std.debug.print("{s}: got", .{what});
            for (rig.rec.events[0..rig.rec.len]) |e| if (std.mem.eql(u8, e.what, what)) std.debug.print(" {s}", .{e.who});
            std.debug.print("\n", .{});
        }
        if (rig.rec.overflow) return error.TestUnexpectedResult;
        try std.testing.expectEqual(expected.len, n);
        for (expected) |who| {
            var times: usize = 0;
            for (rig.rec.events[0..rig.rec.len]) |e| if (std.mem.eql(u8, e.what, what) and std.mem.eql(u8, e.who, who)) {
                times += 1;
            };
            try std.testing.expectEqual(1, times);
        }
    }

    /// Where the event `what` of `who` stands among all events; null when
    /// it never came.
    pub fn position(rig: *Rig, what: []const u8, who: []const u8) ?usize {
        rig.rec.mutex.lockUncancelable(rig.io);
        defer rig.rec.mutex.unlock(rig.io);
        for (rig.rec.events[0..rig.rec.len], 0..) |e, k| {
            if (std.mem.eql(u8, e.what, what) and std.mem.eql(u8, e.who, who)) return k;
        }
        return null;
    }
};

/// Waits until `event` is set, `limit` at most: `error.TestTimeout` then.
pub fn within(event: *Io.Event, io: Io, limit: Io.Duration) !void {
    untilSet(event, io, .after(Io.Clock.awake.now(io), limit)) catch return error.TestTimeout;
}

/// A Worker's task: one long item of work, which ends when the test opens
/// the gate. It touches only the slot, never App's memory.
fn work(s: *Slot, io: Io) void {
    s.gate.waitUncancelable(io);
    s.wake.set(io);
}

/// The methods of the gated beans, for a type T with a field `rig: *Rig`.
/// A bean declares those it has: `pub const start = Methods(@This()).start;`.
fn Methods(comptime T: type) type {
    const who = comptime names.name(T);
    return struct {
        fn slot(t: *const T) *Slot {
            return t.rig.of(who);
        }

        pub fn start(t: *T, io: Io) anyerror!void {
            t.rig.rec.add("start", who);
            const s = slot(t);
            switch (s.start) {
                .ok => {},
                .held => {
                    s.entered.set(io);
                    try s.gate.wait(io);
                },
                .fails => {
                    try io.sleep(s.sleep, .awake);
                    s.failed_at = Io.Clock.awake.now(io);
                    return error.StartFailed;
                },
            }
        }

        /// A Waiter's: until the test ends it, or until the bean's own
        /// requestStop or shutdown, which return {}.
        pub fn wait(t: *T, io: Io) anyerror!void {
            const s = slot(t);
            defer t.rig.rec.add("waited", who);
            try s.wake.wait(io);
            if (s.stopped.load(.acquire)) return;
            return s.result;
        }

        /// A Stubborn's: until its task is canceled or the test opens its
        /// gate; the bean's own stop does not end it.
        pub fn waitHeld(t: *T, io: Io) anyerror!void {
            defer t.rig.rec.add("waited", who);
            try slot(t).gate.wait(io);
        }

        /// A DeafWait's: deaf to cancelation, until the test opens its gate.
        pub fn waitDeaf(t: *T, io: Io) anyerror!void {
            const s = slot(t);
            s.entered.set(io);
            s.gate.waitUncancelable(io);
            t.rig.rec.add("waited", who);
        }

        /// A Worker's: starts its task, which the slot keeps.
        pub fn startWorker(t: *T, io: Io) anyerror!void {
            t.rig.rec.add("start", who);
            const s = slot(t);
            s.task = try io.concurrent(work, .{ s, io });
        }

        /// A Worker's: until its task ends; a cancelation ends the wait
        /// sooner, not the task.
        pub fn waitWorker(t: *T, io: Io) anyerror!void {
            defer t.rig.rec.add("waited", who);
            try slot(t).wake.wait(io);
        }

        /// A Lingering's: returns `sleep` after the bean's own requestStop.
        pub fn waitLingering(t: *T, io: Io) anyerror!void {
            const s = slot(t);
            try s.wake.wait(io);
            try io.sleep(s.sleep, .awake);
            t.rig.rec.add("waited", who);
        }

        pub fn requestStop(t: *T, io: Io) void {
            t.rig.rec.add("requestStop", who);
            const s = slot(t);
            s.stopped.store(true, .release);
            s.wake.set(io);
        }

        /// Records "shutdown" when called and "shut" when it returns.
        pub fn shutdown(t: *T, io: Io, deadline: Timestamp) anyerror!void {
            t.rig.rec.add("shutdown", who);
            defer t.rig.rec.add("shut", who);
            const s = slot(t);
            s.deadline = deadline;
            s.stopped.store(true, .release);
            s.wake.set(io);
            switch (s.shutdown) {
                .ok => {},
                .deaf => {
                    s.entered.set(io);
                    s.gate.waitUncancelable(io);
                },
                .fails => return error.ShutdownFailed,
                .fails_late => {
                    s.entered.set(io);
                    s.gate.waitUncancelable(io);
                    return error.ShutdownFailed;
                },
                .times_out => return error.ShutdownTimeout,
            }
        }

        pub fn notReady(_: *const T) bool {
            return false;
        }

        pub fn deinit(t: *T) void {
            t.rig.rec.add("deinit", who);
        }
    };
}

/// Beans whose slots script their start and shutdown: six types, as one
/// type is one bean. A, B and C stop as servers do: start, requestStop,
/// shutdown and deinit. First, Second and Third stop as clients do: start,
/// shutdown and deinit, and no requestStop.
pub const A = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const requestStop = M.requestStop;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

pub const B = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const requestStop = M.requestStop;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

pub const C = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const requestStop = M.requestStop;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

pub const First = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

pub const Second = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

pub const Third = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

/// A bean like a server: its wait runs until the bean is stopped, or until
/// the test ends it (`Rig.end`) with an error or with {}.
pub const Waiter = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.start;
    pub const wait = M.wait;
    pub const requestStop = M.requestStop;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

/// A bean whose wait ends only when its task is canceled: App's gathering
/// of the watchers ends it.
pub const Stubborn = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const wait = M.waitHeld;
    pub const shutdown = M.shutdown;
    pub const deinit = M.deinit;
};

/// A background worker deaf to cancelation, with neither requestStop nor
/// shutdown: its wait returns only when the test opens its gate.
pub const DeafWait = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const wait = M.waitDeaf;
    pub const deinit = M.deinit;
};

/// A background worker with neither requestStop nor shutdown: its start
/// runs a task of its own, which ends only when the test opens its gate,
/// and its wait waits for that task.
pub const Worker = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const start = M.startWorker;
    pub const wait = M.waitWorker;
    pub const deinit = M.deinit;
};

/// A bean with wait and no shutdown: its wait returns `sleep` after its
/// requestStop.
pub const Lingering = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const wait = M.waitLingering;
    pub const requestStop = M.requestStop;
    pub const deinit = M.deinit;
};

/// A server with wait and no shutdown whose wait is deaf to its own
/// requestStop and to cancelation: it returns only when the test opens its
/// gate.
pub const DeafServer = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const wait = M.waitDeaf;
    pub const requestStop = M.requestStop;
    pub const deinit = M.deinit;
};

/// A bean that is never ready.
pub const Unready = struct {
    rig: *Rig,
    const M = Methods(@This());
    pub const isReady = M.notReady;
};
