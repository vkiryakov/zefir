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

test "a write in place after an answered error or code 50 ran without its write concern" {
    var md: mongo.Diagnostics = .{};
    // The deadline passed on the client's side: the server said nothing.
    try testing.expect(!Call.unconfirmed(error.Timeout, &md));
    try testing.expect(!Call.unconfirmed(error.ConnectionLost, &md));
    try testing.expect(Call.unconfirmed(error.WriteFailed, &md));
    // MaxTimeMSExpired while the server waited for the journal.
    md.server = .{ .code = 50 };
    try testing.expect(Call.unconfirmed(error.Timeout, &md));
}

test "a write that ran without its write concern warns only when its reply shows a change" {
    // A claim that took nothing, a renewal not of this claim, an update or
    // a transition that matched nothing, a delete of nothing, a create of a
    // job that is there, a row of the history that is there: nothing of
    // the write is in place.
    try testing.expect(!Call.changed(mongo.Collection.UpdateResult{}));
    try testing.expect(!Call.changed(mongo.Collection.UpdateResult{ .matched = 1 }));
    try testing.expect(!Call.changed(mongo.Collection.DeleteResult{}));
    try testing.expect(!Call.changed(Call.Modified{ .value = null }));
    // A record or a row made or changed, a record deleted, a record
    // claimed or renewed.
    try testing.expect(Call.changed(mongo.Collection.UpdateResult{ .upserted_id = .{ .string = "send/k1" } }));
    try testing.expect(Call.changed(mongo.Collection.UpdateResult{ .matched = 1, .modified = 1 }));
    try testing.expect(Call.changed(mongo.Collection.DeleteResult{ .deleted = 1 }));
    try testing.expect(Call.changed(Call.Modified{ .value = bson.literal(.{ ._id = "send/k1" }) }));
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
    const duplicate = bson.literal(.{ .n = 0, .writeErrors = .{.{ .index = 0, .code = 11000, .errmsg = "E11000 duplicate key error" }}, .ok = 1.0 });
    const one = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 });
    try f.start(&.{
        // update, no reply: our tag is there, so it ran.
        .close_connection,                                                                                                    .{ .reply = try fixture.found(a, jobs_ns, &.{ours}) },
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
    try afterProbe();
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

/// A writeConcernError as mongod writes one, of `code`: 64 when the
/// journal did not confirm in time, 50 when the deadline passed meanwhile.
fn concernError(code: i32) bson.RawDocument {
    return switch (code) {
        50 => bson.literal(.{ .code = 50, .codeName = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" }),
        else => bson.literal(.{ .code = 64, .codeName = "WriteConcernFailed", .errmsg = "waiting for the journal timed out" }),
    };
}

/// The reply of a findAndModify that changed `value`, or none, and whose
/// write concern failed with `code`.
fn modifiedUnconfirmed(a: std.mem.Allocator, value: ?bson.RawDocument, code: i32) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("lastErrorObject");
    try b.putInt32("n", if (value != null) 1 else 0);
    try b.putBoolean("updatedExisting", value != null);
    try b.end();
    if (value) |doc| try b.putDocument("value", doc) else try b.putNull("value");
    try b.putDocument("writeConcernError", concernError(code));
    try b.putDouble("ok", 1);
    return (try b.finish()).raw();
}

/// What a write of one item did, as its reply counts it.
const Written = struct { n: i32, modified: i32 = 0, upserted: bool = false };

/// The reply of a write of one item that did `w`, and whose write concern
/// failed with `code`.
fn writtenUnconfirmed(a: std.mem.Allocator, w: Written, code: i32) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putInt32("n", w.n);
    try b.putInt32("nModified", w.modified);
    if (w.upserted) try b.put("upserted", .{.{ .index = 0, ._id = "send/k1" }});
    try b.putDocument("writeConcernError", concernError(code));
    try b.putDouble("ok", 1);
    return (try b.finish()).raw();
}

/// The one row of a finish of the claim of "w1" with fence 1, kept always.
const one_row = [_]scheduler.Run{.{ .job = "send", .key = "k1", .tenant = null, .life = fixture.life, .fence = 1, .attempt = 1, .scheduled_at = .fromUnixMs(0), .started_at = .fromUnixMs(0), .finished_at = .fromUnixMs(0), .outcome = .succeeded, .error_name = null, .instance = "w1", .expires_at = null }};

/// A finish of the claim of "w1" with fence 1 at revision 0 to `next`.
fn finishOf(next: Store.Next) Store.FinishRequest {
    return .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .revision = 0, .tag = fixture.tag, .next = next, .last = null };
}

test "a row of the history that ran without its write concern is there, and the transition goes" {
    var f: Fixture = .{};
    const a = f.a();
    const one = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 });
    const invalid = bson.literal(.{ .n = 0, .writeErrors = .{.{ .index = 0, .code = 121, .errmsg = "Document failed validation" }}, .ok = 1.0 });
    try f.start(&.{
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .upserted = true }, 64) }, .{ .reply = one },
        // Code 50: the deadline passed while the server waited.
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .upserted = true }, 50) }, .{ .reply = one },
        // The server refused the row: the transition does not go.
        .{ .reply = invalid },
    });
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var finish = finishOf(.{ .done = .{ .state = .succeeded, .keep = .forever } });
    finish.history = .{ .runs = &one_row, .keep = .forever };
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try testing.expectError(error.Refused, f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try testing.expectEqual(@as(?i32, 121), f.diagnostics.code);
    try f.expectCommands(&.{ "update", "update", "update", "update", "update" });
}

test "a write that ran without its write concern gives what its reply says it did" {
    var f: Fixture = .{};
    const a = f.a();
    const lease = bson.literal(.{ ._id = "send/k1", .lease_until = bson.DateTime{ .milliseconds = 1_793_000_061_000 } });
    const claimed = try recordDoc(a, fixture.life_hex, .running, 0, fixture.tag_hex ++ "-1");
    const reborn = try recordDoc(a, other_life_hex, .pending, 0, "efefefefefefefefefefefefefefefef");
    const of_life = bson.literal(.{ ._id = "send/k1", .life = fixture.life_hex });
    try f.start(&.{
        // create: made, replaced, and existing with code 50.
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .upserted = true }, 64) },
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .modified = 1 }, 64) },
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1 }, 50) },
        // update: applied; not applied, and the record is read for the
        // conflict.
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .modified = 1 }, 64) },
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 0 }, 64) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{reborn}) },
        // remove: one removed; none, with code 50.
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1 }, 64) },
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 0 }, 50) },
        // finish: the transition, and the removal.
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1, .modified = 1 }, 64) },
        .{ .reply = try writtenUnconfirmed(a, .{ .n = 1 }, 64) },
        // claim: a record taken; none due, and when the next is.
        .{ .reply = try modifiedUnconfirmed(a, claimed, 64) },
        .{ .reply = try modifiedUnconfirmed(a, null, 64) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        // renew: renewed, with code 50 too; not this claim, and the record
        // is read for whose it is.
        .{ .reply = try modifiedUnconfirmed(a, lease, 64) },
        .{ .reply = try modifiedUnconfirmed(a, lease, 50) },
        .{ .reply = try modifiedUnconfirmed(a, null, 64) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{of_life}) },
    });
    defer f.stop();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    const create: Store.CreateRequest = .{ .job = "send", .key = "k1", .life = fixture.life, .plan = "", .payload = payload, .run_at = .{ .after = .zero } };
    try testing.expectEqual(Store.CreateResult.created, try f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
    try testing.expectEqual(Store.CreateResult.replaced, try f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));
    try testing.expectEqual(Store.CreateResult.existing, try f.store.create(io, fixture.within(.fromSeconds(10)), &create, f.call()));

    const update: Store.UpdateRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .expect = .{ .life = fixture.life, .revision = 0, .state = .pending }, .set = .{ .pause_requested = true }, .tag = fixture.tag };
    try testing.expectEqual(Store.UpdateResult{ .updated = 1 }, try f.store.update(io, fixture.no_deadline, &update, f.call()));
    switch (try f.store.update(io, fixture.no_deadline, &update, f.call())) {
        .conflict => |now| try testing.expectEqualStrings(other_life_hex, &documents.hex(now.life)),
        else => return error.TestUnexpectedResult,
    }

    try testing.expect(try f.store.remove(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call()));
    try testing.expect(!try f.store.remove(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call()));

    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finishOf(.{ .done = .{ .state = .succeeded, .keep = .forever } }), f.call()));
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finishOf(.delete), f.call()));

    const claim: Store.ClaimRequest = .{ .owner = "w2", .any_key = &.{"send"}, .keyed_only = &.{}, .max = 1, .lease = .fromSeconds(60), .tag = fixture.tag };
    const took = try f.store.claim(io, fixture.no_deadline, &claim, f.call());
    try testing.expectEqual(@as(usize, 1), took.claimed.len);
    try testing.expectEqualStrings("k1", took.claimed[0].record.key);
    const none = try f.store.claim(io, fixture.no_deadline, &claim, f.call());
    try testing.expectEqual(@as(usize, 0), none.claimed.len);
    try testing.expectEqual(@as(?std.Io.Duration, null), none.next_in);

    const renew: Store.RenewRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .lease = .fromSeconds(60) };
    try testing.expectEqual(Store.RenewResult.renewed, try f.store.renew(io, fixture.no_deadline, &renew, f.call()));
    try testing.expectEqual(Store.RenewResult.renewed, try f.store.renew(io, fixture.no_deadline, &renew, f.call()));
    try testing.expectEqual(Store.RenewResult.lost, try f.store.renew(io, fixture.no_deadline, &renew, f.call()));
    try expectClean(&f);
    try f.expectCommands(&.{
        "update",    "update",        "update",        "update",        "update",        "find",
        "delete",    "delete",        "update",        "delete",        "findAndModify", "findAndModify",
        "aggregate", "findAndModify", "findAndModify", "findAndModify", "find",
    });
}

/// What a record "send/k1" may be when a finish of the claim of "w1" with
/// fence 1 at revision 0 reads it again after a lost reply.
const After = struct {
    life: []const u8 = fixture.life_hex,
    state: scheduler.State,
    fence: i64,
    revision: i64 = 0,
    /// The mark of the write that left the record so.
    tag: []const u8,
    /// Running: the claim of "w2" took over the claim of "w1".
    took_over: bool = false,
};

/// The record of `after`; a running one has the claim of "w2".
fn afterDoc(a: std.mem.Allocator, after: After) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putString("_id", "send/k1");
    try b.putString("job", "send");
    try b.putString("key", "k1");
    try b.putString("life", after.life);
    try b.putString("plan", "");
    try b.putString("payload", "{}");
    try b.putString("state", @tagName(after.state));
    try b.putDateTime("scheduled_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putInt32("attempt", if (after.state == .running) 1 else 0);
    try b.putInt64("fence", after.fence);
    try b.putInt64("revision", after.revision);
    try b.putString("tag", after.tag);
    switch (after.state) {
        .running => {
            try b.putString("owner", "w2");
            try b.putDateTime("claimed_at", .{ .milliseconds = 1_793_000_005_000 });
            try b.putDateTime("lease_until", .{ .milliseconds = 1_793_000_065_000 });
            if (after.took_over) try b.put("prev", .{
                .owner = "w1",
                .claimed_at = bson.DateTime{ .milliseconds = 1_793_000_001_000 },
                .attempt = @as(i32, 1),
                .scheduled_at = bson.DateTime{ .milliseconds = 1_793_000_000_000 },
            });
        },
        .pending, .paused => try b.putDateTime("run_at", .{ .milliseconds = 1_793_000_000_000 }),
        .succeeded, .failed => try b.putDateTime("finished_at", .{ .milliseconds = 1_793_000_009_000 }),
    }
    try b.putDateTime("created_at", .{ .milliseconds = 1_792_999_000_000 });
    try b.putDateTime("updated_at", .{ .milliseconds = 1_792_999_000_000 });
    return (try b.finish()).raw();
}

test "after a lost reply, finish answers lost only when its transition cannot have applied" {
    var f: Fixture = .{};
    const a = f.a();
    const claim_tag = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd-1";
    const other_tag = "efefefefefefefefefefefefefefefef";
    // The transition made the record due, and a claim of "w2" took it
    // before the store read it: one fence on, no claim taken over.
    const claimed_after = try afterDoc(a, .{ .state = .running, .fence = 2, .tag = claim_tag });
    // The claim one fence on took over the claim of "w1", still running:
    // the transition had not applied, and its condition holds no more.
    const taken_over = try afterDoc(a, .{ .state = .running, .fence = 2, .tag = claim_tag, .took_over = true });
    // The transition applied, and a change of the client wrote its tag.
    const changed_after = try afterDoc(a, .{ .state = .pending, .fence = 1, .revision = 1, .tag = other_tag });
    // The next claim ran the record and finished it.
    const finished_after = try afterDoc(a, .{ .state = .succeeded, .fence = 2, .tag = other_tag });
    // A cancel, and the key made again since.
    const reborn = try afterDoc(a, .{ .life = other_life_hex, .state = .pending, .fence = 0, .tag = other_tag });
    try f.start(&.{
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{claimed_after}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{taken_over}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{changed_after}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{finished_after}) },
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{reborn}) },
        // A cancel: no record.
        .close_connection, .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
    });
    defer f.stop();
    const finish = finishOf(.{ .wait = .{ .state = .pending, .run_at = .{ .after = .zero }, .scheduled_at = null, .attempt = 0 } });

    // The store cannot tell its transition, which a claim, a change or a
    // cancel came after, from one that never applied.
    try testing.expectError(error.OutcomeUnknown, f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try expectClean(&f);
    try afterProbe();
    try testing.expectEqual(Store.FinishResult.lost, try f.store.finish(io, fixture.no_deadline, &finish, f.call()));
    try afterProbe();
    for (0..4) |_| {
        try testing.expectError(error.OutcomeUnknown, f.store.finish(io, fixture.no_deadline, &finish, f.call()));
        try afterProbe();
    }
    try f.expectCommands(&.{ "update", "find", "update", "find", "update", "find", "update", "find", "update", "find", "update", "find" });
}

test "a renewal that may have run and failed again tells both errors" {
    var f: Fixture = .{};
    const a = f.a();
    try f.start(&.{
        .close_connection,
        .{ .reply = try Script.failure(a, .{ .code = 2, .code_name = "BadValue", .errmsg = "the second try was refused" }) },
    });
    defer f.stop();
    const renew: Store.RenewRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .lease = .fromSeconds(60) };
    try testing.expectError(error.OutcomeUnknown, f.store.renew(io, fixture.no_deadline, &renew, f.call()));
    try expectClean(&f);
    // The first error with its own details, then the renewal sent again.
    const text = f.diagnostics.message();
    const first = std.mem.find(u8, text, "renew: the write may have run (error.ConnectionLost of zefir-mongo: ") orelse {
        std.debug.print("the diagnostics: {s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    const again = std.mem.find(u8, text, "sending it again failed: error.CommandFailed of zefir-mongo: ") orelse {
        std.debug.print("the diagnostics: {s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    const refused = std.mem.find(u8, text, "the second try was refused") orelse return error.TestUnexpectedResult;
    try testing.expect(first < again and again < refused);
    try f.expectCommands(&.{ "findAndModify", "findAndModify" });
}
