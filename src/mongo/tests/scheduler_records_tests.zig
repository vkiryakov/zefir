//! Tests of the records of `mongo.SchedulerStore` against
//! `mongo.testing.FakeServer`: the commands that create, get, update,
//! remove, list and history send, as the script's journal holds them, and
//! what the store makes of the replies.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const fixture = @import("scheduler_fixture.zig");
const Fixture = fixture.Fixture;
const Store = scheduler.Store;

const io = testing.io;
const trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
const at_ms = 1_793_018_096_789;
const at = bson.DateTime{ .milliseconds = at_ms };

const upserted = bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "send-invoice/order-42" }}, .ok = 1.0 });
const replaced = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 });
const untouched = bson.literal(.{ .n = 1, .nModified = 0, .ok = 1.0 });
const missed = bson.literal(.{ .n = 0, .nModified = 0, .ok = 1.0 });

test "create is one upsert with a pipeline" {
    var f: Fixture = .{};
    try f.start(&.{ .{ .reply = upserted }, .{ .reply = replaced }, .{ .reply = untouched } });
    defer f.stop();
    var request: Store.CreateRequest = .{ .job = "send-invoice", .key = "order-42", .tenant = "acme", .life = fixture.life, .plan = "", .payload = "{\"order_id\":42}", .trace = trace, .run_at = .{ .at = .fromUnixMs(at_ms) } };
    try testing.expectEqual(Store.CreateResult.created, try f.store.create(io, fixture.no_deadline, &request, f.call()));
    request.tenant = null;
    request.trace = null;
    request.run_at = .{ .after = .fromSeconds(60) };
    try testing.expectEqual(Store.CreateResult.replaced, try f.store.create(io, fixture.no_deadline, &request, f.call()));
    try testing.expectEqual(Store.CreateResult.existing, try f.store.create(io, fixture.no_deadline, &request, f.call()));
    try f.expectCommands(&.{ "update", "update", "update" });

    const first = try f.entry(0);
    try fixture.expectDoc(bson.literal(.{ .update = "scheduler_jobs", .writeConcern = .{ .w = 1, .j = true }, .ordered = true, .@"$db" = "app" }), first.body);
    // A new record when there is none or a finished one; a live one stays.
    const record = .{
        ._id = "$_id",
        .job = .{ .@"$literal" = "send-invoice" },
        .key = .{ .@"$literal" = "order-42" },
        .tenant = .{ .@"$literal" = "acme" },
        .life = fixture.life_hex,
        .plan = .{ .@"$literal" = "" },
        .payload = .{ .@"$literal" = "{\"order_id\":42}" },
        .trace = .{ .@"$literal" = trace },
        .state = "pending",
        .scheduled_at = at,
        .run_at = at,
        .wake_at = at,
        .attempt = 0,
        .fence = @as(i64, 0),
        .revision = @as(i64, 0),
        .created_at = "$$NOW",
        .updated_at = "$$NOW",
    };
    const vacant = .{ .@"$or" = .{
        .{ .@"$eq" = .{ .{ .@"$type" = "$job" }, "missing" } },
        .{ .@"$in" = .{ "$state", .{ "succeeded", "failed" } } },
    } };
    try fixture.expectDoc(bson.literal(.{
        .q = .{ ._id = "send-invoice/order-42" },
        .u = .{.{ .@"$replaceWith" = .{ .@"$cond" = .{ vacant, record, "$$ROOT" } } }},
        .upsert = true,
    }), try fixture.item(first, "updates"));
    // .after: the server's now and the delay; no tenant, no trace.
    const later = .{ .@"$add" = .{ "$$NOW", @as(i64, 60_000) } };
    try fixture.expectDoc(bson.literal(.{ .@"$replaceWith" = .{ .@"$cond" = .{ vacant, .{
        ._id = "$_id",
        .job = .{ .@"$literal" = "send-invoice" },
        .key = .{ .@"$literal" = "order-42" },
        .life = fixture.life_hex,
        .plan = .{ .@"$literal" = "" },
        .payload = .{ .@"$literal" = "{\"order_id\":42}" },
        .state = "pending",
        .scheduled_at = later,
        .run_at = later,
        .wake_at = later,
        .attempt = 0,
        .fence = @as(i64, 0),
        .revision = @as(i64, 0),
        .created_at = "$$NOW",
        .updated_at = "$$NOW",
    }, "$$ROOT" } } }), try fixture.docAt(try fixture.item(try f.entry(1), "updates"), "u.0"));

    // Names that break the rules go nowhere.
    request.job = "send/invoice";
    try testing.expectError(error.InvalidArgument, f.store.create(io, fixture.no_deadline, &request, f.call()));
    request.job = "send-invoice";
    request.tenant = "";
    try testing.expectError(error.InvalidArgument, f.store.create(io, fixture.no_deadline, &request, f.call()));
    request.tenant = null;
    request.payload = "{\"note\":\"\xff\"}";
    try testing.expectError(error.InvalidArgument, f.store.create(io, fixture.no_deadline, &request, f.call()));
    try testing.expectEqualStrings("create: a string of the request is not UTF-8", f.diagnostics.message());
    try testing.expectEqual(@as(usize, 3), f.served.script.received(io));
}

/// An update of the record "send-invoice/order-42" at revision 3 in
/// `state`, with the tag of the fixture.
fn updateOf(state: scheduler.State, set: Store.Patch) Store.UpdateRequest {
    return .{ .ref = .{ .job = "send-invoice", .key = "order-42" }, .expect = .{ .revision = 3, .state = state }, .set = set, .tag = fixture.tag };
}

test "update matches revision and state and sets wake_at by the state after it" {
    var f: Fixture = .{};
    const conflicting = try fixture.pendingDoc(f.a(), "send-invoice", "order-42", fixture.life_hex, .{ .tag = "elsewhere" });
    try f.start(&.{
        .{ .reply = replaced }, .{ .reply = replaced },
        .{ .reply = replaced }, .{ .reply = replaced },
        .{ .reply = missed },   .{ .reply = try fixture.found(f.a(), "app.scheduler_jobs", &.{conflicting}) },
        .{ .reply = missed },   .{ .reply = try fixture.found(f.a(), "app.scheduler_jobs", &.{}) },
    });
    defer f.stop();
    const head = .{ .revision = .{ .@"$add" = .{ "$revision", @as(i64, 1) } }, .tag = fixture.tag_hex, .updated_at = "$$NOW" };

    // A pause: the record is out of the index of claims.
    try testing.expectEqual(Store.UpdateResult{ .updated = 4 }, try f.store.update(io, fixture.no_deadline, &updateOf(.pending, .{ .state = .paused }), f.call()));
    const paused = try fixture.item(try f.entry(0), "updates");
    try fixture.expectDoc(bson.literal(.{ ._id = "send-invoice/order-42", .revision = @as(i64, 3), .state = "pending" }), try fixture.docAt(paused, "q"));
    try fixture.expectDoc(bson.literal(.{ .@"$set" = .{
        .revision = head.revision,
        .tag = head.tag,
        .updated_at = head.updated_at,
        .state = "paused",
        .wake_at = "$$REMOVE",
    } }), try fixture.docAt(paused, "u.0"));

    // An unpause: claimable again from the run_at it kept.
    _ = try f.store.update(io, fixture.no_deadline, &updateOf(.paused, .{ .state = .pending, .plan = "every 60s", .pause_requested = true }), f.call());
    try fixture.expectDoc(bson.literal(.{ .@"$set" = .{
        .revision = head.revision,
        .tag = head.tag,
        .updated_at = head.updated_at,
        .state = "pending",
        .plan = .{ .@"$literal" = "every 60s" },
        .pause_requested = .{ .@"$literal" = true },
        .wake_at = "$run_at",
    } }), try fixture.docAt(try fixture.item(try f.entry(1), "updates"), "u.0"));

    // A retry of a failed record: due now, attempt 0, scheduled_at kept.
    _ = try f.store.update(io, fixture.no_deadline, &updateOf(.failed, .{ .reset = true, .pause_requested = false }), f.call());
    try fixture.expectDoc(bson.literal(.{ .@"$set" = .{
        .revision = head.revision,
        .tag = head.tag,
        .updated_at = head.updated_at,
        .state = "pending",
        .pause_requested = "$$REMOVE",
        .run_at = "$$NOW",
        .attempt = 0,
        .unreadable_since = "$$REMOVE",
        .finished_at = "$$REMOVE",
        .expires_at = "$$REMOVE",
        .wake_at = "$$NOW",
    } }), try fixture.docAt(try fixture.item(try f.entry(2), "updates"), "u.0"));

    // A move of a running record: a new scheduled_at, and no run_at or
    // wake_at, which its lease holds.
    _ = try f.store.update(io, fixture.no_deadline, &updateOf(.running, .{ .run_at = .{ .at = .fromUnixMs(at_ms) } }), f.call());
    try fixture.expectDoc(bson.literal(.{ .@"$set" = .{
        .revision = head.revision,
        .tag = head.tag,
        .updated_at = head.updated_at,
        .scheduled_at = at,
        .attempt = 0,
    } }), try fixture.docAt(try fixture.item(try f.entry(3), "updates"), "u.0"));

    // Nothing matched: the record as it is now, or none.
    switch (try f.store.update(io, fixture.no_deadline, &updateOf(.pending, .{ .state = .paused }), f.call())) {
        .conflict => |now| {
            try testing.expectEqualStrings("order-42", now.key);
            try testing.expectEqual(@as(u64, 0), now.revision);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Store.UpdateResult.not_found, try f.store.update(io, fixture.no_deadline, &updateOf(.pending, .{ .state = .paused }), f.call()));
    try f.expectCommands(&.{ "update", "update", "update", "update", "update", "find", "update", "find" });

    // Patches that break the rules, before any I/O.
    const refused = [_]Store.UpdateRequest{
        updateOf(.pending, .{ .state = .running }),
        updateOf(.running, .{ .state = .paused }),
        updateOf(.succeeded, .{ .state = .pending }),
        updateOf(.failed, .{ .run_at = .{ .after = .zero } }),
    };
    for (refused) |request| try testing.expectError(error.InvalidArgument, f.store.update(io, fixture.no_deadline, &request, f.call()));
    try testing.expectEqualStrings("update: a finished record has no run_at: make it pending or paused too", f.diagnostics.message());
    try testing.expectEqual(@as(usize, 8), f.served.script.received(io));
}

test "get, remove, list and history" {
    var f: Fixture = .{};
    const a = f.a();
    const jobs_ns = "app.scheduler_jobs";
    const k1 = try fixture.pendingDoc(a, "send", "k1", fixture.life_hex, .{});
    const k2 = try fixture.pendingDoc(a, "send", "k2", fixture.life_hex, .{ .tenant = "acme" });
    const row = bson.literal(.{
        ._id = fixture.life_hex ++ "/3",
        .job = "send",
        .key = "k1",
        .life = fixture.life_hex,
        .fence = @as(i64, 3),
        .attempt = 2,
        .scheduled_at = at,
        .started_at = at,
        .finished_at = bson.DateTime{ .milliseconds = at_ms + 500 },
        .outcome = "abandoned",
        .instance = "shop/1",
    });
    try f.start(&.{
        .{ .reply = try fixture.found(a, jobs_ns, &.{k1}) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) },
        .{ .reply = bson.literal(.{ .n = 0, .ok = 1.0 }) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{ k1, k2 }) },
        .{ .reply = try fixture.found(a, jobs_ns, &.{}) },
        .{ .reply = try fixture.found(a, "app.scheduler_runs", &.{row}) },
        .{ .reply = try fixture.found(a, "app.scheduler_runs", &.{}) },
    });
    defer f.stop();

    const got = (try f.store.get(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call())) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("k1", got.key);
    try testing.expectEqual(@as(?scheduler.Record, null), try f.store.get(io, fixture.no_deadline, &.{ .job = "send", .key = "k9" }, f.call()));
    try fixture.expectDoc(bson.literal(.{ .find = "scheduler_jobs", .filter = .{ ._id = "send/k1" }, .limit = 1, .singleBatch = true, .@"$db" = "app" }), (try f.entry(0)).body);
    // A job name that breaks its rule names no record: no I/O.
    try testing.expectEqual(@as(?scheduler.Record, null), try f.store.get(io, fixture.no_deadline, &.{ .job = "send/k1", .key = "" }, f.call()));

    try testing.expect(try f.store.remove(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call()));
    try testing.expect(!try f.store.remove(io, fixture.no_deadline, &.{ .job = "send", .key = "k1" }, f.call()));
    const removal = try f.entry(2);
    try fixture.expectDoc(bson.literal(.{ .delete = "scheduler_jobs", .writeConcern = .{ .w = 1, .j = true }, .ordered = true, .@"$db" = "app" }), removal.body);
    try fixture.expectDoc(bson.literal(.{ .q = .{ ._id = "send/k1" }, .limit = 1 }), try fixture.item(removal, "deletes"));

    // A full page of a job by _id, then the page after its last _id.
    const page = try f.store.list(io, fixture.no_deadline, &.{ .filter = .{ .job = "send", .state = .pending }, .page = .{ .limit = 2 } }, f.call());
    try testing.expectEqual(@as(usize, 2), page.records.len);
    try testing.expectEqualStrings("k2", page.records[1].key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), page.records[1].tenant);
    try testing.expectEqualDeep(@as(?[]const u8, "send/k2"), page.next);
    try fixture.expectDoc(bson.literal(.{
        .find = "scheduler_jobs",
        .filter = .{ ._id = .{ .@"$gte" = "send/", .@"$lt" = "send0" }, .state = "pending" },
        .sort = .{ ._id = 1 },
        .limit = 2,
        .@"$db" = "app",
    }), (try f.entry(4)).body);
    const rest = try f.store.list(io, fixture.no_deadline, &.{ .filter = .{ .tenant = "acme" }, .page = .{ .after = page.next, .limit = 2 } }, f.call());
    try testing.expectEqual(@as(usize, 0), rest.records.len);
    try testing.expectEqual(@as(?[]const u8, null), rest.next);
    try fixture.expectDoc(bson.literal(.{ ._id = .{ .@"$gt" = "send/k2" }, .tenant = "acme" }), try fixture.docAt((try f.entry(5)).body, "filter"));

    // History: the newest first, by finished_at and _id.
    const rows = try f.store.history(io, fixture.no_deadline, &.{ .filter = .{ .job = "send", .key = "k1", .outcome = .abandoned }, .page = .{ .limit = 1 } }, f.call());
    try testing.expectEqual(@as(usize, 1), rows.runs.len);
    try testing.expectEqual(scheduler.RunOutcome.abandoned, rows.runs[0].outcome);
    try testing.expectEqual(@as(u64, 3), rows.runs[0].fence);
    try testing.expectEqualStrings("shop/1", rows.runs[0].instance);
    try testing.expectEqualDeep(@as(?[]const u8, "1793018097289/" ++ fixture.life_hex ++ "/3"), rows.next);
    try fixture.expectDoc(bson.literal(.{
        .find = "scheduler_runs",
        .filter = .{ .job = "send", .key = "k1", .outcome = "abandoned" },
        .sort = .{ .finished_at = -1, ._id = -1 },
        .limit = 1,
        .@"$db" = "app",
    }), (try f.entry(6)).body);
    const older = try f.store.history(io, fixture.no_deadline, &.{ .filter = .{ .tenant = "acme" }, .page = .{ .after = rows.next, .limit = 1 } }, f.call());
    try testing.expectEqual(@as(usize, 0), older.runs.len);
    try fixture.expectDoc(bson.literal(.{ .tenant = "acme", .@"$or" = .{
        .{ .finished_at = .{ .@"$lt" = bson.DateTime{ .milliseconds = at_ms + 500 } } },
        .{ .finished_at = bson.DateTime{ .milliseconds = at_ms + 500 }, ._id = .{ .@"$lt" = fixture.life_hex ++ "/3" } },
    } }), try fixture.docAt((try f.entry(7)).body, "filter"));
    try testing.expectError(error.InvalidArgument, f.store.history(io, fixture.no_deadline, &.{ .filter = .{}, .page = .{ .after = "no-slash" } }, f.call()));
    try testing.expectError(error.InvalidArgument, f.store.list(io, fixture.no_deadline, &.{ .filter = .{}, .page = .{ .limit = 0 } }, f.call()));
    try testing.expectEqual(@as(usize, 8), f.served.script.received(io));
}

test "keys and tenants that look like operators stay strings" {
    var f: Fixture = .{};
    try f.start(&.{ .{ .reply = upserted }, .{ .reply = try fixture.found(f.a(), "app.scheduler_jobs", &.{}) } });
    defer f.stop();
    const request: Store.CreateRequest = .{ .job = "send", .key = "$set", .tenant = "$where", .life = fixture.life, .plan = "$$NOW", .payload = "{\"$set\":{\"a.b\":1}}", .trace = "a.b", .run_at = .{ .at = .fromUnixMs(at_ms) } };
    _ = try f.store.create(io, fixture.no_deadline, &request, f.call());
    const record = try fixture.docAt(try fixture.item(try f.entry(0), "updates"), "u.0.$replaceWith.$cond.1");
    for ([_][2][]const u8{ .{ "key", "$set" }, .{ "tenant", "$where" }, .{ "plan", "$$NOW" }, .{ "payload", "{\"$set\":{\"a.b\":1}}" }, .{ "trace", "a.b" } }) |pair| {
        var b: bson.Builder = .init(f.a());
        try b.putString("$literal", pair[1]);
        try fixture.expectDoc((try b.finish()).raw(), try fixture.docAt(record, pair[0]));
    }
    // In a filter, a string is a value as it is.
    _ = try f.store.get(io, fixture.no_deadline, &.{ .job = "send", .key = "{\"$gt\":1}" }, f.call());
    try fixture.expectDoc(bson.literal(.{ ._id = "send/{\"$gt\":1}" }), try fixture.docAt((try f.entry(1)).body, "filter"));
}
