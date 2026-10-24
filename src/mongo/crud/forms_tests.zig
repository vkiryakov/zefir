//! Every one of the 25 operations of `mongo.Collection` and
//! `mongo.Database`, built and run with each form of its documents — a
//! `bson.RawDocument`, a `bson.OwnedDocument`, a struct and an anonymous
//! literal — and its lists as a slice, an array, a pointer to an array, a
//! tuple and a pointer to a tuple. Zig compiles only what is called, so an
//! error in a branch of an `anytype` that no test takes would show only
//! in the code of a user.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = @import("mongo-bson");
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// Answers every command of the operations as mongod does, at its
/// simplest: the batches of writes with their `n`, the cursors with one
/// document `{_id: 1, n: 1}` in a batch that ends them, findAndModify
/// with no document, and the rest with what their operations read.
const Server = struct {
    write: Script.Write = .{},

    fn handler(s: *Server) Script.Handler {
        return .init(s);
    }

    pub fn answer(s: *Server, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        const name = request.name;
        if (std.meta.stringToEnum(mongo.WriteKind, name) != null) return s.write.answer(io, arena, request);
        for ([_][]const u8{ "find", "aggregate", "listIndexes", "listCollections" }) |cursor| {
            if (std.mem.eql(u8, name, cursor)) return .{ .reply = one_document };
        }
        if (std.mem.eql(u8, name, "findAndModify")) return .{ .reply = bson.literal(.{ .value = null, .ok = 1.0 }) };
        if (std.mem.eql(u8, name, "count")) return .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) };
        if (std.mem.eql(u8, name, "distinct")) return .{ .reply = bson.literal(.{ .values = .{1}, .ok = 1.0 }) };
        return .{ .reply = Script.ok };
    }

    const one_document = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ ._id = 1, .n = 1 }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 });
};

const Fixture = struct {
    server: Server = .{},
    served: Served = undefined,
    /// The script of the server.
    script: *Script = undefined,
    ids: bson.ObjectId.Generator = .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) },

    /// Lives where it is: the server and the client point into it.
    fn init(f: *Fixture) !void {
        try f.served.start(testing.io, f.server.handler(), .{});
        f.script = &f.served.script;
    }

    fn deinit(f: *Fixture) void {
        f.served.stop(testing.io);
    }

    fn db(f: *Fixture) mongo.Database {
        return .init(f.served.client(), "app", &f.ids);
    }
};

/// `{key: {inner: n}}`, or `{key: n}` without `inner`, by `bson.Builder`.
fn built(key: []const u8, inner: ?[]const u8, n: i32) !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    if (inner) |field| {
        try b.beginDocument(key);
        try b.putInt32(field, n);
        try b.end();
    } else try b.putInt32(key, n);
    return b.finish();
}

const N = struct { n: i32 };
const SetN = struct { @"$set": N };
const Ping = struct { ping: i32 };
const Find = struct { find: []const u8 };

fn expectOne(cursor: mongo.Cursor) !void {
    defer cursor.deinit(testing.io);
    try testing.expect(try cursor.next(testing.io, .of(.root)) != null);
    try testing.expect(try cursor.next(testing.io, .of(.root)) == null);
}

test "the operations with a filter take it in each of the three forms" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.db().collection("users");
    const a = testing.allocator;
    const owned = try built("n", null, 1);
    defer owned.deinit();

    inline for (.{ bson.literal(.{ .n = 1 }), owned, N{ .n = 1 }, .{ .n = 1 } }) |filter| {
        var updated = try users.updateOne(io, .of(.root), filter, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = a });
        updated.deinit(a);
        var many = try users.updateMany(io, .of(.root), filter, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = a });
        many.deinit(a);
        var replaced = try users.replaceOne(io, .of(.root), filter, .{ .n = 3 }, .{ .allocator = a });
        replaced.deinit(a);
        var deleted = try users.deleteOne(io, .of(.root), filter, .{ .allocator = a });
        deleted.deinit(a);
        var all = try users.deleteMany(io, .of(.root), filter, .{ .allocator = a });
        all.deinit(a);
        try expectOne(try users.find(io, .of(.root), filter, .{ .allocator = a }));
        const first = (try users.findOne(io, .of(.root), filter, .{ .allocator = a })).?;
        first.deinit();
        try testing.expect(try users.findOneAndUpdate(io, .of(.root), filter, .{ .@"$set" = .{ .n = 2 } }, .{ .allocator = a }) == null);
        try testing.expect(try users.findOneAndReplace(io, .of(.root), filter, .{ .n = 3 }, .{ .allocator = a }) == null);
        try testing.expect(try users.findOneAndDelete(io, .of(.root), filter, .{ .allocator = a }) == null);
        try testing.expectEqual(@as(u64, 1), try users.countDocuments(io, .of(.root), filter, .{ .allocator = a }));
        const values = try users.distinct(io, .of(.root), "n", filter, .{ .allocator = a });
        values.deinit();
    }
    try testing.expectEqual(@as(usize, 4 * 12), f.script.received(io));
}

test "an update, a replacement and a document to insert take each of the three forms" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.db().collection("users");
    const a = testing.allocator;
    const set = try built("$set", "n", 2);
    defer set.deinit();
    const doc = try built("n", null, 3);
    defer doc.deinit();

    inline for (.{ bson.literal(.{ .@"$set" = .{ .n = 2 } }), set, SetN{ .@"$set" = .{ .n = 2 } }, .{ .@"$set" = .{ .n = 2 } } }) |update| {
        var one = try users.updateOne(io, .of(.root), .{}, update, .{ .allocator = a });
        one.deinit(a);
        var many = try users.updateMany(io, .of(.root), .{}, update, .{ .allocator = a });
        many.deinit(a);
        try testing.expect(try users.findOneAndUpdate(io, .of(.root), .{}, update, .{ .allocator = a }) == null);
    }
    inline for (.{ bson.literal(.{ .n = 3 }), doc, N{ .n = 3 }, .{ .n = 3 } }) |replacement| {
        var replaced = try users.replaceOne(io, .of(.root), .{}, replacement, .{ .allocator = a });
        replaced.deinit(a);
        try testing.expect(try users.findOneAndReplace(io, .of(.root), .{}, replacement, .{ .allocator = a }) == null);
        var inserted = try users.insertOne(io, .of(.root), replacement, .{ .allocator = a });
        inserted.deinit(a);
    }
    try testing.expectEqual(@as(usize, 4 * 3 + 4 * 3), f.script.received(io));
}

test "the lists of documents, of stages and of updates take a slice, an array, a pointer to one, a tuple and a pointer to one" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const users = f.db().collection("users");
    const a = testing.allocator;
    const owned_doc = try built("n", null, 1);
    defer owned_doc.deinit();
    const owned_stage = try built("$set", "n", 2);
    defer owned_stage.deinit();

    const raw_docs = [_]bson.RawDocument{ bson.literal(.{ .n = 1 }), bson.literal(.{ .n = 2 }) };
    const struct_docs = [_]N{ .{ .n = 1 }, .{ .n = 2 } };
    const tuple_docs = .{ owned_doc, .{ .n = 2 } };
    inline for (.{
        @as([]const bson.RawDocument, &raw_docs),
        @as([]const N, &struct_docs),
        struct_docs,
        &struct_docs,
        .{ bson.literal(.{ .n = 1 }), owned_doc, N{ .n = 3 }, .{ .n = 4 } },
        &tuple_docs,
    }) |docs| {
        var result = try users.insertMany(io, .of(.root), docs, .{ .allocator = a });
        defer result.deinit(a);
        try testing.expect(result.inserted_ids.len >= 2);
    }

    const raw_stages = [_]bson.RawDocument{ bson.literal(.{ .@"$set" = .{ .n = 2 } }), bson.literal(.{ .@"$unset" = "x" }) };
    const struct_stages = [_]SetN{ .{ .@"$set" = .{ .n = 2 } }, .{ .@"$set" = .{ .n = 3 } } };
    const tuple_stages = .{ owned_stage, .{ .@"$unset" = "x" } };
    inline for (.{
        @as([]const bson.RawDocument, &raw_stages),
        @as([]const SetN, &struct_stages),
        struct_stages,
        &struct_stages,
        .{ bson.literal(.{ .@"$set" = .{ .n = 2 } }), owned_stage, SetN{ .@"$set" = .{ .n = 3 } }, .{ .@"$unset" = "x" } },
        &tuple_stages,
    }) |pipeline| {
        try expectOne(try users.aggregate(io, .of(.root), pipeline, .{ .allocator = a }));
        var one = try users.updateOne(io, .of(.root), .{}, pipeline, .{ .allocator = a });
        one.deinit(a);
        var many = try users.updateMany(io, .of(.root), .{}, pipeline, .{ .allocator = a });
        many.deinit(a);
        try testing.expect(try users.findOneAndUpdate(io, .of(.root), .{}, pipeline, .{ .allocator = a }) == null);
    }

    // .{} is the empty list: a pipeline without stages, and an insert of
    // nothing, which is refused.
    try expectOne(try users.aggregate(io, .of(.root), .{}, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), .{}, .{ .allocator = a }));
    try testing.expectError(error.InvalidArgument, users.insertMany(io, .of(.root), @as([]const N, &.{}), .{ .allocator = a }));
    try testing.expectEqual(@as(usize, 6 + 6 * 4 + 1), f.script.received(io));
}

test "the commands of runCommand and runCursorCommand take each of the three forms" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const db = f.db();
    const a = testing.allocator;
    var b: bson.Builder = .init(a);
    try b.putString("find", "users");
    const find = try b.finish();
    defer find.deinit();
    const ping = try built("ping", null, 1);
    defer ping.deinit();

    inline for (.{ bson.literal(.{ .ping = 1 }), ping, Ping{ .ping = 1 }, .{ .ping = 1 } }) |command| {
        const reply = try db.runCommand(io, .of(.root), command, .{ .allocator = a });
        reply.deinit();
    }
    inline for (.{ bson.literal(.{ .find = "users" }), find, Find{ .find = "users" }, .{ .find = "users" } }) |command| {
        try expectOne(try db.runCursorCommand(io, .of(.root), command, .{ .allocator = a }));
    }
    try testing.expectEqual(@as(usize, 8), f.script.received(io));
}

test "the operations without documents of their own" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const db = f.db();
    const users = db.collection("users");
    const a = testing.allocator;

    try testing.expectEqual(@as(u64, 1), try users.estimatedDocumentCount(io, .of(.root), .{ .allocator = a }));
    const names = try users.createIndexes(io, .of(.root), &.{.{ .keys = bson.literal(.{ .n = 1 }) }}, .{ .allocator = a });
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    try testing.expectEqualStrings("n_1", names[0]);
    try expectOne(try users.listIndexes(io, .of(.root), .{ .allocator = a }));
    try users.dropIndex(io, .of(.root), "n_1", .{ .allocator = a });
    try users.dropIndexes(io, .of(.root), .{ .allocator = a });
    try users.drop(io, .of(.root), .{ .allocator = a });
    try expectOne(try db.listCollections(io, .of(.root), .{ .allocator = a }));
    try db.drop(io, .of(.root), .{ .allocator = a });
    try testing.expectEqual(@as(usize, 8), f.script.received(io));
}
