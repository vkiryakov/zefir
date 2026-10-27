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
const documents = @import("../scheduler/documents.zig");
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
    const as_expected = try fixture.pendingDoc(a, "send", "k1", fixture.life_hex, .{});
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
        .{ .reply = refused },                                                                                                .{ .reply = try fixture.found(a, jobs_ns, &.{as_expected}) },
        // create, no reply, no record, due in an hour: the same upsert again.
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
    const update: Store.UpdateRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .expect = .{ .life = fixture.life, .revision = 0, .state = .pending }, .set = .{ .pause_requested = true }, .tag = fixture.tag };
    try testing.expectEqual(Store.UpdateResult{ .updated = 1 }, try f.store.update(io, fixture.no_deadline, &update, f.call()));
    try testing.expectError(error.Refused, f.store.update(io, fixture.no_deadline, &update, f.call()));
    try testing.expectEqual(@as(?i32, 2), f.diagnostics.code);
    try expectClean(&f);

    const create: Store.CreateRequest = .{ .job = "send", .key = "k1", .life = fixture.life, .plan = "", .payload = payload, .run_at = .{ .after = .fromSeconds(3600) } };
    try testing.expectEqual(Store.CreateResult.created, try f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
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

/// A record "send/k1" of `life_text` in `state` at `revision`, whose last
/// write left `tag`; a running one has the claim of "w2".
fn recordDoc(a: std.mem.Allocator, life_text: []const u8, state: scheduler.State, revision: i64, tag: []const u8) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putString("_id", "send/k1");
    try b.putString("job", "send");
    try b.putString("key", "k1");
    try b.putString("life", life_text);
    try b.putString("plan", "");
    try b.putString("payload", "{}");
    try b.putString("state", @tagName(state));
    try b.putDateTime("scheduled_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putInt32("attempt", if (state == .running) 1 else 0);
    try b.putInt64("fence", if (state == .running) 1 else 0);
    try b.putInt64("revision", revision);
    try b.putString("tag", tag);
    if (state == .running) {
        try b.putString("owner", "w2");
        try b.putDateTime("claimed_at", .{ .milliseconds = 1_793_000_001_000 });
        try b.putDateTime("lease_until", .{ .milliseconds = 1_793_000_061_000 });
    } else try b.putDateTime("run_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putDateTime("created_at", .{ .milliseconds = 1_792_999_000_000 });
    try b.putDateTime("updated_at", .{ .milliseconds = 1_792_999_000_000 });
    return (try b.finish()).raw();
}

const other_life_hex = "0123456789abcdef0123456789abcdef";

test "after a lost reply, update answers conflict only when its change cannot have applied" {
    var f: Fixture = .{};
    const a = f.a();
    // The change applied, then a claim of another worker wrote its own tag:
    // the same life, a revision past the one expected.
    const claimed_after = try recordDoc(a, fixture.life_hex, .running, 4, "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd-1");
    // The key made again since: another life, at the revision and in the
    // state that the change expected.
    const reborn = try recordDoc(a, other_life_hex, .pending, 3, "efefefefefefefefefefefefefefefef");
    // A claim came first: the same life at the revision expected, running.
    const claimed_before = try recordDoc(a, fixture.life_hex, .running, 3, "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd-1");
    try f.start(&.{
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{claimed_after}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{reborn}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{claimed_before}) },
    });
    defer f.stop();
    const update: Store.UpdateRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .expect = .{ .life = fixture.life, .revision = 3, .state = .pending }, .set = .{ .run_at = .{ .after = .zero } }, .tag = fixture.tag };

    // The store cannot tell its change, written over since, from another
    // change that came first.
    try testing.expectError(error.OutcomeUnknown, f.store.update(io, fixture.no_deadline, &update, f.call()));
    try expectClean(&f);
    try afterProbe();
    // A record of another life: the filter holds the life, so the change
    // never lands on it.
    switch (try f.store.update(io, fixture.no_deadline, &update, f.call())) {
        .conflict => |now| try testing.expectEqualStrings(other_life_hex, &documents.hex(now.life)),
        else => return error.TestUnexpectedResult,
    }
    try afterProbe();
    // The revision expected: an applied change would have raised it.
    switch (try f.store.update(io, fixture.no_deadline, &update, f.call())) {
        .conflict => |now| {
            try testing.expectEqual(scheduler.State.running, now.state);
            try testing.expectEqual(@as(u64, 3), now.revision);
        },
        else => return error.TestUnexpectedResult,
    }
    try f.expectCommands(&.{ "update", "find", "update", "find", "update", "find" });
}

test "after a lost reply, create sends its upsert again only while no claim can have taken the record" {
    var f: Fixture = .{};
    const a = f.a();
    const nothing = try fixture.found(a, jobs_ns, &.{});
    const upserted = bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "send/k1" }}, .ok = 1.0 });
    // Each upsert loses its reply, and the record is not there when read
    // again.
    try f.start(&.{
        .close_connection,      .{ .reply = nothing },
        .close_connection,      .{ .reply = nothing },
        .close_connection,      .{ .reply = nothing },
        .close_connection,      .{ .reply = nothing },
        .{ .reply = upserted },
    });
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var create: Store.CreateRequest = .{ .job = "send", .key = "k1", .life = fixture.life, .plan = "", .payload = payload, .run_at = .{ .after = .zero } };

    // Due at once: a claim may have run the life and its finish removed
    // it, and the upsert would make it again.
    try testing.expectError(error.OutcomeUnknown, f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
    try testing.expectEqual(@as(usize, 2), f.served.script.received(io));
    try expectClean(&f);
    try afterProbe();
    // Without a deadline, no moment is sure to come before every claim.
    create.run_at = .{ .after = .fromSeconds(3600) };
    try testing.expectError(error.OutcomeUnknown, f.store.create(io, fixture.no_deadline, &create, f.call()));
    try testing.expectEqual(@as(usize, 4), f.served.script.received(io));
    try afterProbe();
    // Due 30 s from now, less than a minute past the deadline 10 s away.
    create.run_at = .{ .at = f.store.now(io).add(.fromSeconds(30)) };
    try testing.expectError(error.OutcomeUnknown, f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
    try testing.expectEqual(@as(usize, 6), f.served.script.received(io));
    try afterProbe();
    // Due in two hours: no claim can take it before the call is over.
    create.run_at = .{ .at = f.store.now(io).add(.fromSeconds(7200)) };
    try testing.expectEqual(Store.CreateResult.created, try f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
    try f.expectCommands(&.{ "update", "find", "update", "find", "update", "find", "update", "find", "update" });
}
