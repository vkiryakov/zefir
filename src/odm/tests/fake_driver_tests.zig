//! Tests of odm.testing.FakeDriver: its plans, replies, gates, journal and
//! counts.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const FakeDriver = odm.testing.FakeDriver;
const Client = odm.Client;

const ns: Client.Namespace = .{ .database = "app", .collection = "users" };
const ann = bson.literal(.{ .name = "Ann" });
const bob = bson.literal(.{ .name = "Bob" });

/// A client of `uri` that has connected.
fn connected(fake: *FakeDriver, io: Io, uri: []const u8) !Client {
    const client = try fake.driver().open(io, &.{ .uri = uri });
    errdefer release(client, io);
    try client.connect(io, .root, null);
    return client;
}

fn release(client: Client, io: Io) void {
    client.close(io);
    client.deinit();
}

test "without a plan a client connects and its operations give nothing" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const driver = fake.driver();
    try testing.expectEqualStrings("fake", driver.name());

    var d: odm.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, driver.open(io, &.{ .uri = "", .diagnostics = &d }));
    try testing.expectEqualStrings("the uri is empty", d.message());

    const client = try driver.open(io, &.{ .uri = "fake://app", .password = "secret" });
    defer release(client, io);
    try testing.expectEqual(odm.Capabilities{ .aggregate = true, .count = true, .indexes = true, .command = true }, client.capabilities());
    try testing.expectEqual(Client.PoolStats{ .connections = 0, .idle = 0, .in_use = 0, .waiting = 0 }, client.stats().?);

    // Before connect an operation is Unavailable.
    const options: Client.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };
    try testing.expectError(error.Unavailable, client.ping(io, .root, &d));
    try testing.expectEqualStrings("connect has not succeeded", d.message());
    const insert: Client.InsertRequest = .{ .ns = ns, .documents = &.{ann} };
    try testing.expectError(error.Unavailable, client.insert(io, .root, &insert, options));

    try client.connect(io, .root, &d);
    try testing.expectEqualStrings("", d.message());
    try client.connect(io, .root, &d);
    try testing.expectEqual(Client.PoolStats{ .connections = 1, .idle = 0, .in_use = 0, .waiting = 0 }, client.stats().?);
    try client.ping(io, .root, &d);

    try testing.expectEqual(@as(u64, 0), (try client.insert(io, .root, &insert, options)).inserted);
    const updated = try client.update(io, .root, &.{ .ns = ns, .filter = ann, .update = bob, .mode = .replace }, options);
    try testing.expectEqual(@as(u64, 0), updated.matched);
    try testing.expectEqual(@as(u64, 0), updated.modified);
    try testing.expect(updated.upserted_id == null);
    try testing.expectEqual(@as(u64, 0), (try client.delete(io, .root, &.{ .ns = ns, .filter = ann, .many = false }, options)).deleted);
    const found = try client.find(io, .root, &.{ .ns = ns, .filter = ann }, options);
    defer found.deinit(io);
    try testing.expect(try found.next(io, .root, &d) == null);
    const aggregated = try client.aggregate(io, .root, &.{ .ns = ns, .pipeline = &.{} }, options);
    defer aggregated.deinit(io);
    try testing.expect(try aggregated.next(io, .root, &d) == null);
    try testing.expectEqual(@as(u64, 0), try client.count(io, .root, &.{ .ns = ns, .filter = .empty }, options));
    try client.createIndexes(io, .root, &.{ .ns = ns, .indexes = &.{.{ .name = "name_1", .keys = bson.literal(.{ .name = @as(i32, 1) }) }} }, options);
    const reply = try client.command(io, .root, &.{ .database = "app", .body = bson.literal(.{ .ping = @as(i32, 1) }) }, options);
    defer testing.allocator.free(reply.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 1.0 }).bytes, reply.bytes);
}

test "the journal keeps copies of what was sent" {
    const io = testing.io;
    const gpa = testing.allocator;
    var fake: FakeDriver = .init(gpa);
    defer fake.deinit();
    const client = try connected(&fake, io, "fake://app");
    defer release(client, io);

    // The caller's memory, which the fake must not keep.
    const database = try gpa.dupe(u8, "app");
    const collection = try gpa.dupe(u8, "users");
    const first = try gpa.dupe(u8, ann.bytes);
    const second = try gpa.dupe(u8, bob.bytes);
    const keys = try gpa.dupe(u8, bson.literal(.{ .name = @as(i32, 1) }).bytes);
    const index_name = try gpa.dupe(u8, "name_1");
    const documents = try gpa.alloc(bson.RawDocument, 2);
    documents[0] = .{ .bytes = first };
    documents[1] = .{ .bytes = second };
    const specs = try gpa.alloc(Client.IndexSpec, 1);
    specs[0] = .{ .name = index_name, .keys = .{ .bytes = keys }, .unique = true, .sparse = true, .expire_after_seconds = 60 };
    const at: Client.Namespace = .{ .database = database, .collection = collection };
    const options: Client.CallOptions = .{ .allocator = gpa };

    _ = try client.insert(io, .root, &.{ .ns = at, .documents = documents }, options);
    _ = try client.update(io, .root, &.{ .ns = at, .filter = documents[1], .update = documents[0], .mode = .many, .upsert = true }, options);
    _ = try client.delete(io, .root, &.{ .ns = at, .filter = documents[1], .many = true }, options);
    const find: Client.FindRequest = .{ .ns = at, .filter = documents[1], .sort = specs[0].keys, .projection = documents[0], .skip = 2, .limit = 1, .batch_size = 5 };
    (try client.find(io, .root, &find, options)).deinit(io);
    (try client.aggregate(io, .root, &.{ .ns = at, .pipeline = documents, .batch_size = 3 }, options)).deinit(io);
    _ = try client.count(io, .root, &.{ .ns = at, .filter = documents[0] }, options);
    try client.createIndexes(io, .root, &.{ .ns = at, .indexes = specs }, options);
    gpa.free((try client.command(io, .root, &.{ .database = database, .body = documents[1] }, options)).bytes);
    try client.ping(io, .root, null);

    for ([_][]u8{ database, collection, first, second, keys, index_name }) |bytes| {
        @memset(bytes, 0xAA);
        gpa.free(bytes);
    }
    @memset(std.mem.sliceAsBytes(documents), 0xAA);
    gpa.free(documents);
    @memset(std.mem.sliceAsBytes(specs), 0xAA);
    gpa.free(specs);

    const journal = fake.journal(io);
    try testing.expectEqual(@as(usize, 10), journal.len);
    for (journal) |entry| try testing.expectEqualStrings("fake://app", entry.uri);
    try testing.expect(journal[0].call == .connect);
    const insert = journal[1].call.insert;
    try expectNs(insert.ns);
    try testing.expectEqual(@as(usize, 2), insert.documents.len);
    try testing.expectEqualSlices(u8, ann.bytes, insert.documents[0].bytes);
    try testing.expectEqualSlices(u8, bob.bytes, insert.documents[1].bytes);
    const update = journal[2].call.update;
    try expectNs(update.ns);
    try testing.expectEqualSlices(u8, bob.bytes, update.filter.bytes);
    try testing.expectEqualSlices(u8, ann.bytes, update.update.bytes);
    try testing.expectEqual(Client.UpdateMode.many, update.mode);
    try testing.expect(update.upsert);
    const delete = journal[3].call.delete;
    try expectNs(delete.ns);
    try testing.expectEqualSlices(u8, bob.bytes, delete.filter.bytes);
    try testing.expect(delete.many);
    const found = journal[4].call.find;
    try expectNs(found.ns);
    try testing.expectEqualSlices(u8, bob.bytes, found.filter.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{ .name = @as(i32, 1) }).bytes, found.sort.?.bytes);
    try testing.expectEqualSlices(u8, ann.bytes, found.projection.?.bytes);
    try testing.expectEqual(@as(u32, 2), found.skip);
    try testing.expectEqual(@as(u32, 1), found.limit);
    try testing.expectEqual(@as(?u32, 5), found.batch_size);
    const aggregate = journal[5].call.aggregate;
    try expectNs(aggregate.ns);
    try testing.expectEqual(@as(usize, 2), aggregate.pipeline.len);
    try testing.expectEqualSlices(u8, bob.bytes, aggregate.pipeline[1].bytes);
    try testing.expectEqual(@as(?u32, 3), aggregate.batch_size);
    try testing.expectEqualSlices(u8, ann.bytes, journal[6].call.count.filter.bytes);
    const indexes = journal[7].call.create_indexes;
    try expectNs(indexes.ns);
    try testing.expectEqual(@as(usize, 1), indexes.indexes.len);
    try testing.expectEqualStrings("name_1", indexes.indexes[0].name);
    try testing.expectEqualSlices(u8, bson.literal(.{ .name = @as(i32, 1) }).bytes, indexes.indexes[0].keys.bytes);
    try testing.expect(indexes.indexes[0].unique and indexes.indexes[0].sparse);
    try testing.expectEqual(@as(?u32, 60), indexes.indexes[0].expire_after_seconds);
    const command = journal[8].call.command;
    try testing.expectEqualStrings("app", command.database);
    try testing.expectEqualSlices(u8, bob.bytes, command.body.bytes);
    try testing.expect(journal[9].call == .ping);
}

fn expectNs(at: Client.Namespace) !void {
    try testing.expectEqualStrings("app", at.database);
    try testing.expectEqualStrings("users", at.collection);
}

test "connects follow the plan and the last result repeats" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const driver = fake.driver();
    try fake.plan("fake://flaky", .{ .connects = &.{ error.Unavailable, null } });
    try fake.plan("fake://locked", .{ .connects = &.{error.AuthenticationFailed} });
    try fake.plan("fake://refused", .{ .open = error.Unsupported });

    var d: odm.Diagnostics = .{};
    const flaky = try driver.open(io, &.{ .uri = "fake://flaky" });
    defer release(flaky, io);
    try testing.expectError(error.Unavailable, flaky.connect(io, .root, &d));
    try testing.expectEqualStrings("the plan of the fake fails this connect with Unavailable", d.message());
    try testing.expectError(error.Unavailable, flaky.ping(io, .root, null));
    try flaky.connect(io, .root, &d);
    try testing.expectEqualStrings("", d.message());
    try flaky.ping(io, .root, null);

    const locked = try driver.open(io, &.{ .uri = "fake://locked" });
    defer release(locked, io);
    for (0..3) |_| try testing.expectError(error.AuthenticationFailed, locked.connect(io, .root, null));

    try testing.expectError(error.Unsupported, driver.open(io, &.{ .uri = "fake://refused", .diagnostics = &d }));
    try testing.expectEqualStrings("the plan of the fake refuses to open a client: Unsupported", d.message());

    // A new plan replaces the old one, and its connects start over.
    try fake.plan("fake://locked", .{ .connects = &.{ null, error.Unavailable } });
    try locked.connect(io, .root, null);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).connected);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).opened);
}

fn pingTask(client: Client, io: Io) odm.DriverError!void {
    return client.ping(io, .root, null);
}

fn insertTask(client: Client, io: Io) odm.DriverError!u64 {
    const request: Client.InsertRequest = .{ .ns = ns, .documents = &.{ann} };
    return (try client.insert(io, .root, &request, .{ .allocator = testing.allocator })).inserted;
}

fn pingWithin(client: Client, io: Io, budget: Io.Duration) odm.DriverError!void {
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), budget));
    return client.ping(io, ctx, null);
}

test "a gate holds ping and operations until it opens, and close ends them with Closed" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();

    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://held", .{ .gate = &gate });
    try fake.reply("fake://held", .{ .write = .{ .inserted = 1 } });
    const client = try connected(&fake, io, "fake://held");
    defer release(client, io);
    {
        var ping = try io.concurrent(pingTask, .{ client, io });
        defer ping.cancel(io) catch {};
        var insert = try io.concurrent(insertTask, .{ client, io });
        defer _ = insert.cancel(io) catch 0;
        defer gate.open(io);
        try gate.waitFor(io, 2);
        try testing.expectEqual(@as(usize, 2), gate.waiting(io));
        try testing.expectEqual(Client.PoolStats{ .connections = 1, .idle = 0, .in_use = 2, .waiting = 2 }, client.stats().?);
        // Both are in the journal: they went out before the gate held them.
        try testing.expectEqual(@as(usize, 3), fake.journal(io).len);
        gate.open(io);
        try ping.await(io);
        try testing.expectEqual(@as(u64, 1), try insert.await(io));
    }
    try testing.expectEqual(@as(usize, 0), gate.waiting(io));
    try testing.expectEqual(Client.PoolStats{ .connections = 1, .idle = 0, .in_use = 0, .waiting = 0 }, client.stats().?);
    // An open gate holds nothing.
    try client.ping(io, .root, null);

    // At a gate that stays shut, a call ends at its deadline, and at the
    // cancelation of its task.
    var shut: FakeDriver.Gate = .{};
    try fake.plan("fake://held", .{ .gate = &shut });
    try testing.expectError(error.Timeout, pingWithin(client, io, .fromMilliseconds(20)));
    {
        var ping = try io.concurrent(pingTask, .{ client, io });
        defer ping.cancel(io) catch {};
        defer shut.open(io);
        try shut.waitFor(io, 1);
        try testing.expectError(error.Interrupted, ping.cancel(io));
    }

    // close ends the calls of its client at the gate.
    var closing: FakeDriver.Gate = .{};
    try fake.plan("fake://closing", .{ .gate = &closing });
    const doomed = try connected(&fake, io, "fake://closing");
    defer doomed.deinit();
    {
        var ping = try io.concurrent(pingTask, .{ doomed, io });
        defer ping.cancel(io) catch {};
        var insert = try io.concurrent(insertTask, .{ doomed, io });
        defer _ = insert.cancel(io) catch 0;
        defer closing.open(io);
        try closing.waitFor(io, 2);
        doomed.close(io);
        try testing.expectError(error.Closed, ping.await(io));
        try testing.expectError(error.Closed, insert.await(io));
    }
    try testing.expectEqual(@as(usize, 0), closing.waiting(io));
}

fn nextTask(cursor: odm.RawCursor, io: Io) odm.DriverError!?bson.RawDocument {
    return cursor.next(io, .root, null);
}

test "a gate holds the next of a cursor too" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const client = try connected(&fake, io, "fake://held");
    defer release(client, io);
    try fake.reply("fake://held", .{ .documents = &.{ann} });
    const cursor = try client.find(io, .root, &.{ .ns = ns, .filter = .empty }, .{ .allocator = testing.allocator });
    defer cursor.deinit(io);

    // The plan of the uri, looked up at each call, holds it from now on.
    var gate: FakeDriver.Gate = .{};
    try fake.plan("fake://held", .{ .gate = &gate });
    {
        var next = try io.concurrent(nextTask, .{ cursor, io });
        defer _ = next.cancel(io) catch null;
        defer gate.open(io);
        try gate.waitFor(io, 1);
        gate.open(io);
        try testing.expectEqualSlices(u8, ann.bytes, (try next.await(io)).?.bytes);
    }
    // close ends a next at the gate with Closed.
    var shut: FakeDriver.Gate = .{};
    try fake.plan("fake://held", .{ .gate = &shut });
    {
        var next = try io.concurrent(nextTask, .{ cursor, io });
        defer _ = next.cancel(io) catch null;
        defer shut.open(io);
        try shut.waitFor(io, 1);
        client.close(io);
        try testing.expectError(error.Closed, next.await(io));
    }
}

test "a deadline under 1 ms and a cancelled token send nothing" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const client = try fake.driver().open(io, &.{ .uri = "fake://app" });
    defer release(client, io);

    var d: odm.Diagnostics = .{};
    const soon = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromMicroseconds(500)));
    try testing.expectError(error.DeadlineExceeded, client.connect(io, soon, &d));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the call", d.message());
    try client.connect(io, .root, null);

    var token: core.CancellationToken = .init;
    token.cancel();
    const cancelled = core.Context.root.withCancellation(&token);
    const past = core.Context.root.withDeadline(.at(Io.Clock.awake.now(io)));
    const options: Client.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };
    for ([_]core.Context{ soon, past, cancelled }) |ctx| {
        const expected: odm.DriverError = if (ctx.cancellation != null) error.Cancelled else error.DeadlineExceeded;
        try testing.expectError(expected, client.ping(io, ctx, &d));
        try testing.expectError(expected, client.insert(io, ctx, &.{ .ns = ns, .documents = &.{ann} }, options));
        try testing.expectError(expected, client.find(io, ctx, &.{ .ns = ns, .filter = ann }, options));
        try testing.expectError(expected, client.command(io, ctx, &.{ .database = "app", .body = ann }, options));
    }
    try testing.expectEqualStrings("the token was canceled before the call", d.message());
    // Only the connect that went through is in the journal.
    try testing.expectEqual(@as(usize, 1), fake.journal(io).len);

    // A cursor refuses its next under the same rules, and goes on with a
    // new context.
    try fake.reply("fake://app", .{ .documents = &.{ ann, bob } });
    const cursor = try client.find(io, .root, &.{ .ns = ns, .filter = .empty }, options);
    defer cursor.deinit(io);
    try testing.expectError(error.DeadlineExceeded, cursor.next(io, past, &d));
    try testing.expectError(error.Cancelled, cursor.next(io, cancelled, &d));
    try testing.expectEqualSlices(u8, ann.bytes, (try cursor.next(io, .root, &d)).?.bytes);
    try testing.expectEqualSlices(u8, bob.bytes, (try cursor.next(io, .root, &d)).?.bytes);
}

fn connectTask(client: Client, io: Io) odm.DriverError!void {
    return client.connect(io, .root, null);
}

/// Waits until `n` calls of `client` are in flight, 5 s at the most.
fn waitInFlight(io: Io, client: Client, n: usize) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (client.stats().?.in_use < n) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "close ends a connect in its delay with Closed" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    try fake.plan("fake://slow", .{ .connect_delay = .fromSeconds(30) });
    const driver = fake.driver();

    const start = Io.Clock.awake.now(io);
    const client = try driver.open(io, &.{ .uri = "fake://slow" });
    defer client.deinit();
    {
        var task = try io.concurrent(connectTask, .{ client, io });
        defer task.cancel(io) catch {};
        try waitInFlight(io, client, 1);
        client.close(io);
        try testing.expectError(error.Closed, task.await(io));
    }
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds < 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 0), fake.counts(io).connected);

    // The cancelation of its task ends the delay too, and the deadline
    // does; a delay that runs out connects.
    const late = try driver.open(io, &.{ .uri = "fake://slow" });
    defer release(late, io);
    {
        var task = try io.concurrent(connectTask, .{ late, io });
        defer task.cancel(io) catch {};
        try waitInFlight(io, late, 1);
        try testing.expectError(error.Cancelled, task.cancel(io));
    }
    var d: odm.Diagnostics = .{};
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromMilliseconds(30)));
    try testing.expectError(error.DeadlineExceeded, late.connect(io, ctx, &d));
    try testing.expectEqualStrings("the deadline passed while the client connected", d.message());
    try fake.plan("fake://slow", .{ .connect_delay = .fromMilliseconds(10) });
    try late.connect(io, .root, null);
    try late.ping(io, .root, null);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);
}

test "a failure reply sets the diagnostics" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const client = try connected(&fake, io, "fake://app");
    defer release(client, io);

    const errmsg = "E11000 duplicate key error collection: app.users index: email_1 dup key: { email: \"ann@example.com\" }";
    try fake.reply("fake://app", .{ .failure = .{ .err = error.DuplicateKey, .code = 11000, .index = 1, .message = errmsg } });
    try fake.reply("fake://app", .{ .failure = .{ .err = error.CommandFailed, .code = 59 } });
    var d: odm.Diagnostics = .{};
    const options: Client.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };
    try testing.expectError(error.DuplicateKey, client.insert(io, .root, &.{ .ns = ns, .documents = &.{ ann, ann } }, options));
    try testing.expectEqual(@as(?i32, 11000), d.code);
    try testing.expectEqual(@as(?usize, 1), d.index);
    try testing.expectEqualStrings(errmsg, d.message());
    try testing.expectError(error.CommandFailed, client.command(io, .root, &.{ .database = "app", .body = bson.literal(.{ .fnd = "users" }) }, options));
    try testing.expectEqual(@as(?i32, 59), d.code);
    try testing.expectEqual(@as(?usize, null), d.index);
    try testing.expectEqualStrings("", d.message());
    // No reply is left: the next operation gives nothing, and its
    // diagnostics are clean.
    try testing.expectEqual(@as(u64, 0), try client.count(io, .root, &.{ .ns = ns, .filter = ann }, options));
    try testing.expectEqual(@as(?i32, null), d.code);
}

test "replies answer the operations in order, and the results live in the call's allocator" {
    const io = testing.io;
    const gpa = testing.allocator;
    var fake: FakeDriver = .init(gpa);
    defer fake.deinit();
    const client = try connected(&fake, io, "fake://app");
    defer release(client, io);
    const other = try connected(&fake, io, "fake://other");
    defer release(other, io);

    // The test's own copies, gone before the operations take the replies.
    const id = try gpa.dupe(u8, "user-7");
    const documents = try gpa.alloc(bson.RawDocument, 2);
    documents[0] = .{ .bytes = try gpa.dupe(u8, ann.bytes) };
    documents[1] = .{ .bytes = try gpa.dupe(u8, bob.bytes) };
    try fake.reply("fake://app", .{ .documents = documents });
    try fake.reply("fake://app", .{ .write = .{ .matched = 1, .upserted_id = .{ .string = id } } });
    try fake.reply("fake://app", .{ .count = 2 });
    try fake.reply("fake://app", .{ .command = documents[1] });
    gpa.free(id);
    for (documents) |doc| gpa.free(doc.bytes);
    gpa.free(documents);

    var d: odm.Diagnostics = .{};
    const options: Client.CallOptions = .{ .allocator = gpa, .diagnostics = &d };
    // A client of another uri takes none of them.
    try testing.expectEqual(@as(u64, 0), try other.count(io, .root, &.{ .ns = ns, .filter = .empty }, options));

    const cursor = try client.find(io, .root, &.{ .ns = ns, .filter = .empty }, options);
    defer cursor.deinit(io);
    try testing.expectEqualSlices(u8, ann.bytes, (try cursor.next(io, .root, &d)).?.bytes);
    try testing.expectEqualSlices(u8, bob.bytes, (try cursor.next(io, .root, &d)).?.bytes);
    try testing.expect(try cursor.next(io, .root, &d) == null);

    const updated = try client.update(io, .root, &.{ .ns = ns, .filter = ann, .update = bob, .mode = .one, .upsert = true }, options);
    defer gpa.free(updated.upserted_id.?.string);
    try testing.expectEqual(@as(u64, 1), updated.matched);
    try testing.expectEqual(@as(u64, 0), updated.modified);
    try testing.expectEqualStrings("user-7", updated.upserted_id.?.string);
    try testing.expectEqual(@as(u64, 2), try client.count(io, .root, &.{ .ns = ns, .filter = .empty }, options));
    const reply = try client.command(io, .root, &.{ .database = "app", .body = ann }, options);
    defer gpa.free(reply.bytes);
    try testing.expectEqualSlices(u8, bob.bytes, reply.bytes);

    // A reply of another kind than the operation's is a protocol
    // violation that names both.
    try fake.reply("fake://app", .{ .count = 3 });
    try testing.expectError(error.ProtocolViolation, client.find(io, .root, &.{ .ns = ns, .filter = .empty }, options));
    try testing.expectEqualStrings("the reply queued for this uri is 'count', which 'find' does not take", d.message());
}

test "counts follow open, connect, close and deinit" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const driver = fake.driver();
    try testing.expectEqual(FakeDriver.Counts{ .opened = 0, .connected = 0, .closed = 0, .close_calls = 0, .freed = 0, .cursors = 0 }, fake.counts(io));

    const a = try driver.open(io, &.{ .uri = "fake://a" });
    const b = try driver.open(io, &.{ .uri = "fake://b" });
    try a.connect(io, .root, null);
    try a.connect(io, .root, null);
    const cursor = try a.find(io, .root, &.{ .ns = ns, .filter = .empty }, .{ .allocator = testing.allocator });
    try testing.expectEqual(FakeDriver.Counts{ .opened = 2, .connected = 1, .closed = 0, .close_calls = 0, .freed = 0, .cursors = 1 }, fake.counts(io));

    a.close(io);
    a.close(io);
    // After close new calls are Closed, and so is the next of its cursor.
    try testing.expectError(error.Closed, a.ping(io, .root, null));
    try testing.expectError(error.Closed, a.connect(io, .root, null));
    try testing.expectError(error.Closed, cursor.next(io, .root, null));
    try testing.expectEqual(Client.PoolStats{ .connections = 0, .idle = 0, .in_use = 0, .waiting = 0 }, a.stats().?);
    cursor.deinit(io);
    b.close(io);
    try testing.expectEqual(FakeDriver.Counts{ .opened = 2, .connected = 1, .closed = 2, .close_calls = 3, .freed = 0, .cursors = 0 }, fake.counts(io));
    a.deinit();
    b.deinit();
    try testing.expectEqual(FakeDriver.Counts{ .opened = 2, .connected = 1, .closed = 2, .close_calls = 3, .freed = 2, .cursors = 0 }, fake.counts(io));

    // Every close is in the journal, the second one of a client too.
    var closes: usize = 0;
    for (fake.journal(io)) |entry| {
        if (entry.call == .close) closes += 1;
    }
    try testing.expectEqual(@as(usize, 3), closes);
}
