//! The checks of group D of `odm.testing.conformance`, D1–D10: the data,
//! on a server that runs the queries. Each writes to collections of its
//! own in the fresh database of its setup.

const std = @import("std");
const bson = @import("mongo-bson");
const odm = @import("../../root.zig");
const Job = @import("Job.zig");
const Error = Job.Error;

/// `{_id: i, n: i, g: "a" or "b", s: "item-i"}` for i in 0…6; g is "a"
/// for even i.
const seven = seven: {
    var docs: [7]bson.RawDocument = undefined;
    for (&docs, 0..) |*d, i| d.* = bson.literal(.{
        ._id = @as(i32, i),
        .n = @as(i32, i),
        .g = if (i % 2 == 0) "a" else "b",
        .s = std.fmt.comptimePrint("item-{d}", .{i}),
    });
    break :seven docs;
};

const by_id = bson.literal(.{ ._id = 1 });

pub fn d1(job: *Job) Error!void {
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d1");
    const docs = [_]bson.RawDocument{
        bson.literal(.{ ._id = bson.ObjectId{ .bytes = "\x65\x1a\x2b\x3c\x4d\x5e\x6f\x70\x81\x92\xa3\xb4".* }, .kind = "an ObjectId" }),
        bson.literal(.{ ._id = "text", .kind = "a string" }),
        bson.literal(.{ ._id = @as(i64, 1) << 40, .kind = "an int64" }),
    };
    const inserted = try job.need(client.insert(job.io, job.ctx(), &.{ .ns = at, .documents = &docs }, job.call()), "insert");
    try job.expect(inserted.inserted == 3, "insert of 3 documents says it inserted {d}", .{inserted.inserted});
    for (docs) |doc| {
        const id = (doc.get("_id") catch null) orelse return job.fail("a document of the check has no _id: {f}", .{doc});
        var b: bson.Builder = .init(job.scratch);
        b.putValue("_id", id) catch return job.fail("a filter by _id did not become BSON", .{});
        const filter = b.finish() catch return job.fail("a filter by _id did not become BSON", .{});
        const found = try job.findAll(client, .{ .ns = at, .filter = filter.raw() }, "find by _id");
        try job.expect(found.len == 1, "find by the _id of {f} gave {d} documents, not 1", .{ doc, found.len });
        try job.expectDocument(found[0], doc, "the document found by its _id");
    }
}

pub fn d2(job: *Job) Error!void {
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d2");
    const docs = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .n = 1 }),
        bson.literal(.{ ._id = 2, .n = 2 }),
        bson.literal(.{ ._id = 1, .n = 3 }),
        bson.literal(.{ ._id = 4, .n = 4 }),
    };
    try job.expectError(client.insert(job.io, job.ctx(), &.{ .ns = at, .documents = &docs }, job.call()), error.DuplicateKey, "insert of a repeated _id");
    try job.expect(job.diag.index != null and job.diag.index.? == 2, "Diagnostics.index of the repeated _id is {?d}, not 2", .{job.diag.index});
    const kept = try job.findAll(client, .{ .ns = at, .filter = .empty, .sort = bson.literal(.{ ._id = 1 }) }, "find after the duplicate");
    // The insert stops at the document that the server refused.
    try job.expectNumbers(kept, "n", &.{ 1, 2 }, "find after the duplicate");
}

pub fn d3(job: *Job) Error!void {
    const client = try job.connected();
    defer job.release(client);
    if (!client.capabilities().indexes) return job.skip("the client has no capability indexes");
    const io = job.io;
    const at = job.ns("d3");
    const unique: odm.Client.IndexSpec = .{ .name = "email_1", .keys = bson.literal(.{ .email = 1 }), .unique = true };
    try job.need(client.createIndexes(io, job.ctx(), &.{ .ns = at, .indexes = &.{unique} }, job.call()), "createIndexes of a unique index");
    try job.need(client.createIndexes(io, job.ctx(), &.{ .ns = at, .indexes = &.{unique} }, job.call()), "createIndexes of the same index again");
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &.{bson.literal(.{ ._id = 1, .email = "ann@example.com" })} }, job.call()), "insert");
    try job.expectError(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &.{bson.literal(.{ ._id = 2, .email = "ann@example.com" })} }, job.call()), error.DuplicateKey, "insert of a second document with the key of a unique index");
    try job.expect(job.diag.index != null and job.diag.index.? == 0, "Diagnostics.index of the duplicate key is {?d}, not 0", .{job.diag.index});
    const sparse: odm.Client.IndexSpec = .{ .name = "nick_1", .keys = bson.literal(.{ .nick = 1 }), .unique = true, .sparse = true };
    try job.need(client.createIndexes(io, job.ctx(), &.{ .ns = at, .indexes = &.{sparse} }, job.call()), "createIndexes of a unique sparse index");
    const without = [_]bson.RawDocument{ bson.literal(.{ ._id = 3, .email = "bob@example.com" }), bson.literal(.{ ._id = 4, .email = "cid@example.com" }) };
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &without }, job.call()), "insert of two documents without the key of a unique sparse index");
    const all = try job.findAll(client, .{ .ns = at, .filter = .empty, .sort = bson.literal(.{ ._id = 1 }) }, "find");
    try job.expectNumbers(all, "_id", &.{ 1, 3, 4 }, "find");
}

pub fn d4(job: *Job) Error!void {
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d4");
    _ = try job.need(client.insert(job.io, job.ctx(), &.{ .ns = at, .documents = &seven }, job.call()), "insert");
    const by_id_order = bson.literal(.{ ._id = 1 });
    const Case = struct { what: []const u8, request: odm.Client.FindRequest, n: []const i64 };
    const cases = [_]Case{
        .{ .what = "find by equality", .request = .{ .ns = at, .filter = bson.literal(.{ .g = "a" }), .sort = by_id_order }, .n = &.{ 0, 2, 4, 6 } },
        .{ .what = "find by $gte", .request = .{ .ns = at, .filter = bson.literal(.{ .n = .{ .@"$gte" = 5 } }), .sort = by_id_order }, .n = &.{ 5, 6 } },
        .{ .what = "find by $in", .request = .{ .ns = at, .filter = bson.literal(.{ .n = .{ .@"$in" = .{ 1, 3 } } }), .sort = by_id_order }, .n = &.{ 1, 3 } },
        .{ .what = "find by $regex", .request = .{ .ns = at, .filter = bson.literal(.{ .s = .{ .@"$regex" = "^item-[12]$" } }), .sort = by_id_order }, .n = &.{ 1, 2 } },
        .{ .what = "find sorted by two keys", .request = .{ .ns = at, .filter = .empty, .sort = bson.literal(.{ .g = 1, .n = -1 }) }, .n = &.{ 6, 4, 2, 0, 5, 3, 1 } },
        .{ .what = "find with skip and limit", .request = .{ .ns = at, .filter = .empty, .sort = by_id_order, .skip = 2, .limit = 3 }, .n = &.{ 2, 3, 4 } },
        .{ .what = "find in batches of 2", .request = .{ .ns = at, .filter = .empty, .sort = by_id_order, .batch_size = 2 }, .n = &.{ 0, 1, 2, 3, 4, 5, 6 } },
        .{ .what = "find with limit 1", .request = .{ .ns = at, .filter = .empty, .sort = bson.literal(.{ .n = -1 }), .limit = 1 }, .n = &.{6} },
    };
    for (cases) |case| {
        const found = try job.findAll(client, case.request, "find");
        try job.expectNumbers(found, "n", case.n, case.what);
    }
    const projected = try job.findAll(client, .{ .ns = at, .filter = bson.literal(.{ ._id = 3 }), .projection = bson.literal(.{ .n = 1, ._id = 0 }) }, "find with a projection");
    try job.expect(projected.len == 1, "find with a projection gave {d} documents, not 1", .{projected.len});
    try job.expectDocument(projected[0], bson.literal(.{ .n = 3 }), "the document of a find with a projection");
}

pub fn d5(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d5");
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = seven[0..5] }, job.call()), "insert");
    const cursor = try job.need(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty, .sort = bson.literal(.{ ._id = 1 }), .batch_size = 2 }, job.call()), "find");
    defer cursor.deinit(io);
    var n: [5]i64 = undefined;
    for (n[0..2]) |*slot| {
        const doc = (try job.need(cursor.next(io, job.ctx(), &job.diag), "next")) orelse return job.fail("the cursor ended after fewer than 2 documents of 5", .{});
        slot.* = try job.number(doc, "n");
    }
    // The first batch is out: the next document needs a getMore.
    try job.expectError(cursor.next(io, job.nearlyExpired(), &job.diag), error.DeadlineExceeded, "next past the first batch with less than 1 ms left");
    for (n[2..]) |*slot| {
        const doc = (try job.need(cursor.next(io, job.ctx(), &job.diag), "next after DeadlineExceeded")) orelse return job.fail("the cursor ended after DeadlineExceeded, before its 5 documents", .{});
        slot.* = try job.number(doc, "n");
    }
    try job.expect(try job.need(cursor.next(io, job.ctx(), &job.diag), "next at the end") == null, "the cursor gave more than its 5 documents", .{});
    try job.expect(std.mem.eql(i64, &n, &.{ 0, 1, 2, 3, 4 }), "the cursor gave {any}, not 0 to 4", .{n});
}

pub fn d6(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d6");
    const docs = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .g = "a", .n = 0 }),
        bson.literal(.{ ._id = 2, .g = "a", .n = 0 }),
        bson.literal(.{ ._id = 3, .g = "b", .n = 0 }),
    };
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &docs }, job.call()), "insert");
    const a = bson.literal(.{ .g = "a" });
    const one = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = a, .update = bson.literal(.{ .@"$set" = .{ .n = 1 } }), .mode = .one }, job.call()), "update .one");
    try expectCounts(job, one, 1, 1, "update .one");
    const many = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = a, .update = bson.literal(.{ .@"$inc" = .{ .n = 1 } }), .mode = .many }, job.call()), "update .many");
    try expectCounts(job, many, 2, 2, "update .many");
    const none = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = bson.literal(.{ .g = "z" }), .update = bson.literal(.{ .@"$set" = .{ .n = 9 } }), .mode = .one }, job.call()), "update that matches nothing");
    try expectCounts(job, none, 0, 0, "update that matches nothing");
    try job.expect(none.upserted_id == null, "an update without upsert has an upserted_id", .{});
    const upsert = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = bson.literal(.{ ._id = "up" }), .update = bson.literal(.{ .@"$set" = .{ .n = 5 } }), .mode = .one, .upsert = true }, job.call()), "update with upsert");
    try expectCounts(job, upsert, 0, 0, "update with upsert");
    const id = upsert.upserted_id orelse return job.fail("the update with upsert inserted a document, but upserted_id is null", .{});
    try job.expect(id == .string and std.mem.eql(u8, id.string, "up"), "upserted_id is {any}, not the string \"up\"", .{id});
    const replaced = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = bson.literal(.{ ._id = 3 }), .update = bson.literal(.{ .g = "c", .n = 7 }), .mode = .replace }, job.call()), "update .replace");
    try expectCounts(job, replaced, 1, 1, "update .replace");
    const after = try job.findAll(client, .{ .ns = at, .filter = bson.literal(.{ ._id = 3 }) }, "find after replace");
    try job.expect(after.len == 1, "find of the replaced document gave {d} documents, not 1", .{after.len});
    try job.expectDocument(after[0], bson.literal(.{ ._id = 3, .g = "c", .n = 7 }), "the replaced document");
}

fn expectCounts(job: *Job, result: odm.Client.UpdateResult, matched: u64, modified: u64, comptime what: []const u8) Error!void {
    try job.expect(result.matched == matched and result.modified == modified, what ++ " matched {d} and modified {d}, not {d} and {d}", .{ result.matched, result.modified, matched, modified });
}

pub fn d7(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns("d7");
    const docs = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .g = "a" }),
        bson.literal(.{ ._id = 2, .g = "a" }),
        bson.literal(.{ ._id = 3, .g = "a" }),
        bson.literal(.{ ._id = 4, .g = "b" }),
    };
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &docs }, job.call()), "insert");
    const a = bson.literal(.{ .g = "a" });
    const one = try job.need(client.delete(io, job.ctx(), &.{ .ns = at, .filter = a, .many = false }, job.call()), "delete of one");
    try job.expect(one.deleted == 1, "delete of one deleted {d}", .{one.deleted});
    try expectCount(job, client, a, 2, "count after the delete of one");
    const many = try job.need(client.delete(io, job.ctx(), &.{ .ns = at, .filter = a, .many = true }, job.call()), "delete of many");
    try job.expect(many.deleted == 2, "delete of many deleted {d}, not 2", .{many.deleted});
    try expectCount(job, client, .empty, 1, "count after the delete of many");
}

/// The documents that `filter` matches in d7: `count`, or `find` without
/// the capability.
fn expectCount(job: *Job, client: odm.Client, filter: bson.RawDocument, expected: u64, comptime what: []const u8) Error!void {
    const at = job.ns("d7");
    const n: u64 = if (client.capabilities().count)
        try job.need(client.count(job.io, job.ctx(), &.{ .ns = at, .filter = filter }, job.call()), what)
    else
        (try job.findAll(client, .{ .ns = at, .filter = filter }, what)).len;
    try job.expect(n == expected, what ++ " is {d}, not {d}", .{ n, expected });
}

pub fn d8(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    if (!client.capabilities().aggregate) return job.skip("the client has no capability aggregate");
    const at = job.ns("d8");
    const docs = [_]bson.RawDocument{
        bson.literal(.{ ._id = 1, .g = "a", .n = 1 }),
        bson.literal(.{ ._id = 2, .g = "a", .n = 2 }),
        bson.literal(.{ ._id = 3, .g = "b", .n = 5 }),
        bson.literal(.{ ._id = 4, .g = "b", .n = 0 }),
    };
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &docs }, job.call()), "insert");
    const pipeline = [_]bson.RawDocument{
        bson.literal(.{ .@"$match" = .{ .n = .{ .@"$gte" = 1 } } }),
        bson.literal(.{ .@"$group" = .{ ._id = "$g", .total = .{ .@"$sum" = "$n" }, .count = .{ .@"$sum" = 1 } } }),
        bson.literal(.{ .@"$sort" = .{ ._id = 1 } }),
    };
    const cursor = try job.need(client.aggregate(io, job.ctx(), &.{ .ns = at, .pipeline = &pipeline }, job.call()), "aggregate");
    const groups = try job.drain(cursor, "aggregate");
    try job.expect(groups.len == 2, "aggregate gave {d} groups, not 2", .{groups.len});
    for (groups, [_][]const u8{ "a", "b" }, [_]i64{ 3, 5 }, [_]i64{ 2, 1 }) |group, name, total, count| {
        const id = (group.get("_id") catch null) orelse return job.fail("a group of aggregate has no _id: {f}", .{group});
        try job.expect(id == .string and std.mem.eql(u8, id.string, name), "a group of aggregate is {f}, not the group \"{s}\"", .{ group, name });
        try job.expect(try job.number(group, "total") == total and try job.number(group, "count") == count, "the group \"{s}\" of aggregate is {f}, not a total of {d} in {d}", .{ name, group, total, count });
    }
}

pub fn d9(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    if (!client.capabilities().command) return job.skip("the client has no capability command");
    const reply = try job.need(client.command(io, job.ctx(), &.{ .database = job.setup.database, .body = bson.literal(.{ .ping = 1 }) }, job.call()), "command ping");
    const ok = (reply.get("ok") catch null) orelse return job.fail("the reply of ping holds no ok: {f}", .{reply});
    const one = switch (ok) {
        .double => |x| x == 1,
        .int32 => |x| x == 1,
        .int64 => |x| x == 1,
        else => false,
    };
    try job.expect(one, "the reply of ping is {f}, without ok: 1", .{reply});
    try job.expectError(client.command(io, job.ctx(), &.{ .database = job.setup.database, .body = bson.literal(.{ .zefirConformanceNoSuchCommand = 1 }) }, job.call()), error.CommandFailed, "an unknown command");
    try job.expect(job.diag.code != null and job.diag.code.? == 59, "the code of an unknown command is {?d}, not 59", .{job.diag.code});
}

pub fn d10(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const xs = job.ns("d10");
    const ys = job.ns("d10_other");
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = xs, .documents = seven[0..4] }, job.call()), "insert");
    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = ys, .documents = seven[3..7] }, job.call()), "insert");
    const order = bson.literal(.{ ._id = 1 });
    const x = try job.need(client.find(io, job.ctx(), &.{ .ns = xs, .filter = .empty, .sort = order, .batch_size = 1 }, job.call()), "find");
    defer x.deinit(io);
    const y = try job.need(client.find(io, job.ctx(), &.{ .ns = ys, .filter = .empty, .sort = order, .batch_size = 1 }, job.call()), "find");
    defer y.deinit(io);
    const first = (try job.need(x.next(io, job.ctx(), &job.diag), "next")) orelse return job.fail("the first cursor gave no document", .{});
    // The other cursor runs its getMores while `first` is borrowed.
    var others: usize = 0;
    while (try job.need(y.next(io, job.ctx(), &job.diag), "next of the other cursor")) |_| others += 1;
    try job.expect(others == 4, "the other cursor gave {d} documents, not 4", .{others});
    try job.expectDocument(first, seven[0], "the document of next, after another cursor ran to its end");
    const second = (try job.need(x.next(io, job.ctx(), &job.diag), "next")) orelse return job.fail("the first cursor ended after one document", .{});
    try job.expectDocument(second, seven[1], "the second document of the cursor");
}
