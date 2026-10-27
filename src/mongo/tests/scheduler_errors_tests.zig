//! Tests of the errors of `mongo.SchedulerStore` against
//! `mongo.testing.FakeServer`: the class of each error of zefir-mongo, and
//! how a write that may have run is resolved by reading the record again
//! (table 8.6 of the design).

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const Script = mongo.testing.Script;
const Call = @import("../scheduler/Call.zig");
const fixture = @import("scheduler_fixture.zig");
const Fixture = fixture.Fixture;
const Store = scheduler.Store;

const io = testing.io;
const jobs_ns = "app.scheduler_jobs";
/// A payload that no text of the store may hold.
const payload = "{\"card\":\"4111-SECRET\"}";

test "each error of zefir-mongo is not sent, answered or without a reply, and what it is to the store" {
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = "mongodb://127.0.0.1:1" });
    defer client.deinit();
    var store: mongo.SchedulerStore = try .init(testing.allocator, io, &client, .{ .database = "app" });
    defer store.deinit();
    var d: scheduler.Diagnostics = .{};
    var c: Call = .init(&store, io, .root, .{ .allocator = testing.allocator, .diagnostics = &d }, "get");
    defer c.deinit();
    const Row = struct { mongo.Error, Call.Class, Store.StoreError };
    const table = [_]Row{
        .{ error.InvalidArgument, .not_sent, error.InvalidArgument },   .{ error.Unsupported, .not_sent, error.InvalidArgument },
        .{ error.Closed, .not_sent, error.Unavailable },                .{ error.Unavailable, .not_sent, error.Unavailable },
        .{ error.PoolExhausted, .not_sent, error.Unavailable },         .{ error.AuthenticationFailed, .not_sent, error.Refused },
        .{ error.DeadlineExceeded, .not_sent, error.DeadlineExceeded }, .{ error.Cancelled, .not_sent, error.Cancelled },
        .{ error.CommandFailed, .answered, error.Refused },             .{ error.WriteFailed, .answered, error.Refused },
        .{ error.ConnectionLost, .no_reply, error.Unavailable },        .{ error.Timeout, .no_reply, error.DeadlineExceeded },
        .{ error.Interrupted, .no_reply, error.Cancelled },             .{ error.IncompleteWrite, .no_reply, error.Unavailable },
        .{ error.ProtocolViolation, .no_reply, error.Unavailable },     .{ error.OutOfMemory, .memory, error.OutOfMemory },
    };
    comptime std.debug.assert(table.len == @typeInfo(mongo.Error).error_set.error_names.?.len);
    for (table) |row| {
        try testing.expectEqual(row[1], Call.classOf(row[0]));
        // As an error of a read, or of a write known not to have run.
        try testing.expectEqual(row[2], c.nothing(row[0]));
    }
    // The server's code goes to the diagnostics.
    c.md.set(.receive, null, "not authorized", .{});
    c.md.server = .{ .code = 13 };
    try testing.expectEqual(error.Refused, c.nothing(error.CommandFailed));
    try testing.expectEqual(@as(?i32, 13), d.code);
    try testing.expectEqualStrings("get: error.CommandFailed of zefir-mongo: not authorized", d.message());
}

/// Fails unless the diagnostics hold neither the connection string nor
/// the payload.
fn expectClean(f: *Fixture) !void {
    const text = f.diagnostics.message();
    try testing.expect(std.mem.find(u8, text, "mongodb://") == null);
    try testing.expect(std.mem.find(u8, text, "SECRET") == null);
}

/// After a lost connection the pool probes again at most every 500 ms: the
/// next scenario's reread must not find it paused.
fn afterProbe() !void {
    try mongo.testing.sleepAtLeast(io, .fromMilliseconds(600));
}

test "a write that may have run is resolved by reading the record again" {
    var f: Fixture = .{};
    const a = f.a();
    const ours = try fixture.pendingDoc(a, "send", "k1", fixture.life_hex, .{ .tag = fixture.tag_hex });
    const theirs = try fixture.pendingDoc(a, "send", "k1", "0123456789abcdef0123456789abcdef", .{});
    const tagged_claim = bson.literal(.{
        ._id = "send/k1",
        .job = "send",
        .key = "k1",
        .life = fixture.life_hex,
        .plan = "",
        .payload = "{}",
        .state = "running",
        .scheduled_at = bson.DateTime{ .milliseconds = 0 },
        .attempt = 1,
        .fence = @as(i64, 1),
        .revision = @as(i64, 0),
        .owner = "w1",
        .tag = fixture.tag_hex ++ "-1",
        .claimed_at = bson.DateTime{ .milliseconds = 9 },
        .lease_until = bson.DateTime{ .milliseconds = 99 },
        .created_at = bson.DateTime{ .milliseconds = 0 },
        .updated_at = bson.DateTime{ .milliseconds = 0 },
    });
    const refused = try Script.failure(a, .{ .code = 2, .code_name = "BadValue", .errmsg = "the server refused it" });
    const concern = bson.literal(.{ .n = 1, .nModified = 1, .writeConcernError = .{ .code = 64, .codeName = "WriteConcernFailed", .errmsg = "waiting for the journal timed out" }, .ok = 1.0 });
    const duplicate = bson.literal(.{ .n = 0, .writeErrors = .{.{ .index = 0, .code = 11000, .errmsg = "E11000 duplicate key error" }}, .ok = 1.0 });
    const one = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 });
    try f.start(&.{
        // update, writeConcernError: our tag is there, so it ran.
        .{ .reply = concern },                                                                                                .{ .reply = try fixture.found(a, jobs_ns, &.{ours}) },
        // update, refused: the record as expected, so it did not run.
        .{ .reply = refused },                                                                                                .{ .reply = try fixture.found(a, jobs_ns, &.{theirs}) },
        // create, no reply, no record: the same upsert again.
        .close_connection,                                                                                                    .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        .{ .reply = bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "send/k1" }}, .ok = 1.0 }) },
        // create, a unique key error: a live record of another life.
        .{ .reply = duplicate },
        .{ .reply = try fixture.found(a, jobs_ns, &.{theirs}) },
        // renew, no reply: the same renew again.
                                                                     .close_connection,
        .{ .reply = try fixture.modified(a, bson.literal(.{ ._id = "send/k1" })) },
        // claim, no reply: the record of the claim's first tag is ours.
                                                  .close_connection,
        .{ .reply = try fixture.found(a, jobs_ns, &.{tagged_claim}) },
        // finish, no reply, the claim still running: unknown.
                                                               .close_connection,
        .{ .reply = try fixture.found(a, jobs_ns, &.{tagged_claim}) },
        // finish to delete, no reply, no record: done (A48).
                                                               .close_connection,
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        // remove, no reply, no record: removed.
                                                                           .close_connection,
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        // finish: a unique key error on its row is the row, then the
        // transition.
                                                                           .{ .reply = duplicate },
        .{ .reply = one },
        // update, refused, and the read fails too.
                                                                                                           .{ .reply = refused },
        .close_connection,
    });
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const update: Store.UpdateRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .expect = .{ .revision = 0, .state = .pending }, .set = .{ .pause_requested = true }, .tag = fixture.tag };
    try testing.expectEqual(Store.UpdateResult{ .updated = 1 }, try f.store.update(io, fixture.no_deadline, &update, f.call()));
    try testing.expectError(error.Refused, f.store.update(io, fixture.no_deadline, &update, f.call()));
    try testing.expectEqual(@as(?i32, 2), f.diagnostics.code);
    try expectClean(&f);

    const create: Store.CreateRequest = .{ .job = "send", .key = "k1", .life = fixture.life, .plan = "", .payload = payload, .run_at = .{ .after = .zero } };
    try testing.expectEqual(Store.CreateResult.created, try f.store.create(io, fixture.no_deadline, &create, f.call()));
    try afterProbe();
    try testing.expectEqual(Store.CreateResult.existing, try f.store.create(io, fixture.no_deadline, &create, f.call()));
    const renew: Store.RenewRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .lease = .fromSeconds(60) };
    try testing.expectEqual(Store.RenewResult.renewed, try f.store.renew(io, fixture.no_deadline, &renew, f.call()));
    try afterProbe();
    const claimed = try f.store.claim(io, fixture.no_deadline, &.{ .owner = "w1", .any_key = &.{"send"}, .keyed_only = &.{}, .max = 3, .lease = .fromSeconds(60), .tag = fixture.tag }, f.call());
    try testing.expectEqual(@as(usize, 1), claimed.claimed.len);
    try testing.expectEqual(@as(?std.Io.Duration, null), claimed.next_in);
    try fixture.expectDoc(bson.literal(.{ .owner = "w1", .tag = fixture.tag_hex ++ "-1", .state = "running" }), try fixture.docAt((try f.entry(12)).body, "filter"));
    try afterProbe();

    var finish: Store.FinishRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .revision = 0, .tag = fixture.tag, .next = .{ .done = .{ .state = .succeeded, .keep = .forever } }, .last = null };
    try testing.expectError(error.OutcomeUnknown, f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try expectClean(&f);
    try afterProbe();
    finish.next = .delete;
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try afterProbe();
    try testing.expect(try f.store.remove(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call()));

    const rows = [_]scheduler.Run{.{ .job = "send", .key = "k1", .tenant = null, .life = fixture.life, .fence = 1, .attempt = 1, .scheduled_at = .fromUnixMs(0), .started_at = .fromUnixMs(0), .finished_at = .fromUnixMs(0), .outcome = .succeeded, .error_name = null, .instance = "w1", .expires_at = null }};
    finish.next = .{ .done = .{ .state = .succeeded, .keep = .forever } };
    finish.history = .{ .runs = &rows, .keep = .forever };
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finish, f.call()));

    try testing.expectError(error.OutcomeUnknown, f.store.update(io, fixture.no_deadline, &update, f.call()));
    try expectClean(&f);
    try f.expectCommands(&.{
        "update", "find",          "update",        "find",
        "update", "find",          "update",        "update",
        "find",   "findAndModify", "findAndModify", "findAndModify",
        "find",   "update",        "find",          "delete",
        "find",   "delete",        "find",          "update",
        "update", "update",        "find",
    });
}
