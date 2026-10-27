//! `mongo.SchedulerStore`: the store of zefir-scheduler in MongoDB, for a
//! service that runs in several instances. It keeps each job as one
//! document of a collection of jobs and each claim of a job that the
//! history keeps as one row of a collection of runs, and implements the
//! store contract `scheduler.Store`:
//!
//! ```zig
//! var jobs: mongo.SchedulerStore = try .init(gpa, io, &client, .{ .database = "shop" });
//! defer jobs.deinit();
//! try jobs.ensureIndexes(io, ctx); // under zefir.App, its start does it
//! const client: scheduler.Client = .init(gpa, io, jobs.store(), .{});
//! ```
//!
//! The store stands on the client and the collection API and starts no
//! task of its own; the client must outlive it, and the store must stay
//! where it is once `store()` gave it out. One pair of collections serves
//! one service: the instances of the service share them.
//!
//! - Times are those of the server: every write that sets one takes
//!   `$$NOW` in a pipeline, so the instances agree whatever their clocks
//!   say. `now` estimates the server's clock without I/O: the process's
//!   real clock and an offset, measured by `ensureIndexes` and refined by
//!   every reply that carries the server's time (a claim, a renewal, the
//!   search for the next due job).
//! - A claim takes one job per `findAndModify`, the oldest due first, by
//!   the index `scan`; each job it takes carries a mark of its own, so that
//!   after a lost reply the store finds exactly what it claimed.
//! - Every write goes with `Options.write_concern`, `{w: 1, j: true}` by
//!   default: the server answers once the change is in its journal on
//!   disk. A `writeConcernError` of the server means the write ran without
//!   that promise: the store reads the job again, returns the normal
//!   result and logs a warning.
//! - An error after which the write may have run (a lost connection, a
//!   timeout, a refusal of the server) is resolved by reading the job
//!   again by the mark the write left; where that cannot tell, the call is
//!   `error.OutcomeUnknown`. Reads (`get`, `list`, `history`) change
//!   nothing, so their errors are those of a call that did nothing.
//! - `list` gives the jobs in the order of their `_id`, `"<job>/<key>"`:
//!   the jobs of one name together, their keys in order.
//! - The texts of `scheduler.Diagnostics` hold the server's message or the
//!   driver's text, never a payload or the connection string.

const std = @import("std");
const Io = std.Io;
const Duration = Io.Duration;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("root.zig");
const documents = @import("scheduler/documents.zig");
const Clock = @import("scheduler/Clock.zig");
const Instant = scheduler.Instant;
const SchedulerStore = @This();

const log = std.log.scoped(.mongo);

gpa: Allocator,
io: Io,
client: *mongo.Client,
/// The copies of the names of the database and the collections.
names: []u8,
database: []const u8,
jobs: []const u8,
runs: []const u8,
write_concern: mongo.WriteConcern,
start_timeout: Duration,
diagnostics: ?*mongo.Diagnostics,
/// For `mongo.Database`, which wants one: every document of the store
/// comes with its own `_id`.
ids: bson.ObjectId.Generator,
clock: Clock = .{},

pub const Options = struct {
    /// The database of the collections; one pair of collections serves one
    /// service.
    database: []const u8,
    /// The collection of the jobs.
    jobs: []const u8 = "scheduler_jobs",
    /// The collection of the history of their runs.
    runs: []const u8 = "scheduler_runs",
    /// The write concern of every write of the store.
    write_concern: mongo.WriteConcern = .{ .journal = true },
    /// How long `start` (zefir.App) waits for the indexes and the
    /// measurement of the server's clock.
    start_timeout: Duration = .fromSeconds(10),
    /// Why `init`, `ensureIndexes` or `start` failed.
    diagnostics: ?*mongo.Diagnostics = null,
};

pub const name = "mongodb";

/// Checks and copies the names; no I/O. The client is not the store's: it
/// must outlive it.
pub fn init(gpa: Allocator, io: Io, client: *mongo.Client, options: Options) error{ InvalidArgument, OutOfMemory }!SchedulerStore {
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try checkDatabase(options.database, d);
    try checkCollection("jobs", options.jobs, d);
    try checkCollection("runs", options.runs, d);
    if (std.mem.eql(u8, options.jobs, options.runs)) return invalid(d, "SchedulerStore: jobs and runs are two collections, and both are named '{s}'", .{options.jobs});
    const names = try std.mem.concat(gpa, u8, &.{ options.database, options.jobs, options.runs });
    const jobs_at = options.database.len;
    const runs_at = jobs_at + options.jobs.len;
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .names = names,
        .database = names[0..jobs_at],
        .jobs = names[jobs_at..runs_at],
        .runs = names[runs_at..],
        .write_concern = options.write_concern,
        .start_timeout = options.start_timeout,
        .diagnostics = d,
        .ids = .init(io),
    };
}

/// Frees the copies of the names; no call may be in flight.
pub fn deinit(s: *SchedulerStore) void {
    s.gpa.free(s.names);
    s.* = undefined;
}

/// Makes the indexes of both collections (one that is there already is no
/// error) and measures the server's clock, under the deadline of `ctx`.
/// Why it failed goes to `Options.diagnostics`.
///
/// The jobs: `scan` `{job: 1, wake_at: 1}`, of the jobs that may be
/// claimed (`wake_at` is `run_at` of a pending job and `lease_until` of a
/// running one); `expire`, the TTL of the finished jobs kept for a time;
/// `tenant` `{tenant: 1, _id: 1}`. The runs: `job_key_finished`,
/// `job_finished`, `tenant_finished` and their own `expire`.
pub fn ensureIndexes(s: *SchedulerStore, io: Io, ctx: core.Context) mongo.Error!void {
    return s.ensure(io, ctx, s.diagnostics);
}

/// For zefir.App: `ensureIndexes` under a deadline `Options.start_timeout`
/// away. Why it failed goes to the log, as a warning.
pub fn start(s: *SchedulerStore, io: Io) mongo.Error!void {
    var own: mongo.Diagnostics = .{};
    const d = s.diagnostics orelse &own;
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), s.start_timeout));
    s.ensure(io, ctx, d) catch |err| {
        log.warn("SchedulerStore.start failed: error.{t}: {s}", .{ err, d.message() });
        return err;
    };
}

/// The store's clock as the process knows it, without I/O.
pub fn now(s: *SchedulerStore, io: Io) Instant {
    return s.clock.now(io);
}

/// The database of the collections, on the client.
fn db(s: *SchedulerStore) mongo.Database {
    return .init(s.client, s.database, &s.ids);
}

fn ensure(s: *SchedulerStore, io: Io, ctx: core.Context, d: ?*mongo.Diagnostics) mongo.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const op: mongo.OperationContext = .of(ctx);
    _ = try s.db().collection(s.jobs).createIndexes(io, op, &job_indexes, .{ .allocator = a, .diagnostics = d });
    _ = try s.db().collection(s.runs).createIndexes(io, op, &run_indexes, .{ .allocator = a, .diagnostics = d });
    const before = Clock.local(io);
    const reply = try s.db().runCommand(io, op, measure, .{ .allocator = a, .diagnostics = d });
    const after = Clock.local(io);
    const server = (reply.raw().getPath("cursor.firstBatch.0.now") catch null) orelse
        return violation(d, "the reply of the aggregation of $$NOW holds no cursor.firstBatch.0.now");
    if (server != .date_time) return violation(d, "the now of the aggregation of $$NOW is not a date");
    s.clock.sample(.fromUnixMs(server.date_time.milliseconds), before, after);
}

/// The server's now, without a collection: `$documents` (MongoDB 5.1).
const measure = bson.literal(.{
    .aggregate = 1,
    .pipeline = .{.{ .@"$documents" = .{.{ .now = "$$NOW" }} }},
    .cursor = .{},
});

const job_indexes = [_]mongo.Collection.IndexModel{
    .{ .name = "scan", .keys = bson.literal(.{ .job = 1, .wake_at = 1 }), .partial_filter_expression = bson.literal(.{ .wake_at = .{ .@"$exists" = true } }) },
    .{ .name = "expire", .keys = bson.literal(.{ .expires_at = 1 }), .expire_after_seconds = 0, .partial_filter_expression = bson.literal(.{ .expires_at = .{ .@"$exists" = true } }) },
    .{ .name = "tenant", .keys = bson.literal(.{ .tenant = 1, ._id = 1 }), .partial_filter_expression = bson.literal(.{ .tenant = .{ .@"$exists" = true } }) },
};

const run_indexes = [_]mongo.Collection.IndexModel{
    .{ .name = "job_key_finished", .keys = bson.literal(.{ .job = 1, .key = 1, .finished_at = -1 }) },
    .{ .name = "job_finished", .keys = bson.literal(.{ .job = 1, .finished_at = -1 }) },
    .{ .name = "tenant_finished", .keys = bson.literal(.{ .tenant = 1, .finished_at = -1 }), .partial_filter_expression = bson.literal(.{ .tenant = .{ .@"$exists" = true } }) },
    .{ .name = "expire", .keys = bson.literal(.{ .expires_at = 1 }), .expire_after_seconds = 0, .partial_filter_expression = bson.literal(.{ .expires_at = .{ .@"$exists" = true } }) },
};

/// A database name: 1 to 63 bytes of UTF-8, without NUL and without any of
/// `/\. "$`, as the client checks it.
fn checkDatabase(text: []const u8, d: ?*mongo.Diagnostics) error{InvalidArgument}!void {
    if (text.len == 0 or text.len > 63) return invalid(d, "SchedulerStore: a database name is 1 to 63 bytes long; this one is {d}", .{text.len});
    if (std.mem.findAny(u8, text, "\x00/\\. \"$") != null) return invalid(d, "SchedulerStore: a database name holds none of / \\ . \" $, a space or NUL", .{});
    if (!std.unicode.utf8ValidateSlice(text)) return invalid(d, "SchedulerStore: a database name is UTF-8, and this one is not", .{});
}

/// A collection name: not empty, UTF-8, without `$` and NUL.
fn checkCollection(comptime field: []const u8, text: []const u8, d: ?*mongo.Diagnostics) error{InvalidArgument}!void {
    if (text.len == 0) return invalid(d, "SchedulerStore: the collection of " ++ field ++ " has an empty name", .{});
    if (std.mem.findAny(u8, text, "\x00$") != null) return invalid(d, "SchedulerStore: the name of the collection of " ++ field ++ " holds a '$' or a NUL", .{});
    if (!std.unicode.utf8ValidateSlice(text)) return invalid(d, "SchedulerStore: the name of the collection of " ++ field ++ " is not UTF-8", .{});
}

fn invalid(d: ?*mongo.Diagnostics, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (d) |x| x.set(null, null, fmt, args);
    return error.InvalidArgument;
}

fn violation(d: ?*mongo.Diagnostics, comptime text: []const u8) mongo.Error {
    if (d) |x| x.set(.receive, null, text, .{});
    return error.ProtocolViolation;
}

test {
    _ = documents;
}
