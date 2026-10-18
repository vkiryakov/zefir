//! The checks of layer L of `mongo.testing.conformance`, each against the
//! live mongod of `Options.live`: L1–L10 of the design of zefir-mongo.
//! They write to the database "zefir_conformance", in a collection of
//! their own, and drop it; L7–L10 configure the fail point `failCommand`
//! for one command and turn it off.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("../../bson.zig");
const errors = @import("../../errors.zig");
const requests = @import("../../requests.zig");
const results = @import("../../results.zig");
const Client = @import("../../contract/Client.zig");
const Cursor = @import("../../contract/Cursor.zig");
const Job = @import("Job.zig");

const database = "zefir_conformance";
const eql = std.mem.eql;

/// The budget of one operation of a check.
fn op(job: *const Job) requests.OperationContext {
    return job.within(60_000);
}

/// Runs `body` in the database of the checks and returns its reply.
fn command(job: *Job, client: Client, body: bson.RawDocument, comptime what: []const u8) Job.Error!bson.OwnedDocument {
    var d: errors.Diagnostics = .{};
    return client.runCommand(job.io, op(job), .{ .database = database, .body = body }, .{ .allocator = job.gpa, .diagnostics = &d }) catch |err|
        job.fail(what ++ " returned error.{t}: {s}", .{ err, d.message() });
}

/// Drops `collection`; one that is not there is no error.
fn drop(job: *Job, client: Client, collection: []const u8) Job.Error!void {
    const body = try job.encode(.{ .drop = collection });
    defer body.deinit();
    var d: errors.Diagnostics = .{};
    if (client.runCommand(job.io, op(job), .{ .database = database, .body = body.raw() }, .{ .allocator = job.gpa, .diagnostics = &d })) |reply| {
        reply.deinit();
    } else |err| {
        // NamespaceNotFound, from servers that report it.
        if (err == error.CommandFailed and d.server != null and d.server.?.code == 26) return;
        return job.fail("drop of {s} returned error.{t}: {s}", .{ collection, err, d.message() });
    }
}

fn write(job: *Job, client: Client, kind: requests.WriteKind, collection: []const u8, items: []const bson.RawDocument, ordered: bool) Job.Error!results.WriteResult {
    var b: bson.Builder = .init(job.gpa);
    defer b.deinit();
    b.putString(kind.command(), collection) catch return error.OutOfMemory;
    const body = b.finish() catch return error.OutOfMemory;
    defer body.deinit();
    var d: errors.Diagnostics = .{};
    return client.write(job.io, op(job), .{ .database = database, .kind = kind, .body = body.raw(), .items = items, .ordered = ordered }, .{ .allocator = job.gpa, .diagnostics = &d }) catch |err|
        job.fail("{s} into {s} returned error.{t}: {s}", .{ kind.command(), collection, err, d.message() });
}

/// The documents of the cursor of `body`, copied into `arena`.
fn all(job: *Job, client: Client, arena: Allocator, body: bson.RawDocument, options: requests.CursorOptions) Job.Error![]const bson.RawDocument {
    var d: errors.Diagnostics = .{};
    var with = options;
    with.diagnostics = &d;
    const cursor = client.openCursor(job.io, op(job), .{ .database = database, .body = body }, with) catch |err|
        return job.fail("openCursor returned error.{t}: {s}", .{ err, d.message() });
    defer cursor.deinit(job.io);
    var found: std.ArrayList(bson.RawDocument) = .empty;
    while (cursor.next(job.io, op(job)) catch |err| return job.fail("next returned error.{t}: {s}", .{ err, d.message() })) |doc| {
        try found.append(arena, .{ .bytes = try arena.dupe(u8, doc.bytes) });
    }
    return found.items;
}

/// How many documents `collection` holds, by `aggregate` with `$count`.
fn countOf(job: *Job, client: Client, collection: []const u8) Job.Error!i64 {
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const body = try job.encode(.{ .aggregate = collection, .pipeline = .{.{ .@"$count" = "n" }}, .cursor = .{} });
    defer body.deinit();
    const counted = try all(job, client, arena.allocator(), body.raw(), .{});
    if (counted.len == 0) return 0;
    const n = (counted[0].get("n") catch null) orelse return job.fail("$count of {s} came without n", .{collection});
    return n.asI64() catch job.fail("n of $count is not an integer", .{});
}

/// Fails unless `result` holds no refused item; the first one says why.
fn expectNoRefused(job: *Job, result: results.WriteResult, comptime what: []const u8) Job.Error!void {
    if (result.write_errors.len == 0) return;
    const first = result.write_errors[0];
    return job.fail(what ++ ": mongod refused {d} item(s), the first, item {d}, with code {d}: {s}", .{ result.write_errors.len, first.index, first.code, first.message });
}

fn expectSame(job: *Job, got: []const bson.RawDocument, expected: []const bson.RawDocument, comptime what: []const u8) Job.Error!void {
    try job.expect(got.len == expected.len, what ++ ": {d} documents, not {d}", .{ got.len, expected.len });
    for (got, expected, 0..) |g, e, i| try job.expect(eql(u8, g.bytes, e.bytes), what ++ ": document {d} is {f}, not {f}", .{ i, g, e });
}

pub fn l1(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(job, client, "l1");
    defer drop(job, client, "l1") catch {};

    const users = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .name = "Ann", .n = 1 }),
        bson.literal(.{ ._id = 2, .name = "Bob", .n = 2 }),
        bson.literal(.{ ._id = 3, .name = "Cid", .n = 3 }),
    };
    var inserted = try write(job, client, .insert, "l1", &users, true);
    defer inserted.deinit(job.gpa);
    try job.expect(inserted.n == 3 and inserted.write_errors.len == 0, "an insert of 3 documents came back with n {d} and {d} refused", .{ inserted.n, inserted.write_errors.len });
    const find = bson.literal(.{ .find = "l1", .filter = .{}, .sort = .{ ._id = 1 } });
    try expectSame(job, try all(job, client, a, find, .{}), &users, "find after the insert");

    var updated = try write(job, client, .update, "l1", &.{bson.literal(.{ .q = .{ ._id = 2 }, .u = .{ .@"$set" = .{ .n = 20 } } })}, true);
    defer updated.deinit(job.gpa);
    try job.expect(updated.n == 1 and updated.modified == 1, "an update of one document came back with n {d} and modified {d}", .{ updated.n, updated.modified });

    const modified = try command(job, client, bson.literal(.{ .findAndModify = "l1", .query = .{ ._id = 3 }, .update = .{ .@"$inc" = .{ .n = 1 } }, .new = true }), "findAndModify");
    defer modified.deinit();
    const value = (modified.raw().get("value") catch null) orelse return job.fail("findAndModify came without value", .{});
    try job.expect(value == .document and eql(u8, value.document.bytes, bson.literal(.{ ._id = 3, .name = "Cid", .n = 4 }).bytes), "findAndModify with new came with another value than the document after the update", .{});

    var deleted = try write(job, client, .delete, "l1", &.{bson.literal(.{ .q = .{ ._id = 1 }, .limit = 1 })}, true);
    defer deleted.deinit(job.gpa);
    try job.expect(deleted.n == 1, "a delete of one document came back with n {d}", .{deleted.n});

    try job.expect(try countOf(job, client, "l1") == 2, "aggregate with $count after the delete is not 2", .{});
    try expectSame(job, try all(job, client, a, find, .{}), &.{ bson.literal(.{ ._id = 2, .name = "Bob", .n = 20 }), bson.literal(.{ ._id = 3, .name = "Cid", .n = 4 }) }, "find after the update, findAndModify and the delete");
}

const l2_comment = "zefir-conformance-l2";

/// The id of the idle cursor of mongod whose command had `comment`.
fn idleCursor(job: *Job, client: Client) Job.Error!?i64 {
    const body = bson.literal(.{
        .aggregate = 1,
        .pipeline = .{
            .{ .@"$currentOp" = .{ .idleCursors = true, .allUsers = true } },
            .{ .@"$match" = .{ .type = "idleCursor", .@"cursor.originatingCommand.comment" = l2_comment } },
        },
        .cursor = .{},
    });
    var d: errors.Diagnostics = .{};
    const reply = client.runCommand(job.io, op(job), .{ .database = "admin", .body = body }, .{ .allocator = job.gpa, .diagnostics = &d }) catch |err|
        return job.fail("$currentOp returned error.{t}: {s}", .{ err, d.message() });
    defer reply.deinit();
    const id = (reply.raw().getPath("cursor.firstBatch.0.cursor.cursorId") catch null) orelse return null;
    return id.asI64() catch null;
}

pub fn l2(job: *Job) Job.Error!void {
    const io = job.io;
    const client = try job.live();
    defer job.end();
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(job, client, "l2");
    defer drop(job, client, "l2") catch {};
    var items: [250]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = (try job.encodeIn(a, .{ ._id = @as(i32, @intCast(i)) })).raw();
    var inserted = try write(job, client, .insert, "l2", &items, true);
    defer inserted.deinit(job.gpa);
    try job.expect(inserted.n == 250, "an insert of 250 documents came back with n {d}", .{inserted.n});

    const find = bson.literal(.{ .find = "l2", .filter = .{}, .sort = .{ ._id = 1 }, .batchSize = 7 });
    try expectSame(job, try all(job, client, a, find, .{ .batch_size = 7 }), &items, "a cursor of 250 documents at a batchSize of 7");

    const commented = bson.literal(.{ .find = "l2", .filter = .{}, .sort = .{ ._id = 1 }, .batchSize = 7, .comment = l2_comment });
    var cursor = client.openCursor(io, op(job), .{ .database = database, .body = commented }, .{ .batch_size = 7 }) catch |err|
        return job.fail("openCursor returned error.{t}", .{err});
    defer cursor.deinit(io);
    for (0..10) |i| {
        const doc = (cursor.next(io, op(job)) catch |err| return job.fail("next returned error.{t}", .{err})) orelse return job.fail("the cursor ended after {d} documents", .{i});
        try job.expect(eql(u8, doc.bytes, items[i].bytes), "document {d} of the cursor came changed", .{i});
    }
    const id = (try idleCursor(job, client)) orelse return job.fail("the cursor in its middle is not among the idle cursors of mongod", .{});
    cursor.close(io);
    try job.expect(try idleCursor(job, client) == null, "the cursor is still among the idle cursors of mongod after close", .{});
    const again = try job.encode(.{ .killCursors = "l2", .cursors = .{id} });
    defer again.deinit();
    const killed = try command(job, client, again.raw(), "a second killCursors");
    defer killed.deinit();
    const not_found = (killed.raw().getPath("cursorsNotFound.0") catch null) orelse return job.fail("a second killCursors of the closed cursor did not report it in cursorsNotFound: close sent no killCursors", .{});
    try job.expect((not_found.asI64() catch 0) == id, "a second killCursors reported another cursor in cursorsNotFound", .{});
}

/// Ten documents, `{_id: 0}` to `{_id: 9}`.
const ten = ten: {
    var items: [10]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = bson.literal(.{ ._id = @as(i32, i) });
    break :ten items;
};

fn expectRefused(job: *Job, result: results.WriteResult, indexes: []const usize, comptime what: []const u8) Job.Error!void {
    try job.expect(result.write_errors.len == indexes.len, what ++ ": {d} items refused, not {d}", .{ result.write_errors.len, indexes.len });
    for (result.write_errors, indexes) |refused, index| {
        try job.expect(refused.index == index and refused.code == 11000, what ++ ": item {d} refused with code {d}, where item {d} is a duplicate key (11000)", .{ refused.index, refused.code, index });
    }
}

pub fn l3(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    try drop(job, client, "l3");
    defer drop(job, client, "l3") catch {};
    var taken = try write(job, client, .insert, "l3", &.{ ten[3], ten[7] }, true);
    taken.deinit(job.gpa);
    var unordered = try write(job, client, .insert, "l3", &ten, false);
    defer unordered.deinit(job.gpa);
    try job.expect(unordered.n == 8, "an unordered insert of 10 documents, 2 of them duplicates, came back with n {d}, not 8", .{unordered.n});
    try expectRefused(job, unordered, &.{ 3, 7 }, "an unordered insert");
    try job.expect(try countOf(job, client, "l3") == 10, "after an unordered insert with duplicates, the collection does not hold 10 documents", .{});

    try drop(job, client, "l3");
    taken = try write(job, client, .insert, "l3", &.{ten[3]}, true);
    taken.deinit(job.gpa);
    var ordered = try write(job, client, .insert, "l3", &ten, true);
    defer ordered.deinit(job.gpa);
    try job.expect(ordered.n == 3, "an ordered insert of 10 documents, the fourth a duplicate, came back with n {d}, not 3", .{ordered.n});
    try expectRefused(job, ordered, &.{3}, "an ordered insert");
    try job.expect(try countOf(job, client, "l3") == 4, "after an ordered insert that stopped at its fourth item, the collection does not hold 4 documents", .{});
}

pub fn l4(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    var d: errors.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    defer if (failure) |f| f.deinit();
    try job.expectError(client.runCommand(job.io, op(job), .{ .database = database, .body = bson.literal(.{ .zefirNoSuchCommand = 1 }) }, .{ .allocator = job.gpa, .diagnostics = &d, .failure_reply = &failure }), error.CommandFailed, "an unknown command");
    const server = d.server orelse return job.fail("Diagnostics.server is null after an unknown command", .{});
    try job.expect(server.code == 59 and eql(u8, server.code_name.slice(), "CommandNotFound"), "an unknown command came with the code {d} \"{s}\", not 59 \"CommandNotFound\"", .{ server.code, server.code_name.slice() });
    try job.expect(d.message().len > 0, "Diagnostics.message() is empty after an unknown command", .{});
    const reply = failure orelse return job.fail("failure_reply is null after an unknown command", .{});
    const code = (reply.raw().get("code") catch null) orelse return job.fail("failure_reply holds no code", .{});
    try job.expect((code.asI64() catch 0) == 59, "failure_reply holds another code than 59", .{});
}

/// One of the 64 tasks of L5: ten inserts, each read back by its _id.
const Worker = struct {
    job: *Job,
    client: Client,
    task: usize,
    err: ?errors.Error = null,
    what: []const u8 = "",

    fn go(w: *Worker) void {
        const io = w.job.io;
        const gpa = w.job.gpa;
        for (0..10) |j| {
            const id: i32 = @intCast(w.task * 100 + j);
            const doc = bson.encode(gpa, .{ ._id = id, .task = @as(i32, @intCast(w.task)) }, .{}) catch return w.failed(error.OutOfMemory, "encode");
            defer doc.deinit();
            var result = w.client.write(io, op(w.job), .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "l5" }), .items = &.{doc.raw()} }, .{ .allocator = gpa }) catch |err| return w.failed(err, "insert");
            defer result.deinit(gpa);
            if (result.n != 1) return w.failed(error.ProtocolViolation, "an insert came back with n other than 1");
            const find = bson.encode(gpa, .{ .find = "l5", .filter = .{ ._id = id } }, .{}) catch return w.failed(error.OutOfMemory, "encode");
            defer find.deinit();
            const cursor = w.client.openCursor(io, op(w.job), .{ .database = database, .body = find.raw() }, .{}) catch |err| return w.failed(err, "openCursor");
            defer cursor.deinit(io);
            const found = (cursor.next(io, op(w.job)) catch |err| return w.failed(err, "next")) orelse return w.failed(error.ProtocolViolation, "find did not find the document just inserted");
            if (!eql(u8, found.bytes, doc.bytes)) return w.failed(error.ProtocolViolation, "find found another document than the one just inserted");
            if ((cursor.next(io, op(w.job)) catch |err| return w.failed(err, "next")) != null) return w.failed(error.ProtocolViolation, "find by _id found two documents");
        }
    }

    fn failed(w: *Worker, err: errors.Error, what: []const u8) void {
        w.err = err;
        w.what = what;
    }
};

pub fn l5(job: *Job) Job.Error!void {
    const io = job.io;
    const client = try job.live();
    defer job.end();
    try drop(job, client, "l5");
    defer drop(job, client, "l5") catch {};
    var workers: [64]Worker = undefined;
    var futures: [64]Io.Future(void) = undefined;
    var begun: usize = 0;
    defer for (futures[0..begun]) |*future| future.await(io);
    for (&workers, &futures, 0..) |*worker, *future, i| {
        worker.* = .{ .job = job, .client = client, .task = i };
        future.* = io.concurrent(Worker.go, .{worker}) catch |err| return job.fail("no task for worker {d}: io.concurrent returned error.{t}", .{ i, err });
        begun += 1;
    }
    for (futures[0..begun]) |*future| future.await(io);
    for (workers, 0..) |worker, i| {
        if (worker.err) |err| return job.fail("task {d} of 64: {s} returned error.{t}", .{ i, worker.what, err });
    }
    try job.expect(try countOf(job, client, "l5") == 640, "after 64 tasks of 10 inserts each, the collection does not hold 640 documents", .{});
}

/// `{_id: id, data: <binary>}` of `size` bytes in all, in `arena`, written
/// in place: a builder would leave every buffer it grew out of in the
/// arena.
fn sized(job: *Job, arena: Allocator, id: i32, size: usize) Job.Error!bson.RawDocument {
    // The length, _id (9 bytes), data (11 bytes and the payload), the end.
    const bytes = try arena.alloc(u8, size);
    std.mem.writeInt(i32, bytes[0..4], @intCast(size), .little);
    bytes[4] = 0x10;
    @memcpy(bytes[5..9], "_id\x00");
    std.mem.writeInt(i32, bytes[9..13], id, .little);
    bytes[13] = 0x05;
    @memcpy(bytes[14..19], "data\x00");
    std.mem.writeInt(i32, bytes[19..23], @intCast(size - 25), .little);
    bytes[23] = 0;
    @memset(bytes[24 .. size - 1], @truncate(@as(u32, @bitCast(id)) *% 31 +% 7));
    bytes[size - 1] = 0;
    const doc: bson.RawDocument = .{ .bytes = bytes };
    doc.validate() catch return job.fail("a document of {d} bytes of the check is not valid BSON", .{size});
    return doc;
}

const mib = 1024 * 1024;

pub fn l6(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try drop(job, client, "l6");
    defer drop(job, client, "l6") catch {};

    // A document of almost 16 MiB, there and back.
    const big = try sized(job, a, 1, 16 * mib - 64);
    var one = try write(job, client, .insert, "l6", &.{big}, true);
    defer one.deinit(job.gpa);
    try expectNoRefused(job, one, "the insert of a document of almost 16 MiB");
    try job.expect(one.n == 1, "the insert of a document of almost 16 MiB came back with n {d}", .{one.n});
    try expectSame(job, try all(job, client, a, bson.literal(.{ .find = "l6", .filter = .{ ._id = 1 } }), .{}), &.{big}, "a document of almost 16 MiB read back");

    // A find of 18 MiB: mongod cuts its batches at 16 MiB.
    var six: [3]bson.RawDocument = undefined;
    for (&six, 2..) |*doc, id| doc.* = try sized(job, a, @intCast(id), 6 * mib);
    var three = try write(job, client, .insert, "l6", &six, true);
    defer three.deinit(job.gpa);
    try expectNoRefused(job, three, "the insert of three documents of 6 MiB");
    try job.expect(three.n == 3, "the insert of three documents of 6 MiB came back with n {d}", .{three.n});
    try expectSame(job, try all(job, client, a, bson.literal(.{ .find = "l6", .filter = .{ ._id = .{ .@"$gte" = 2, .@"$lte" = 4 } }, .sort = .{ ._id = 1 } }), .{}), &six, "a find of three documents of 6 MiB");

    // An insert of 50 MiB, which maxMessageSizeBytes splits.
    var ten_mib: [5]bson.RawDocument = undefined;
    for (&ten_mib, 10..) |*doc, id| doc.* = try sized(job, a, @intCast(id), 10 * mib);
    var five = try write(job, client, .insert, "l6", &ten_mib, true);
    defer five.deinit(job.gpa);
    try expectNoRefused(job, five, "the insert of five documents of 10 MiB");
    try job.expect(five.n == 5, "the insert of five documents of 10 MiB came back with n {d}", .{five.n});
    try job.expect(try countOf(job, client, "l6") == 9, "after the inserts the collection does not hold 9 documents", .{});
}

/// Configures `failCommand` to fail the next command it names, once.
fn failPoint(job: *Job, client: Client, data: anytype) Job.Error!void {
    const body = try job.encode(.{ .configureFailPoint = "failCommand", .mode = .{ .times = 1 }, .data = data });
    defer body.deinit();
    var d: errors.Diagnostics = .{};
    const reply = client.runCommand(job.io, op(job), .{ .database = "admin", .body = body.raw() }, .{ .allocator = job.gpa, .diagnostics = &d }) catch |err|
        return job.fail("configureFailPoint returned error.{t}: {s}; fail points need a mongod with enableTestCommands=1", .{ err, d.message() });
    reply.deinit();
}

fn failPointOff(job: *Job, client: Client) void {
    const off = bson.literal(.{ .configureFailPoint = "failCommand", .mode = "off" });
    const reply = client.runCommand(job.io, op(job), .{ .database = "admin", .body = off }, .{ .allocator = job.gpa }) catch return;
    reply.deinit();
}

pub fn l7(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    defer failPointOff(job, client);
    try failPoint(job, client, .{ .failCommands = .{"count"}, .closeConnection = true });
    const body = bson.literal(.{ .count = "l7" });
    try job.expectError(client.runCommand(job.io, op(job), .{ .database = database, .body = body }, .{ .allocator = job.gpa }), error.ConnectionLost, "a command whose connection mongod closed");
    const next = try command(job, client, body, "the command after ConnectionLost");
    next.deinit();
}

pub fn l8(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    try drop(job, client, "l8");
    defer drop(job, client, "l8") catch {};
    defer failPointOff(job, client);
    try failPoint(job, client, .{ .failCommands = .{"insert"}, .errorCode = 91, .errorLabels = .{"RetryableWriteError"} });
    var d: errors.Diagnostics = .{};
    // Failed once: a retry would have gone through.
    try job.expectError(client.write(job.io, op(job), .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "l8" }), .items = ten[0..1] }, .{ .allocator = job.gpa, .diagnostics = &d }), error.CommandFailed, "an insert that mongod failed with 91 once");
    const server = d.server orelse return job.fail("Diagnostics.server is null after CommandFailed", .{});
    try job.expect(server.code == 91, "Diagnostics.server.code is {d}, not 91", .{server.code});
    try job.expect(server.labels.contains(.retryable_write_error), "Diagnostics.server.labels lack RetryableWriteError", .{});
    try job.expect(try countOf(job, client, "l8") == 0, "the failed insert left a document: the driver sent it again", .{});
    var again = try write(job, client, .insert, "l8", ten[0..1], true);
    again.deinit(job.gpa);
}

pub fn l9(job: *Job) Job.Error!void {
    const client = try job.live();
    defer job.end();
    defer failPointOff(job, client);
    try failPoint(job, client, .{ .failCommands = .{"find"}, .errorCode = 462, .errorLabels = .{ "SystemOverloadedError", "RetryableError" } });
    var d: errors.Diagnostics = .{};
    const find: requests.Command = .{ .database = database, .body = bson.literal(.{ .find = "l9" }) };
    try job.expectError(client.openCursor(job.io, op(job), find, .{ .diagnostics = &d }), error.CommandFailed, "a find that mongod failed with 462 once, which a retry would have passed");
    const server = d.server orelse return job.fail("Diagnostics.server is null after CommandFailed", .{});
    try job.expect(server.code == 462, "Diagnostics.server.code is {d}, not 462", .{server.code});
    try job.expect(server.labels.contains(.system_overloaded_error) and server.labels.contains(.retryable_error), "Diagnostics.server.labels lack SystemOverloadedError or RetryableError", .{});
    const cursor = try job.need(client.openCursor(job.io, op(job), find, .{}), "the find after CommandFailed");
    cursor.deinit(job.io);
}

pub fn l10(job: *Job) Job.Error!void {
    const io = job.io;
    const client = try job.live();
    defer job.end();
    defer failPointOff(job, client);
    try failPoint(job, client, .{ .failCommands = .{"find"}, .blockConnection = true, .blockTimeMS = @as(i32, @intCast(1000 * job.scale())) });
    const deadline: core.Deadline = .after(Job.now(io), job.ms(300));
    try job.expectError(client.openCursor(io, .of(core.Context.root.withDeadline(deadline)), .{ .database = database, .body = bson.literal(.{ .find = "l10" }) }, .{}), error.Timeout, "a find that mongod held past the deadline");
    const overdue = deadline.expires.durationTo(Job.now(io));
    try job.expect(overdue.nanoseconds <= job.ms(500).nanoseconds, "Timeout came {d} ms after the deadline", .{overdue.toMilliseconds()});

    try failPoint(job, client, .{ .failCommands = .{"count"}, .errorCode = 50 });
    const body = bson.literal(.{ .count = "l10" });
    try job.expectError(client.runCommand(io, op(job), .{ .database = database, .body = body }, .{ .allocator = job.gpa }), error.Timeout, "a command that mongod failed with code 50");
    const next = try command(job, client, body, "the command after Timeout");
    next.deinit();
}
