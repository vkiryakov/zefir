//! Tests of `write_concern` in the options of the collection API's ten
//! writes on the client against `mongo.testing.FakeServer`: the
//! `writeConcern` that each command carries in the script's journal, or
//! not; a `writeConcernError` in the reply of each; and the refusal of a
//! write concern in the connection string.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = @import("mongo-bson");
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// Answers each write with `write` and each findAndModify with `modify`.
const Replies = struct {
    write: bson.RawDocument,
    modify: bson.RawDocument,

    pub fn answer(r: *Replies, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        return .{ .reply = if (std.mem.eql(u8, request.name, "findAndModify")) r.modify else r.write };
    }
};

const acknowledged: Replies = .{
    .write = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }),
    .modify = bson.literal(.{ .lastErrorObject = .{ .n = 1, .updatedExisting = true }, .value = .{ ._id = 1, .n = 2 }, .ok = 1.0 }),
};

/// The commands of the ten writes, in the order `writeAll` makes them.
const commands = [_][]const u8{ "insert", "insert", "update", "update", "update", "delete", "delete", "findAndModify", "findAndModify", "findAndModify" };

/// Makes the ten writes of the collection API, each with `concern` in its
/// options.
fn writeAll(users: mongo.Collection, concern: ?mongo.WriteConcern) !void {
    const io = testing.io;
    const gpa = testing.allocator;
    const op: mongo.OperationContext = .of(.root);
    var one = try users.insertOne(io, op, .{ ._id = 1 }, .{ .allocator = gpa, .write_concern = concern });
    one.deinit(gpa);
    var many = try users.insertMany(io, op, .{.{ ._id = 2 }}, .{ .allocator = gpa, .write_concern = concern });
    many.deinit(gpa);
    var updated = try users.updateOne(io, op, .{ ._id = 1 }, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = gpa, .write_concern = concern });
    updated.deinit(gpa);
    var all = try users.updateMany(io, op, .{}, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = gpa, .write_concern = concern });
    all.deinit(gpa);
    var replaced = try users.replaceOne(io, op, .{ ._id = 2 }, .{ .n = 5 }, .{ .allocator = gpa, .write_concern = concern });
    replaced.deinit(gpa);
    var deleted = try users.deleteOne(io, op, .{ ._id = 2 }, .{ .allocator = gpa, .write_concern = concern });
    deleted.deinit(gpa);
    var cleared = try users.deleteMany(io, op, .{ .n = 5 }, .{ .allocator = gpa, .write_concern = concern });
    cleared.deinit(gpa);
    const raised = try users.findOneAndUpdate(io, op, .{ ._id = 1 }, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = gpa, .write_concern = concern });
    if (raised) |doc| doc.deinit();
    const swapped = try users.findOneAndReplace(io, op, .{ ._id = 1 }, .{ .n = 3 }, .{ .allocator = gpa, .write_concern = concern });
    if (swapped) |doc| doc.deinit();
    const dropped = try users.findOneAndDelete(io, op, .{ ._id = 1 }, .{ .allocator = gpa, .write_concern = concern });
    if (dropped) |doc| doc.deinit();
}

/// The ten commands of `writeAll` from entry `first` of the journal on
/// carry `expected` as their `writeConcern`, or none when it is null.
fn expectConcerns(script: *Script, first: usize, expected: ?bson.RawDocument) !void {
    const io = testing.io;
    try testing.expectEqual(first + commands.len, script.received(io));
    for (commands, first..) |name, i| {
        const entry = try script.entry(io, i);
        try testing.expectEqualStrings(name, entry.name);
        const sent = try entry.body.get("writeConcern");
        const wanted = expected orelse {
            if (sent != null) {
                std.debug.print("{s} sent a writeConcern, and none was asked for\n", .{name});
                return error.TestUnexpectedResult;
            }
            continue;
        };
        const concern = sent orelse {
            std.debug.print("{s} sent no writeConcern\n", .{name});
            return error.TestUnexpectedResult;
        };
        if (concern != .document) return error.TestUnexpectedResult;
        try testing.expectEqualSlices(u8, wanted.bytes, concern.document.bytes);
    }
}

test "write_concern null sends no writeConcern" {
    var replies = acknowledged;
    var served: Served = undefined;
    try served.start(testing.io, .init(&replies), .{});
    defer served.stop(testing.io);
    var ids: bson.ObjectId.Generator = .init(testing.io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    try writeAll(users, null);
    try expectConcerns(&served.script, 0, null);
    // Options that leave write_concern out send none either.
    var result = try users.insertOne(testing.io, .of(.root), .{ ._id = 9 }, .{ .allocator = testing.allocator });
    result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{ .insert = "users", .ordered = true, .@"$db" = "app" }).bytes, (try served.script.entry(testing.io, commands.len)).body.bytes);
}

test "journal sends w 1 and j true" {
    const io = testing.io;
    var replies = acknowledged;
    var served: Served = undefined;
    try served.start(io, .init(&replies), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    try writeAll(users, .{ .journal = true });
    try expectConcerns(&served.script, 0, bson.literal(.{ .w = 1, .j = true }));
    // It goes after the fields of the operation, before those the client
    // adds.
    try testing.expectEqualSlices(u8, bson.literal(.{
        .insert = "users",
        .writeConcern = .{ .w = 1, .j = true },
        .ordered = true,
        .@"$db" = "app",
    }).bytes, (try served.script.entry(io, 0)).body.bytes);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .findAndModify = "users",
        .query = .{ ._id = 1 },
        .update = .{ .@"$set" = .{ .n = 2 } },
        .writeConcern = .{ .w = 1, .j = true },
        .@"$db" = "app",
    }).bytes, (try served.script.entry(io, 7)).body.bytes);

    // With the other options of a write, it comes last of them.
    var result = try users.updateOne(io, .of(.root), .{ ._id = 1 }, .{ .@"$set" = .{ .n = 1 } }, .{
        .allocator = testing.allocator,
        .let = bson.literal(.{ .x = 1 }),
        .bypass_document_validation = true,
        .comment = .{ .string = "durable" },
        .write_concern = .{ .journal = true },
    });
    result.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, bson.literal(.{
        .update = "users",
        .let = .{ .x = 1 },
        .bypassDocumentValidation = true,
        .comment = "durable",
        .writeConcern = .{ .w = 1, .j = true },
        .ordered = true,
        .@"$db" = "app",
    }).bytes, (try served.script.entry(io, commands.len)).body.bytes);
}

test "majority sends w majority" {
    var replies = acknowledged;
    var served: Served = undefined;
    try served.start(testing.io, .init(&replies), .{});
    defer served.stop(testing.io);
    var ids: bson.ObjectId.Generator = .init(testing.io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");

    try writeAll(users, .{ .w = .majority });
    try expectConcerns(&served.script, 0, bson.literal(.{ .w = "majority" }));
    try writeAll(users, .{ .w = .majority, .journal = true });
    try expectConcerns(&served.script, commands.len, bson.literal(.{ .w = "majority", .j = true }));
    // j only with journal: the defaults send w 1 alone.
    try writeAll(users, .{});
    try expectConcerns(&served.script, 2 * commands.len, bson.literal(.{ .w = 1 }));
}

/// On a server that answers with `replies`, each of the ten writes fails
/// with `expected`, the code of the writeConcernError of its reply in its
/// diagnostics.
fn expectEachFails(replies: Replies, expected: mongo.Error, code: i32) !void {
    const io = testing.io;
    const gpa = testing.allocator;
    var answers = replies;
    var served: Served = undefined;
    try served.start(io, .init(&answers), .{});
    defer served.stop(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const users = mongo.Database.init(served.client(), "app", &ids).collection("users");
    const op: mongo.OperationContext = .of(.root);
    const concern: mongo.WriteConcern = .{ .journal = true };
    var d: mongo.Diagnostics = .{};
    try testing.expectError(expected, users.insertOne(io, op, .{ ._id = 1 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.insertMany(io, op, .{.{ ._id = 2 }}, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.updateOne(io, op, .{ ._id = 1 }, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.updateMany(io, op, .{}, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.replaceOne(io, op, .{ ._id = 2 }, .{ .n = 5 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.deleteOne(io, op, .{ ._id = 2 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.deleteMany(io, op, .{ .n = 5 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.findOneAndUpdate(io, op, .{ ._id = 1 }, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.findOneAndReplace(io, op, .{ ._id = 1 }, .{ .n = 3 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
    try testing.expectError(expected, users.findOneAndDelete(io, op, .{ ._id = 1 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }));
    try expectCode(&d, code);
}

fn expectCode(d: *const mongo.Diagnostics, code: i32) !void {
    const server = d.server orelse return error.TestNoServerError;
    try testing.expectEqual(code, server.code);
}

test "a writeConcernError in the reply of each operation is WriteFailed" {
    // The write ran, but its write concern failed: the server may have
    // run it, and the client says so.
    const failed = .{ .code = 64, .codeName = "WriteConcernTimeout", .errmsg = "waiting for replication timed out" };
    try expectEachFails(.{
        .write = bson.literal(.{ .n = 1, .nModified = 1, .writeConcernError = failed, .ok = 1.0 }),
        .modify = bson.literal(.{ .lastErrorObject = .{ .n = 1, .updatedExisting = true }, .value = .{ ._id = 1, .n = 2 }, .writeConcernError = failed, .ok = 1.0 }),
    }, error.WriteFailed, 64);
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(error.WriteFailed));

    // Code 50, MaxTimeMSExpired, there is Timeout, findAndModify's too.
    const expired = .{ .code = 50, .codeName = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" };
    try expectEachFails(.{
        .write = bson.literal(.{ .n = 1, .nModified = 1, .writeConcernError = expired, .ok = 1.0 }),
        .modify = bson.literal(.{ .lastErrorObject = .{ .n = 1, .updatedExisting = true }, .value = .{ ._id = 1, .n = 2 }, .writeConcernError = expired, .ok = 1.0 }),
    }, error.Timeout, 50);
}

test "w and journal in the connection string point to the options" {
    for ([_][]const u8{ "w=majority", "w=1", "journal=true", "wTimeoutMS=1000" }) |option| {
        var buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1/?{s}", .{option});
        var d: mongo.Diagnostics = .{};
        if (mongo.Client.init(testing.allocator, testing.io, .{ .uri = uri, .diagnostics = &d })) |made| {
            var client = made;
            client.deinit();
            std.debug.print("{s}: taken, expected Unsupported\n", .{uri});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.Unsupported, err);
        if (!std.mem.endsWith(u8, d.message(), ": put write_concern in the options of the operation")) {
            std.debug.print("{s}: {s}\n", .{ uri, d.message() });
            return error.TestUnexpectedResult;
        }
    }
}
