//! Tests of `mongo.SchedulerStore` against `mongo.testing.FakeServer`: its
//! settings, its indexes and the clock of the server, and how a document
//! of the collection of jobs reads back as a record.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const Script = mongo.testing.Script;
const SchedulerStore = mongo.SchedulerStore;
const documents = @import("../scheduler/documents.zig");
const fixture = @import("scheduler_fixture.zig");
const Fixture = fixture.Fixture;

test "init checks and copies the names and does no I/O" {
    const io = testing.io;
    // A client that never connects: init does no I/O.
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = "mongodb://127.0.0.1:1" });
    defer client.deinit();
    var names = "shop.jobs.runs".*;
    var store: SchedulerStore = try .init(testing.allocator, io, &client, .{ .database = names[0..4], .jobs = names[5..9], .runs = names[10..] });
    defer store.deinit();
    @memset(&names, 'x');
    try testing.expectEqualStrings("shop", store.database);
    try testing.expectEqualStrings("jobs", store.jobs);
    try testing.expectEqualStrings("runs", store.runs);
    try testing.expectEqual(mongo.WriteConcern{ .w = .one, .journal = true }, store.write_concern);

    var defaults: SchedulerStore = try .init(testing.allocator, io, &client, .{ .database = "shop" });
    defer defaults.deinit();
    try testing.expectEqualStrings("scheduler_jobs", defaults.jobs);
    try testing.expectEqualStrings("scheduler_runs", defaults.runs);

    const refused = [_]struct { options: SchedulerStore.Options, text: []const u8 }{
        .{ .options = .{ .database = "" }, .text = "SchedulerStore: a database name is 1 to 63 bytes long; this one is 0" },
        .{ .options = .{ .database = &@as([64]u8, @splat('a')) }, .text = "SchedulerStore: a database name is 1 to 63 bytes long; this one is 64" },
        .{ .options = .{ .database = "shop.eu" }, .text = "SchedulerStore: a database name holds none of / \\ . \" $, a space or NUL" },
        .{ .options = .{ .database = "shop", .jobs = "" }, .text = "SchedulerStore: the collection of jobs has an empty name" },
        .{ .options = .{ .database = "shop", .runs = "runs$" }, .text = "SchedulerStore: the name of the collection of runs holds a '$' or a NUL" },
        .{ .options = .{ .database = "shop", .runs = "j\xff" }, .text = "SchedulerStore: the name of the collection of runs is not UTF-8" },
        .{ .options = .{ .database = "shop", .jobs = "same", .runs = "same" }, .text = "SchedulerStore: jobs and runs are two collections, and both are named 'same'" },
    };
    for (refused) |case| {
        var d: mongo.Diagnostics = .{};
        var options = case.options;
        options.diagnostics = &d;
        try testing.expectError(error.InvalidArgument, SchedulerStore.init(testing.allocator, io, &client, options));
        try testing.expectEqualStrings(case.text, d.message());
    }
    // Nothing went out: the client never connected.
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
}

test "ensureIndexes creates the indexes and measures the server's clock" {
    const io = testing.io;
    var f: Fixture = .{};
    // The server's clock is an hour ahead of the process's.
    const ahead: i64 = 3_600_000;
    const server_now = SchedulerStoreClock.local(io).unix_ms + ahead;
    var b: bson.Builder = .init(f.a());
    try b.putDateTime("now", .{ .milliseconds = server_now });
    const measured = try fixture.found(f.a(), "app.$cmd.aggregate", &.{(try b.finish()).raw()});
    const created = bson.literal(.{ .numIndexesBefore = 1, .numIndexesAfter = 4, .createdCollectionAutomatically = true, .ok = 1.0 });
    try f.start(&.{ .{ .reply = created }, .{ .reply = created }, .{ .reply = measured } });
    defer f.stop();

    try f.store.ensureIndexes(io, fixture.no_deadline);
    try f.expectCommands(&.{ "createIndexes", "createIndexes", "aggregate" });
    try fixture.expectDoc(bson.literal(.{
        .createIndexes = "scheduler_jobs",
        .indexes = .{
            .{ .key = .{ .job = 1, .wake_at = 1 }, .name = "scan", .partialFilterExpression = .{ .wake_at = .{ .@"$exists" = true } } },
            .{ .key = .{ .expires_at = 1 }, .name = "expire", .expireAfterSeconds = 0, .partialFilterExpression = .{ .expires_at = .{ .@"$exists" = true } } },
            .{ .key = .{ .tenant = 1, ._id = 1 }, .name = "tenant", .partialFilterExpression = .{ .tenant = .{ .@"$exists" = true } } },
        },
        .@"$db" = "app",
    }), (try f.entry(0)).body);
    try fixture.expectDoc(bson.literal(.{
        .createIndexes = "scheduler_runs",
        .indexes = .{
            .{ .key = .{ .job = 1, .key = 1, .finished_at = -1, ._id = -1 }, .name = "job_key_finished" },
            .{ .key = .{ .job = 1, .finished_at = -1, ._id = -1 }, .name = "job_finished" },
            .{ .key = .{ .tenant = 1, .finished_at = -1, ._id = -1 }, .name = "tenant_finished", .partialFilterExpression = .{ .tenant = .{ .@"$exists" = true } } },
            .{ .key = .{ .expires_at = 1 }, .name = "expire", .expireAfterSeconds = 0, .partialFilterExpression = .{ .expires_at = .{ .@"$exists" = true } } },
        },
        .@"$db" = "app",
    }), (try f.entry(1)).body);
    try fixture.expectDoc(bson.literal(.{
        .aggregate = 1,
        .pipeline = .{.{ .@"$documents" = .{.{ .now = "$$NOW" }} }},
        .cursor = .{},
        .@"$db" = "app",
    }), (try f.entry(2)).body);

    // now() is the process's clock and the measured offset: an hour
    // ahead, within what the exchange and this test take.
    const local = SchedulerStoreClock.local(io).unix_ms;
    const now = f.store.now(io).unix_ms;
    try testing.expect(now >= local + ahead - 5_000 and now <= local + ahead + 5_000);
}

test "start logs why the indexes failed and returns the error" {
    const io = testing.io;
    var f: Fixture = .{};
    const refusal = try Script.failure(f.a(), .{ .code = 13, .code_name = "Unauthorized", .errmsg = "not authorized on app to execute command" });
    try f.start(&.{.{ .reply = refusal }});
    defer f.stop();
    var d: mongo.Diagnostics = .{};
    f.store.diagnostics = &d;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.CommandFailed, f.store.start(io));
    try testing.expectEqualStrings("not authorized on app to execute command", d.message());
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
}

const SchedulerStoreClock = @import("../scheduler/Clock.zig");

test "a document reads back as the record it was written from" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every field, a fence and a revision beyond 32 bits.
    const raw = bson.literal(.{
        ._id = "send-invoice/order-42",
        .job = "send-invoice",
        .key = "order-42",
        .tenant = "acme",
        .life = fixture.life_hex,
        .plan = "daily 03:30:00",
        .payload = "{\"order_id\":42}",
        .trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        .state = "running",
        .scheduled_at = bson.DateTime{ .milliseconds = 1_793_000_000_000 },
        .wake_at = bson.DateTime{ .milliseconds = 1_793_000_060_000 },
        .attempt = 3,
        .fence = @as(i64, (1 << 31) + 7),
        .revision = @as(i64, 1 << 33),
        .pause_requested = true,
        .owner = "shop/7f3a",
        .tag = fixture.tag_hex ++ "-2",
        .claimed_at = bson.DateTime{ .milliseconds = 1_793_000_001_000 },
        .lease_until = bson.DateTime{ .milliseconds = 1_793_000_061_000 },
        .claim = .{ .attempt = @as(i32, 3), .scheduled_at = bson.DateTime{ .milliseconds = 1_793_000_000_000 } },
        .prev = .{ .owner = "shop/0001", .claimed_at = bson.DateTime{ .milliseconds = 1_792_999_900_000 }, .attempt = @as(i32, 2), .scheduled_at = bson.DateTime{ .milliseconds = 1_792_999_890_000 } },
        .last = .{ .outcome = "failed", .@"error" = "PaymentDeclined", .attempt = 2, .started_at = bson.DateTime{ .milliseconds = 1_792_999_800_000 }, .finished_at = bson.DateTime{ .milliseconds = 1_792_999_850_000 } },
        .unreadable_since = bson.DateTime{ .milliseconds = 1_792_999_700_000 },
        .created_at = bson.DateTime{ .milliseconds = 1_792_000_000_000 },
        .updated_at = bson.DateTime{ .milliseconds = 1_792_500_000_000 },
    });
    var problem: documents.Problem = .{};
    const read = try documents.readRecord(a, raw, &problem);
    const r = read.record;
    try testing.expectEqualStrings("send-invoice", r.job);
    try testing.expectEqualStrings("order-42", r.key);
    try testing.expectEqualDeep(@as(?[]const u8, "acme"), r.tenant);
    try testing.expectEqualSlices(u8, &fixture.life, &r.life);
    try testing.expectEqualStrings("daily 03:30:00", r.plan);
    try testing.expectEqualStrings("{\"order_id\":42}", r.payload);
    try testing.expectEqualDeep(@as(?[]const u8, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"), r.trace);
    try testing.expectEqual(scheduler.State.running, r.state);
    try testing.expectEqual(@as(i64, 1_793_000_000_000), r.scheduled_at.unix_ms);
    try testing.expectEqual(@as(?scheduler.Instant, null), r.run_at);
    try testing.expectEqual(@as(u32, 3), r.attempt);
    try testing.expectEqual(@as(u64, (1 << 31) + 7), r.fence);
    try testing.expectEqual(@as(u64, 1 << 33), r.revision);
    try testing.expect(r.pause_requested);
    try testing.expectEqualDeep(@as(?[]const u8, "shop/7f3a"), r.owner);
    try testing.expectEqual(@as(?scheduler.Instant, .fromUnixMs(1_793_000_001_000)), r.claimed_at);
    try testing.expectEqual(@as(?scheduler.Instant, .fromUnixMs(1_793_000_061_000)), r.lease_until);
    const last = r.last orelse return error.TestUnexpectedResult;
    try testing.expectEqual(scheduler.RunOutcome.failed, last.outcome);
    try testing.expectEqualDeep(@as(?[]const u8, "PaymentDeclined"), last.error_name);
    try testing.expectEqual(@as(u32, 2), last.attempt);
    try testing.expectEqual(@as(i64, 1_792_999_800_000), last.started_at.unix_ms);
    try testing.expectEqual(@as(i64, 1_792_999_850_000), last.finished_at.unix_ms);
    try testing.expectEqual(@as(?scheduler.Instant, .fromUnixMs(1_792_999_700_000)), r.unreadable_since);
    try testing.expectEqual(@as(i64, 1_792_000_000_000), r.created_at.unix_ms);
    try testing.expectEqual(@as(i64, 1_792_500_000_000), r.updated_at.unix_ms);
    try testing.expectEqual(@as(?scheduler.Instant, null), r.finished_at);
    try testing.expectEqual(@as(?scheduler.Instant, null), r.expires_at);
    try testing.expectEqualDeep(@as(?[]const u8, fixture.tag_hex ++ "-2"), read.tag);
    const over = read.took_over orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("shop/0001", over.owner);
    try testing.expectEqual(@as(i64, 1_792_999_900_000), over.claimed_at.unix_ms);
    try testing.expectEqual(@as(u32, 2), over.attempt);
    try testing.expectEqual(@as(i64, 1_792_999_890_000), over.scheduled_at.unix_ms);

    // A copy in one allocation holds the same record.
    const copy = try documents.recordOut(testing.allocator, &r);
    defer testing.allocator.free(@constCast(copy.job.ptr)[0..documents.recordSize(&copy)]);
    try testing.expectEqualStrings(r.payload, copy.payload);
    try testing.expectEqualDeep(@as(?[]const u8, "PaymentDeclined"), copy.last.?.error_name);

    // A finished record without the optional fields reads too.
    const done = try fixture.pendingDoc(a, "j", "", fixture.life_hex, .{ .finished_at = bson.DateTime{ .milliseconds = 5 } });
    const plain = (try documents.readRecord(a, done, &problem)).record;
    try testing.expectEqual(@as(?[]const u8, null), plain.tenant);
    try testing.expectEqual(@as(?[]const u8, null), plain.trace);
    try testing.expect(!plain.pause_requested and plain.last == null and plain.owner == null);
    try testing.expectEqual(@as(?scheduler.Instant, .fromUnixMs(5)), plain.finished_at);
}

test "a document that is no record is Corrupt, and the problem names the field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { doc: bson.RawDocument, text: []const u8 }{
        .{ .doc = try fixture.pendingDoc(a, "j", "k", "not hex", .{}), .text = "field 'life': not 32 hex digits" },
        .{ .doc = bson.literal(.{ .job = "j" }), .text = "field 'key': error.MissingField" },
        .{ .doc = try fixture.pendingDoc(a, "j", "k", fixture.life_hex, .{ .tenant = 7 }), .text = "field 'tenant': error.WrongType" },
    };
    for (cases) |case| {
        var problem: documents.Problem = .{};
        try testing.expectError(error.Corrupt, documents.readRecord(a, case.doc, &problem));
        try testing.expectEqualStrings(case.text, problem.message());
    }
    // An Int64 below 0 and a state that is none.
    var b: bson.Builder = .init(a);
    try b.putString("job", "j");
    try b.putString("key", "k");
    try b.putString("life", fixture.life_hex);
    try b.putString("plan", "");
    try b.putString("payload", "{}");
    try b.putString("state", "pending");
    try b.putDateTime("scheduled_at", .{ .milliseconds = 0 });
    try b.putInt32("attempt", 0);
    try b.putInt64("fence", -1);
    try b.putInt64("revision", 0);
    try b.putDateTime("created_at", .{ .milliseconds = 0 });
    try b.putDateTime("updated_at", .{ .milliseconds = 0 });
    var problem: documents.Problem = .{};
    try testing.expectError(error.Corrupt, documents.readRecord(a, (try b.finish()).raw(), &problem));
    try testing.expectEqualStrings("field 'fence': below 0", problem.message());
    const asleep = try fixture.pendingDoc(a, "j", "k", fixture.life_hex, .{});
    var patched = try a.dupe(u8, asleep.bytes);
    const at = std.mem.find(u8, patched, "pending").?;
    @memcpy(patched[at..][0..7], "pausing");
    try testing.expectError(error.Corrupt, documents.readRecord(a, .{ .bytes = patched }, &problem));
    try testing.expectEqualStrings("field 'state': error.InvalidEnumTag", problem.message());
}
