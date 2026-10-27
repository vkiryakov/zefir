//! What the scenarios of workers on mongod share: the database of a
//! scenario, an instance of a service (its own client of mongod and its
//! store), worker settings with short times, a probe that counts and holds
//! the runs of a job, the effects that runs leave as documents, and waits
//! that loop on the clock.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const e2e = @import("root.zig");

pub const Options = scheduler.Worker(struct {}).Options;

/// Times that hold on a slow machine ("Time on CI"): a lease of 3 s
/// renewed every second, a poll every 100 ms, calls of the store within
/// 1 s, and the pauses of a failing poll up to 2 s.
pub fn options(instance: []const u8, workers: u16) Options {
    return .{
        .workers = workers,
        .lease = .fromSeconds(3),
        .renew_every = .fromSeconds(1),
        .poll_every = .fromMilliseconds(100),
        .store_timeout = .fromSeconds(1),
        .max_backoff = .fromSeconds(2),
        .instance = instance,
    };
}

/// Stops `worker`, a `*scheduler.Worker(Jobs)`, within 10 s.
pub fn stop(io: Io, worker: anytype) !void {
    try worker.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }));
}

/// The database of a scenario, `scheduler_<prefix>_<n>`: fresh, and
/// dropped at the end through a client of its own. Open it in place.
pub const Scene = struct {
    admin: e2e.Admin,
    buffer: [64]u8,
    database: []const u8,

    pub fn open(s: *Scene, io: Io, uri: []const u8, prefix: []const u8) !void {
        try s.admin.open(io, uri);
        errdefer s.admin.close();
        s.database = try e2e.freshName(&s.buffer, prefix);
        try s.admin.dropDatabase(io, s.database);
    }

    pub fn close(s: *Scene, io: Io) void {
        s.admin.dropDatabase(io, s.database) catch |err| std.debug.print("drop of {s}: {t}\n", .{ s.database, err });
        s.admin.close();
    }

    /// The collection `effects` of the scenario, where its jobs note their
    /// runs.
    pub fn effects(s: *Scene) mongo.Collection {
        return s.admin.collection(s.database, "effects");
    }
};

/// One instance of a service: its own client of mongod and its store on
/// the database of the scenario, with the indexes made. Open it in place:
/// the store points to the client.
pub const Node = struct {
    client: mongo.Client,
    store: mongo.SchedulerStore,
    ids: bson.ObjectId.Generator,

    pub fn open(n: *Node, io: Io, uri: []const u8, database: []const u8) !void {
        n.client = try .init(testing.allocator, io, .{ .uri = uri });
        errdefer n.client.deinit();
        n.ids = .init(io);
        var d: mongo.Diagnostics = .{};
        n.client.connect(io, e2e.within(io, .fromSeconds(30)), &d) catch |err| {
            std.debug.print("connect to {s}: {t}: {s}\n", .{ uri, err, d.message() });
            return err;
        };
        n.store = try .init(testing.allocator, io, &n.client, .{ .database = database });
        errdefer n.store.deinit();
        n.store.diagnostics = &d;
        defer n.store.diagnostics = null;
        n.store.ensureIndexes(io, e2e.within(io, .fromSeconds(30))) catch |err| {
            std.debug.print("ensureIndexes of {s}: {t}: {s}\n", .{ database, err, d.message() });
            return err;
        };
    }

    pub fn close(n: *Node) void {
        n.store.deinit();
        n.client.deinit();
    }

    /// The collection `effects` through this instance's client: what its
    /// jobs write.
    pub fn effects(n: *Node) mongo.Collection {
        return mongo.Database.init(&n.client, n.store.database, &n.ids).collection("effects");
    }
};

/// The runs of a job in this process, as its handler notes them.
pub const Probe = struct {
    began: std.atomic.Value(u32) = .init(0),
    ended: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(u32) = .init(0),
    /// Of the latest run: its attempt, and when it began and ended, in ms
    /// of the real clock.
    attempt: std.atomic.Value(u32) = .init(0),
    began_ms: std.atomic.Value(i64) = .init(0),
    ended_ms: std.atomic.Value(i64) = .init(0),

    /// The body of a handler: notes the run, and with `hold` waits until
    /// the worker cancels it.
    pub fn run(p: *Probe, ctx: *scheduler.Context, hold: bool) !void {
        const io = ctx.io();
        p.attempt.store(ctx.info().attempt, .release);
        p.began_ms.store(nowMs(io), .release);
        _ = p.began.fetchAdd(1, .acq_rel);
        defer {
            p.ended_ms.store(nowMs(io), .release);
            _ = p.ended.fetchAdd(1, .acq_rel);
        }
        if (!hold) return;
        while (true) io.sleep(.fromSeconds(1), .awake) catch |err| {
            _ = p.cancelled.fetchAdd(1, .acq_rel);
            return err;
        };
    }
};

/// What one run left in the world, a document of `effects`: the run, who
/// ran it, and when it began and ended, in ms of the real clock.
pub const Effect = struct {
    job: []const u8,
    key: []const u8,
    instance: []const u8,
    attempt: i64,
    fence: i64,
    start: i64,
    end: i64,
};

/// Notes the run of `ctx`, which began at `start`, in `effects`: the last
/// thing its handler does.
pub fn note(effects: mongo.Collection, ctx: *scheduler.Context, start: i64) !void {
    const info = ctx.info();
    _ = try effects.insertOne(ctx.io(), .of(ctx.operation()), Effect{
        .job = info.job,
        .key = info.key,
        .instance = info.instance,
        .attempt = info.attempt,
        .fence = @intCast(info.fence),
        .start = start,
        .end = nowMs(ctx.io()),
    }, .{ .allocator = ctx.allocator() });
}

/// The effects of `job` in `arena`, the earliest first.
pub fn effectsOf(io: Io, effects: mongo.Collection, arena: std.mem.Allocator, job: []const u8) ![]const Effect {
    const op: mongo.OperationContext = .of(e2e.within(io, .fromSeconds(30)));
    var cursor = try effects.find(io, op, .{ .job = job }, .{ .allocator = arena, .sort = bson.literal(.{ .start = 1 }) });
    defer cursor.deinit(io);
    var list: std.ArrayList(Effect) = .empty;
    while (try cursor.next(io, op)) |doc| try list.append(arena, try bson.decode(Effect, arena, doc, .{}));
    return list.items;
}

pub fn nowMs(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

/// A wait that gives up: `tick` sleeps 20 ms, and fails the test once
/// `seconds` have passed, saying what it waited for.
pub const Limit = struct {
    end: i96,
    what: []const u8,

    pub fn of(io: Io, seconds: i64, what: []const u8) Limit {
        return .{ .end = Io.Clock.awake.now(io).nanoseconds +| @as(i96, seconds) * std.time.ns_per_s, .what = what };
    }

    pub fn tick(l: Limit, io: Io) !void {
        if (Io.Clock.awake.now(io).nanoseconds >= l.end) {
            std.debug.print("gave up waiting for {s}\n", .{l.what});
            return error.TestTimedOut;
        }
        try io.sleep(.fromMilliseconds(20), .awake);
    }
};
