//! A worker in a process of its own, which the test of a killed instance
//! (e2e/kill.zig) starts and kills: on zio, it runs the job `e2e-kill` of
//! a database, notes the start of each run in the collection `effects`,
//! and holds the run until the process ends. It ends by itself once the
//! test that started it is gone, and after two minutes, so that a test
//! that died between the start and the kill leaves no worker behind to
//! renew its lease for ever.
//!
//! Settings, from the environment:
//!
//!   SCHEDULER_E2E_URI        the connection string of mongod
//!   SCHEDULER_E2E_DATABASE   the database of the store and of `effects`

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const core = @import("core");
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const bson = @import("mongo-bson");

/// A panic prints its message and exits with code 3 instead of aborting.
pub const panic = std.debug.FullPanic(exitOnPanic);

/// On stderr, as the tests' own log.
pub const std_options: std.Options = .{ .log_level = .warn };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// How long the process may live: the test kills it within seconds.
const time_limit: std.Io.Duration = .fromSeconds(120);

/// Windows has no `getppid`, and the test that starts this process runs
/// only on Linux and macOS: there the process is built, never run, and
/// only `time_limit` would end it.
const watches_parent = builtin.os.tag != .windows;

/// Exits with code 5 once the process that started this one is gone, as
/// the parent of an orphan changes, and with code 4 after `time_limit`;
/// a cancel ends it first.
fn watch(io: std.Io, parent: std.posix.pid_t) void {
    const end = std.Io.Clock.awake.now(io).addDuration(time_limit);
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch return;
        if (watches_parent and std.posix.getppid() != parent) {
            std.debug.print("worker_child: the test that started it is gone: exit with code 5\n", .{});
            std.process.exit(5);
        }
        if (std.Io.Clock.awake.now(io).nanoseconds >= end.nanoseconds) {
            std.debug.print("worker_child: not killed within {d} s: exit with code 4\n", .{time_limit.toSeconds()});
            std.process.exit(4);
        }
    }
}

/// The job of the test, as e2e/kill.zig knows it too: a run notes its
/// start, then holds.
const Kill = struct {
    effects: mongo.Collection,

    pub const scheduler_job: scheduler.Job = .{ .name = "e2e-kill", .history = .forever };

    pub fn run(self: *Kill, ctx: *scheduler.Context) !void {
        const io = ctx.io();
        const info = ctx.info();
        const start = std.Io.Clock.real.now(io).toMilliseconds();
        _ = try self.effects.insertOne(io, .of(ctx.operation()), .{
            .job = info.job,
            .key = info.key,
            .instance = info.instance,
            .attempt = @as(i64, info.attempt),
            .fence = @as(i64, @intCast(info.fence)),
            .start = start,
            .end = start,
        }, .{ .allocator = ctx.allocator() });
        while (true) try io.sleep(.fromSeconds(1), .awake);
    }
};

pub fn main(init: std.process.Init) !void {
    const parent: std.posix.pid_t = if (watches_parent) std.posix.getppid() else undefined;
    var watchdog = try init.io.concurrent(watch, .{ init.io, parent });
    defer watchdog.cancel(init.io);
    const uri = init.environ_map.get("SCHEDULER_E2E_URI") orelse return error.NoUri;
    const database = init.environ_map.get("SCHEDULER_E2E_DATABASE") orelse return error.NoDatabase;
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();

    var client: mongo.Client = try .init(init.gpa, io, .{ .uri = uri });
    defer client.deinit();
    try client.connect(io, core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(30))), null);
    var store: mongo.SchedulerStore = try .init(init.gpa, io, &client, .{ .database = database });
    defer store.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    var kill: Kill = .{ .effects = mongo.Database.init(&client, database, &ids).collection("effects") };
    // The times of the tests: a lease of 3 s, renewed every second.
    var worker: scheduler.Worker(struct { kill: *Kill }) = try .init(init.gpa, io, store.store(), .{ .kill = &kill }, .{
        .workers = 1,
        .lease = .fromSeconds(3),
        .renew_every = .fromSeconds(1),
        .poll_every = .fromMilliseconds(100),
        .store_timeout = .fromSeconds(1),
        .instance = "child",
    });
    defer worker.deinit(io);
    try worker.run(io);
}
