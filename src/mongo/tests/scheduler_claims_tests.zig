//! Tests of the claims of `mongo.SchedulerStore` against
//! `mongo.testing.FakeServer`: what claim, renew and finish send, and what
//! the store makes of the replies.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const Clock = @import("../scheduler/Clock.zig");
const fixture = @import("scheduler_fixture.zig");
const Fixture = fixture.Fixture;
const Store = scheduler.Store;

const io = testing.io;
const at_ms = 1_793_018_096_789;
const jobs_ns = "app.scheduler_jobs";

/// A record of "send" as a claim by "w1" leaves it, with `tag`; `over`
/// adds the claim it took over.
fn runningDoc(a: std.mem.Allocator, key: []const u8, tag: []const u8, over: bool) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putString("_id", try std.fmt.allocPrint(a, "send/{s}", .{key}));
    try b.putString("job", "send");
    try b.putString("key", key);
    try b.putString("life", fixture.life_hex);
    try b.putString("plan", "");
    try b.putString("payload", "{}");
    try b.putString("state", "running");
    try b.putDateTime("scheduled_at", .{ .milliseconds = at_ms });
    try b.putInt32("attempt", 1);
    try b.putInt64("fence", 1);
    try b.putInt64("revision", 0);
    try b.putString("owner", "w1");
    try b.putString("tag", tag);
    try b.putDateTime("claimed_at", .{ .milliseconds = at_ms + 1000 });
    try b.putDateTime("lease_until", .{ .milliseconds = at_ms + 61_000 });
    if (over) try b.put("prev", .{ .owner = "w0", .claimed_at = bson.DateTime{ .milliseconds = at_ms - 60_000 } });
    try b.putDateTime("created_at", .{ .milliseconds = at_ms });
    try b.putDateTime("updated_at", .{ .milliseconds = at_ms });
    return (try b.finish()).raw();
}

const branches = .{ .{ .job = .{ .@"$in" = .{"report"} } }, .{ .job = .{ .@"$in" = .{"send"} }, .key = .{ .@"$ne" = "" } } };

test "claim takes records one findAndModify at a time, each with its own tag" {
    var f: Fixture = .{};
    const a = f.a();
    const first = try runningDoc(a, "k1", fixture.tag_hex ++ "-1", false);
    const second = try runningDoc(a, "k2", fixture.tag_hex ++ "-2", true);
    try f.start(&.{ .{ .reply = try fixture.modified(a, first) }, .{ .reply = try fixture.modified(a, second) } });
    defer f.stop();
    const local = Clock.local(io).unix_ms;
    const request: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{"report"}, .keyed_only = &.{"send"}, .max = 2, .lease = .fromSeconds(60), .tag = fixture.tag };
    const result = try f.store.claim(io, fixture.no_deadline, &request, f.call());
    try testing.expectEqual(@as(usize, 2), result.claimed.len);
    try testing.expectEqualStrings("k1", result.claimed[0].record.key);
    try testing.expect(result.claimed[0].took_over == null);
    const over = result.claimed[1].took_over orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("w0", over.owner);
    try testing.expectEqual(@as(i64, at_ms - 60_000), over.claimed_at.unix_ms);
    // max reached: no next_in, no aggregation.
    try testing.expectEqual(@as(?std.Io.Duration, null), result.next_in);
    try f.expectCommands(&.{ "findAndModify", "findAndModify" });

    for (0..2) |k| {
        const body = (try f.entry(k)).body;
        try fixture.expectDoc(bson.literal(.{ .@"0" = branches[0], .@"1" = branches[1] }), try fixture.docAt(body, "query.$or"));
        try fixture.expectDoc(bson.literal(.{ .@"$in" = .{ "pending", "running" } }), try fixture.docAt(body, "query.state"));
        try fixture.expectDoc(bson.literal(.{ .@"$lte" = .{ "$wake_at", "$$NOW" } }), try fixture.docAt(body, "query.$expr"));
        // The range of the index: the estimate of the server's now and 2 s.
        const hi = (try body.getPath("query.wake_at.$lte")) orelse return error.TestUnexpectedResult;
        if (hi != .date_time) return error.TestUnexpectedResult;
        try testing.expect(hi.date_time.milliseconds >= local + 2_000 - 5_000 and hi.date_time.milliseconds <= local + 2_000 + 5_000);
        try fixture.expectDoc(bson.literal(.{ .wake_at = 1 }), try fixture.docAt(body, "sort"));
        try fixture.expectDoc(fixture.journal, try fixture.docAt(body, "writeConcern"));
        const new = (try body.get("new")) orelse return error.TestUnexpectedResult;
        try testing.expect(new == .boolean and new.boolean);
        const lease = .{ .@"$add" = .{ "$$NOW", @as(i64, 60_000) } };
        const expected = .{ .@"$set" = .{
            .prev = .{ .@"$cond" = .{ .{ .@"$eq" = .{ "$state", "running" } }, .{ .owner = "$owner", .claimed_at = "$claimed_at" }, "$$REMOVE" } },
            .state = "running",
            .owner = .{ .@"$literal" = "w1" },
            .tag = "",
            .attempt = .{ .@"$add" = .{ "$attempt", 1 } },
            .fence = .{ .@"$add" = .{ "$fence", @as(i64, 1) } },
            .claimed_at = "$$NOW",
            .lease_until = lease,
            .wake_at = lease,
            .run_at = "$$REMOVE",
        } };
        // The tag of the k-th record: the claim's and k.
        var stage: [4096]u8 = undefined;
        const tagged = try withTag(&stage, bson.literal(expected), if (k == 0) fixture.tag_hex ++ "-1" else fixture.tag_hex ++ "-2");
        try fixture.expectDoc(tagged, try fixture.docAt(body, "update.0"));
    }
}

/// `doc`, a `$set` stage with an empty `tag`, with `tag` in its place.
fn withTag(buffer: []u8, doc: bson.RawDocument, tag: []const u8) !bson.RawDocument {
    var fba: std.heap.FixedBufferAllocator = .init(buffer);
    var b: bson.Builder = .init(fba.allocator());
    const set = try fixture.docAt(doc, "$set");
    try b.beginDocument("$set");
    var it = set.iterator();
    while (try it.next()) |element| {
        if (std.mem.eql(u8, element.key, "tag")) try b.putString("tag", tag) else try b.putValue(element.key, element.value);
    }
    try b.end();
    return (try b.finish()).raw();
}

test "fewer than max: next_in from one aggregation with the same branches" {
    var f: Fixture = .{};
    const a = f.a();
    const doc = try runningDoc(a, "k1", fixture.tag_hex ++ "-1", false);
    var b: bson.Builder = .init(a);
    try b.putInt64("in_ms", 1500);
    try b.putDateTime("now", .{ .milliseconds = Clock.local(io).unix_ms + 3_600_000 });
    const soon = (try b.finish()).raw();
    try f.start(&.{
        .{ .reply = try fixture.modified(a, doc) },            .{ .reply = try fixture.modified(a, null) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{soon}) }, .{ .reply = try fixture.modified(a, null) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
    });
    defer f.stop();
    // Only keyed_only: one branch.
    var request: Store.ClaimRequest = .{ .owner = "w1", .any_key = &.{}, .keyed_only = &.{"send"}, .max = 5, .lease = .fromSeconds(60), .tag = fixture.tag };
    const some = try f.store.claim(io, fixture.no_deadline, &request, f.call());
    try testing.expectEqual(@as(usize, 1), some.claimed.len);
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(1500)), some.next_in);
    try fixture.expectDoc(bson.literal(.{ .@"0" = .{ .job = .{ .@"$in" = .{"send"} }, .key = .{ .@"$ne" = "" } } }), try fixture.docAt((try f.entry(0)).body, "query.$or"));
    const pipeline = try fixture.docAt((try f.entry(2)).body, "pipeline");
    try fixture.expectDoc(bson.literal(.{
        .@"0" = .{ .@"$match" = .{ .@"$or" = .{.{ .job = .{ .@"$in" = .{"send"} }, .key = .{ .@"$ne" = "" } }}, .wake_at = .{ .@"$exists" = true } } },
        .@"1" = .{ .@"$sort" = .{ .wake_at = 1 } },
        .@"2" = .{ .@"$limit" = 1 },
        .@"3" = .{ .@"$project" = .{ ._id = 0, .in_ms = .{ .@"$subtract" = .{ "$wake_at", "$$NOW" } }, .now = "$$NOW" } },
    }), pipeline);
    // The aggregation's now set the clock: an hour ahead.
    const ahead = f.store.now(io).unix_ms - Clock.local(io).unix_ms;
    try testing.expect(ahead >= 3_600_000 - 5_000 and ahead <= 3_600_000 + 5_000);

    // Nothing due and nothing to come: null.
    request.max = 1;
    const none = try f.store.claim(io, fixture.no_deadline, &request, f.call());
    try testing.expectEqual(@as(usize, 0), none.claimed.len);
    try testing.expectEqual(@as(?std.Io.Duration, null), none.next_in);
    try f.expectCommands(&.{ "findAndModify", "findAndModify", "aggregate", "findAndModify", "aggregate" });
    // No jobs at all: no I/O.
    const nothing = try f.store.claim(io, fixture.no_deadline, &.{ .owner = "w1", .any_key = &.{}, .keyed_only = &.{}, .max = 1, .lease = .fromSeconds(1), .tag = fixture.tag }, f.call());
    try testing.expectEqual(@as(usize, 0), nothing.claimed.len);
    try testing.expectEqual(@as(usize, 5), f.served.script.received(io));
}

/// A renew of the claim of "send/k1" by "w1" with fence 1.
const renewal: Store.RenewRequest = .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .lease = .fromSeconds(60) };

test "renew matches the claim and reads the server's time" {
    var f: Fixture = .{};
    const a = f.a();
    var b: bson.Builder = .init(a);
    try b.putString("_id", "send/k1");
    // The server's clock is an hour behind.
    try b.putDateTime("lease_until", .{ .milliseconds = Clock.local(io).unix_ms - 3_600_000 + 60_000 });
    const renewed = (try b.finish()).raw();
    const of_life = bson.literal(.{ ._id = "send/k1", .life = fixture.life_hex });
    const of_other = bson.literal(.{ ._id = "send/k1", .life = "00000000000000000000000000000000" });
    try f.start(&.{
        .{ .reply = try fixture.modified(a, renewed) },
        .{ .reply = try fixture.modified(a, null) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{of_life}) },
        .{ .reply = try fixture.modified(a, null) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{of_other}) },
        .{ .reply = try fixture.modified(a, null) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
    });
    defer f.stop();
    try testing.expectEqual(Store.RenewResult.renewed, try f.store.renew(io, fixture.no_deadline, &renewal, f.call()));
    const behind = Clock.local(io).unix_ms - f.store.now(io).unix_ms;
    try testing.expect(behind >= 3_600_000 - 5_000 and behind <= 3_600_000 + 5_000);
    try fixture.expectDoc(bson.literal(.{
        .findAndModify = "scheduler_jobs",
        .query = .{ ._id = "send/k1", .life = fixture.life_hex, .owner = "w1", .fence = @as(i64, 1), .state = "running" },
        .update = .{.{ .@"$set" = .{ .lease_until = .{ .@"$add" = .{ "$$NOW", @as(i64, 60_000) } }, .wake_at = .{ .@"$add" = .{ "$$NOW", @as(i64, 60_000) } } } }},
        .new = true,
        .fields = .{ .lease_until = 1 },
        .writeConcern = .{ .w = 1, .j = true },
        .@"$db" = "app",
    }), (try f.entry(0)).body);
    // Not renewed: the same life is another claim's; another life or none
    // is a removed record.
    try testing.expectEqual(Store.RenewResult.lost, try f.store.renew(io, fixture.no_deadline, &renewal, f.call()));
    try fixture.expectDoc(bson.literal(.{ .life = 1 }), try fixture.docAt((try f.entry(2)).body, "projection"));
    try testing.expectEqual(Store.RenewResult.removed, try f.store.renew(io, fixture.no_deadline, &renewal, f.call()));
    try testing.expectEqual(Store.RenewResult.removed, try f.store.renew(io, fixture.no_deadline, &renewal, f.call()));
    try f.expectCommands(&.{ "findAndModify", "findAndModify", "find", "findAndModify", "find", "findAndModify", "find" });
}

/// A finish of the claim of "send/k1" by "w1", fence 1, revision 0.
fn finishOf(next: Store.Next) Store.FinishRequest {
    return .{ .ref = .{ .job = "send", .key = "k1" }, .life = fixture.life, .owner = "w1", .fence = 1, .revision = 0, .tag = fixture.tag, .next = next, .last = null };
}

test "finish writes the rows first, then the transition on the whole claim" {
    var f: Fixture = .{};
    const a = f.a();
    const upserted = bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "x" }}, .ok = 1.0 });
    const changed = try fixture.pendingDoc(a, "send", "k1", fixture.life_hex, .{});
    const moved = try runningDoc(a, "k1", "t", false);
    // The same claim at revision 2: a change of the client came first.
    const revision_at = std.mem.find(u8, moved.bytes, "revision").? + "revision".len + 1;
    @constCast(moved.bytes)[revision_at] = 2;
    try f.start(&.{
        .{ .reply = upserted },                                             .{ .reply = upserted },
        .{ .reply = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }) }, .{ .reply = bson.literal(.{ .n = 0, .nModified = 0, .ok = 1.0 }) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{moved}) },             .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) },
        .{ .reply = bson.literal(.{ .n = 0, .ok = 1.0 }) },                 .{ .reply = try fixture.found(a, jobs_ns, &.{changed}) },
    });
    defer f.stop();
    const at: scheduler.Instant = .fromUnixMs(at_ms);
    const own: scheduler.Run = .{ .job = "send", .key = "k1", .tenant = "acme", .life = fixture.life, .fence = 1, .attempt = 1, .scheduled_at = at, .started_at = at, .finished_at = at, .outcome = .failed, .error_name = "Declined", .instance = "w1", .expires_at = null };
    var abandoned = own;
    abandoned.fence = 0;
    abandoned.outcome = .abandoned;
    abandoned.error_name = null;
    abandoned.tenant = null;
    var request = finishOf(.{ .wait = .{ .state = .pending, .run_at = .{ .after = .fromSeconds(10) }, .scheduled_at = at, .attempt = 1 } });
    request.last = .{ .outcome = .failed, .error_name = "Declined", .attempt = 1, .started_at = at, .finished_at = at };
    const rows_in = [_]scheduler.Run{ abandoned, own };
    request.history = .{ .runs = &rows_in, .keep = .{ .keep_for = .fromSeconds(3600) } };
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &request, f.call()));

    // The rows: "<life>/<fence>", the abandoned one only where none is,
    // the owner's over an abandoned one too.
    const missing = .{ .@"$eq" = .{ .{ .@"$type" = "$job" }, "missing" } };
    const kept = .{ .@"$add" = .{ "$$NOW", @as(i64, 3_600_000) } };
    const date = bson.DateTime{ .milliseconds = at_ms };
    const rows = [_]bson.RawDocument{ try fixture.item(try f.entry(0), "updates"), try fixture.item(try f.entry(1), "updates") };
    try fixture.expectDoc(bson.literal(.{ .update = "scheduler_runs", .writeConcern = .{ .w = 1, .j = true }, .ordered = true, .@"$db" = "app" }), (try f.entry(0)).body);
    try fixture.expectDoc(bson.literal(.{ .q = .{ ._id = fixture.life_hex ++ "/0" }, .u = .{.{ .@"$replaceWith" = .{ .@"$cond" = .{ missing, .{
        ._id = "$_id",
        .job = .{ .@"$literal" = "send" },
        .key = .{ .@"$literal" = "k1" },
        .life = fixture.life_hex,
        .fence = @as(i64, 0),
        .attempt = 1,
        .scheduled_at = date,
        .started_at = date,
        .finished_at = "$$NOW",
        .outcome = "abandoned",
        .instance = .{ .@"$literal" = "w1" },
        .expires_at = kept,
    }, "$$ROOT" } } }}, .upsert = true }), rows[0]);
    try fixture.expectDoc(bson.literal(.{ .@"$or" = .{ missing, .{ .@"$eq" = .{ "$outcome", "abandoned" } } } }), try fixture.docAt(rows[1], "u.0.$replaceWith.$cond.0"));
    try fixture.expectDoc(bson.literal(.{
        ._id = "$_id",
        .job = .{ .@"$literal" = "send" },
        .key = .{ .@"$literal" = "k1" },
        .tenant = .{ .@"$literal" = "acme" },
        .life = fixture.life_hex,
        .fence = @as(i64, 1),
        .attempt = 1,
        .scheduled_at = date,
        .started_at = date,
        .finished_at = "$$NOW",
        .outcome = "failed",
        .@"error" = .{ .@"$literal" = "Declined" },
        .instance = .{ .@"$literal" = "w1" },
        .expires_at = kept,
    }), try fixture.docAt(rows[1], "u.0.$replaceWith.$cond.1"));

    // The transition on the whole claim: its tag, last, the new state and
    // wake_at; the claim's fields go.
    const transition = try fixture.item(try f.entry(2), "updates");
    try fixture.expectDoc(bson.literal(.{ ._id = "send/k1", .life = fixture.life_hex, .owner = "w1", .fence = @as(i64, 1), .revision = @as(i64, 0), .state = "running" }), try fixture.docAt(transition, "q"));
    const later = .{ .@"$add" = .{ "$$NOW", @as(i64, 10_000) } };
    try fixture.expectDoc(bson.literal(.{
        .@"0" = .{ .@"$set" = .{
            .tag = fixture.tag_hex,
            .last = .{ .@"$mergeObjects" = .{.{ .outcome = "failed", .@"error" = .{ .@"$literal" = "Declined" }, .attempt = 1, .started_at = date, .finished_at = "$$NOW" }} },
            .state = "pending",
            .run_at = later,
            .scheduled_at = date,
            .attempt = 1,
            .wake_at = later,
        } },
        .@"1" = .{ .@"$unset" = .{ "owner", "claimed_at", "lease_until", "prev", "pause_requested", "unreadable_since" } },
    }), try fixture.docAt(transition, "u"));

    // Not applied: the same claim at another revision is changed; done
    // kept always drops expires_at.
    switch (try f.store.finish(io, fixture.no_deadline, &finishOf(.{ .done = .{ .state = .failed, .keep = .forever } }), f.call())) {
        .changed => |now| try testing.expectEqual(@as(u64, 2), now.revision),
        else => return error.TestUnexpectedResult,
    }
    try fixture.expectDoc(bson.literal(.{
        .@"0" = .{ .@"$set" = .{ .tag = fixture.tag_hex, .state = "failed", .finished_at = "$$NOW" } },
        .@"1" = .{ .@"$unset" = .{ "owner", "claimed_at", "lease_until", "prev", "pause_requested", "expires_at", "run_at", "unreadable_since", "wake_at" } },
    }), try fixture.docAt(try fixture.item(try f.entry(3), "updates"), "u"));
    // delete: a deleteOne on the same condition; nothing deleted and the
    // record is no longer this claim's: lost.
    try testing.expectEqual(Store.FinishResult.done, try f.store.finish(io, fixture.no_deadline, &finishOf(.delete), f.call()));
    const deletion = try fixture.item(try f.entry(5), "deletes");
    try fixture.expectDoc(try fixture.docAt(transition, "q"), try fixture.docAt(deletion, "q"));
    try testing.expectEqual(Store.FinishResult.lost, try f.store.finish(io, fixture.no_deadline, &finishOf(.delete), f.call()));
    try f.expectCommands(&.{ "update", "update", "update", "update", "find", "delete", "delete", "find" });
    // A next that no record takes, before any I/O.
    try testing.expectError(error.InvalidArgument, f.store.finish(io, fixture.no_deadline, &finishOf(.{ .done = .{ .state = .succeeded, .keep = .none } }), f.call()));
    try testing.expectError(error.InvalidArgument, f.store.finish(io, fixture.no_deadline, &finishOf(.{ .wait = .{ .state = .running, .run_at = .{ .after = .zero }, .scheduled_at = null, .attempt = 0 } }), f.call()));
}

test "a SchedulerStore is a scheduler.Store" {
    var f: Fixture = .{};
    try f.start(&.{});
    defer f.stop();
    const s = f.store.store();
    try testing.expectEqualStrings("mongodb", s.vtable.name);
    _ = s.now(io);
}
