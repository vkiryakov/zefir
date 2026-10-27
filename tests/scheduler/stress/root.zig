//! Stress tests of zefir-scheduler against mongo-plain of the repository's
//! docker-compose.yml (13.5 of the design): 20,000 one-shot jobs due at
//! one moment, and 200 jobs that repeat every second for 60 s, each run
//! by four instances of 16 slots through a proxy that cuts every
//! connection every 2 s. `zig build stress` runs them in Debug and in
//! ReleaseSafe, each on zio with one executor and again with four, under
//! the time limit of the end-to-end tests; the test runner checks that all
//! the memory comes back.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const zio = @import("zio");
const e2e = @import("e2e");
const fixture = e2e.fixture;
const Proxy = e2e.Proxy;

/// Runs `scenario` on zio with one executor, then with four. The four
/// instances and the proxy take a few hundred sockets, which it raises the
/// limit of open files for.
pub fn onZio(comptime scenario: fn (Io) anyerror!void) !void {
    std.process.raiseFileDescriptorLimit();
    for ([_]u8{ 1, 4 }) |executors| {
        const runtime = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(executors) });
        defer runtime.deinit();
        std.debug.print("  {t}, {d} executor(s)\n", .{ builtin.mode, executors });
        e2e.withinTimeLimit(runtime.io(), scenario) catch |err| {
            std.debug.print("with {d} executor(s): {t}\n", .{ executors, err });
            return err;
        };
    }
}

/// The instances of a service under stress, and the slots of each.
pub const instances = 4;
pub const slots = 16;

/// The settings of the workers: those of the end-to-end tests, a lease of
/// 3 s renewed every second and a poll every 100 ms, with 16 slots.
pub fn options() fixture.Options {
    return fixture.options("stress", slots);
}

/// A scene of the stress: its database on mongo-plain, the proxy, a node
/// that reaches mongod straight, to put the jobs on their time and to look
/// at the records, and the four instances, which reach it through the
/// proxy. Open it in place: the nodes point to the proxy's port.
pub const Stage = struct {
    scene: fixture.Scene,
    proxy: Proxy,
    direct: fixture.Node,
    nodes: [instances]fixture.Node,
    opened: usize,

    pub fn open(s: *Stage, io: Io, prefix: []const u8) !void {
        try s.scene.open(io, e2e.servers.plain, prefix);
        errdefer s.scene.close(io);
        try s.proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
        errdefer s.proxy.stop();
        try s.direct.open(io, e2e.servers.plain, s.scene.database);
        errdefer s.direct.close();
        var uri: [96]u8 = undefined;
        const through = try s.proxy.uri(&uri, "appName=scheduler-stress");
        s.opened = 0;
        errdefer for (s.nodes[0..s.opened]) |*n| n.close();
        for (&s.nodes) |*n| {
            try n.open(io, through, s.scene.database);
            s.opened += 1;
        }
    }

    pub fn close(s: *Stage, io: Io) void {
        for (s.nodes[0..s.opened]) |*n| n.close();
        s.direct.close();
        s.proxy.stop();
        s.scene.close(io);
    }
};

/// Cuts every connection through the proxy every 2 s until `stop`.
pub const Cutter = struct {
    proxy: *Proxy,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The rounds of cuts so far, and the connections they cut.
    rounds: std.atomic.Value(u32) = .init(0),
    cut: std.atomic.Value(u32) = .init(0),
    task: Io.Future(void) = undefined,

    const every_ms = 2000;
    /// How often it looks whether to stop.
    const step_ms = 50;

    pub fn start(c: *Cutter, io: Io) !void {
        c.task = try io.concurrent(loop, .{ c, io });
    }

    /// Stops cutting and waits for the task.
    pub fn stop(c: *Cutter, io: Io) void {
        c.stopping.store(true, .release);
        c.task.await(io);
    }

    fn loop(c: *Cutter, io: Io) void {
        while (true) {
            var waited: u32 = 0;
            while (waited < every_ms) : (waited += step_ms) {
                if (c.stopping.load(.acquire)) return;
                io.sleep(.fromMilliseconds(step_ms), .awake) catch return;
            }
            if (c.stopping.load(.acquire)) return;
            _ = c.cut.fetchAdd(@intCast(c.proxy.cutAll()), .acq_rel);
            _ = c.rounds.fetchAdd(1, .acq_rel);
        }
    }
};

/// The counters of the workers, added up.
pub fn statsOf(workers: anytype) scheduler.Stats {
    var sum: scheduler.Stats = std.mem.zeroes(scheduler.Stats);
    for (workers) |*w| {
        const s = w.stats();
        inline for (.{ "claimed", "succeeded", "failed", "timed_out", "gave_up", "lost", "removed", "taken_over", "coalesced", "skipped", "unreadable", "store_errors" }) |name|
            @field(sum, name) += @field(s, name);
    }
    return sum;
}

test {
    _ = @import("storm.zig");
    _ = @import("recurring.zig");
}
