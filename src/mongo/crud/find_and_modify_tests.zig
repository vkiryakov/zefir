//! Tests of `findOneAndUpdate`, `findOneAndReplace` and
//! `findOneAndDelete` on the client against `mongo.testing.FakeServer`:
//! the exact `findAndModify` commands in the script's journal, and their
//! `value`.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("../tests/Served.zig");

/// A script that answers each command with `reply`, and the client on it.
const Fixture = struct {
    replies: [16]Script.Answer = undefined,
    queue: Script.Queue = undefined,
    served: Served = undefined,
    /// The script of the server.
    script: *Script = undefined,
    ids: bson.ObjectId.Generator = .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) },

    /// Lives where it is: the server and the client point into it.
    fn init(f: *Fixture, reply: bson.RawDocument) !void {
        f.answerWith(reply);
        f.queue = .{ .answers = &f.replies };
        try f.served.start(testing.io, f.queue.handler(), .{});
        f.script = &f.served.script;
    }

    fn answerWith(f: *Fixture, reply: bson.RawDocument) void {
        for (&f.replies) |*answer| answer.* = .{ .reply = reply };
    }

    fn deinit(f: *Fixture) void {
        f.served.stop(testing.io);
    }

    fn users(f: *Fixture) mongo.Collection {
        return mongo.Database.init(f.served.client(), "app", &f.ids).collection("users");
    }
};

const found = bson.literal(.{
    .lastErrorObject = .{ .n = 1, .updatedExisting = true },
    .value = .{ ._id = 1, .n = 2 },
    .ok = 1.0,
});

fn expectValue(expected: bson.RawDocument, got: ?bson.OwnedDocument) !void {
    const doc = got orelse return error.TestNoDocument;
    defer doc.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, doc.bytes);
}

test "findOneAndUpdate sends findAndModify with query and update, and returns a copy of value, in each of the three forms" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(found);
    defer f.deinit();
    const users = f.users();

    var b: bson.Builder = .init(testing.allocator);
    try b.beginDocument("$inc");
    try b.putInt32("n", 1);
    try b.end();
    const built = try b.finish();
    defer built.deinit();
    const Filter = struct { _id: i32 };
    inline for (.{
        .{ bson.literal(.{ ._id = 1 }), bson.literal(.{ .@"$inc" = .{ .n = 1 } }) },
        .{ Filter{ ._id = 1 }, built },
        .{ .{ ._id = 1 }, .{ .@"$inc" = .{ .n = 1 } } },
    }, 0..) |args, i| {
        try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try users.findOneAndUpdate(io, .of(.root), args[0], args[1], .{ .allocator = testing.allocator }));
        const entry = f.script.entry(io, i);
        try testing.expectEqualStrings("findAndModify", entry.name);
        try testing.expect(entry.sequence == null);
        try testing.expectEqualSlices(u8, bson.literal(.{
            .findAndModify = "users",
            .query = .{ ._id = 1 },
            .update = .{ .@"$inc" = .{ .n = 1 } },
            .@"$db" = "app",
        }).bytes, entry.body.bytes);
    }
}

test "the options of findOneAndUpdate: return_document after is new: true, projection is fields" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(found);
    defer f.deinit();
    try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try f.users().findOneAndUpdate(io, .of(.root), .{ .n = .{ .@"$gte" = 1 } }, .{ .@"$set" = .{ .@"tags.$[t]" = "x" } }, .{
        .allocator = testing.allocator,
        .sort = bson.literal(.{ .n = -1 }),
        .projection = bson.literal(.{ .n = 1 }),
        .upsert = true,
        .return_document = .after,
        .array_filters = &.{bson.literal(.{ .t = "y" })},
        .collation = bson.literal(.{ .locale = "fr" }),
        .hint = .{ .name = "n_1" },
        .let = bson.literal(.{ .x = 1 }),
        .bypass_document_validation = true,
        .comment = .{ .string = "tag it" },
    }));
    try testing.expectEqualSlices(u8, bson.literal(.{
        .findAndModify = "users",
        .query = .{ .n = .{ .@"$gte" = 1 } },
        .sort = .{ .n = -1 },
        .update = .{ .@"$set" = .{ .@"tags.$[t]" = "x" } },
        .new = true,
        .fields = .{ .n = 1 },
        .upsert = true,
        .bypassDocumentValidation = true,
        .arrayFilters = .{.{ .t = "y" }},
        .collation = .{ .locale = "fr" },
        .hint = "n_1",
        .let = .{ .x = 1 },
        .comment = "tag it",
        .@"$db" = "app",
    }).bytes, f.script.entry(io, 0).body.bytes);

    // The defaults go out not at all; a pipeline goes as an array.
    try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try f.users().findOneAndUpdate(io, .of(.root), .{}, .{.{ .@"$set" = .{ .n = 3 } }}, .{
        .allocator = testing.allocator,
        .upsert = false,
        .return_document = .before,
        .bypass_document_validation = false,
    }));
    try testing.expectEqualSlices(u8, bson.literal(.{
        .findAndModify = "users",
        .query = .{},
        .update = .{.{ .@"$set" = .{ .n = 3 } }},
        .@"$db" = "app",
    }).bytes, f.script.entry(io, 1).body.bytes);
}

test "findOneAndReplace sends the replacement as update, and refuses one that starts with an operator" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(found);
    defer f.deinit();
    const users = f.users();
    try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try users.findOneAndReplace(io, .of(.root), .{ ._id = 1 }, .{ .n = 5 }, .{
        .allocator = testing.allocator,
        .return_document = .after,
        .hint = .{ .keys = bson.literal(.{ ._id = 1 }) },
    }));
    try testing.expectEqualSlices(u8, bson.literal(.{
        .findAndModify = "users",
        .query = .{ ._id = 1 },
        .update = .{ .n = 5 },
        .new = true,
        .hint = .{ ._id = 1 },
        .@"$db" = "app",
    }).bytes, f.script.entry(io, 0).body.bytes);

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, users.findOneAndReplace(io, .of(.root), .{ ._id = 1 }, .{ .@"$set" = .{ .n = 5 } }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the replacement starts with the update operator '$set': to change fields of the document, use updateOne", d.message());
    try testing.expectError(error.InvalidArgument, users.findOneAndUpdate(io, .of(.root), .{ ._id = 1 }, .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the update is empty: it starts with an update operator, such as $set, or it is a pipeline", d.message());
    try testing.expectError(error.InvalidArgument, users.findOneAndUpdate(io, .of(.root), .{ ._id = 1 }, .{ .n = 5 }, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(usize, 1), f.script.received(io));
}

test "findOneAndDelete sends remove: true, with its sort and projection" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(found);
    defer f.deinit();
    try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try f.users().findOneAndDelete(io, .of(.root), .{ .n = 2 }, .{
        .allocator = testing.allocator,
        .sort = bson.literal(.{ ._id = 1 }),
        .projection = bson.literal(.{ ._id = 1, .n = 1 }),
        .collation = bson.literal(.{ .locale = "en" }),
        .let = bson.literal(.{ .y = 2 }),
        .comment = .{ .int32 = 7 },
    }));
    try testing.expectEqualSlices(u8, bson.literal(.{
        .findAndModify = "users",
        .query = .{ .n = 2 },
        .sort = .{ ._id = 1 },
        .remove = true,
        .fields = .{ ._id = 1, .n = 1 },
        .collation = .{ .locale = "en" },
        .let = .{ .y = 2 },
        .comment = 7,
        .@"$db" = "app",
    }).bytes, f.script.entry(io, 0).body.bytes);
    try expectValue(bson.literal(.{ ._id = 1, .n = 2 }), try f.users().findOneAndDelete(io, .of(.root), .{}, .{ .allocator = testing.allocator }));
    try testing.expectEqualSlices(u8, bson.literal(.{ .findAndModify = "users", .query = .{}, .remove = true, .@"$db" = "app" }).bytes, f.script.entry(io, 1).body.bytes);
}

test "value null is a null result; a reply without value is a protocol violation" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(bson.literal(.{ .lastErrorObject = .{ .n = 0, .updatedExisting = false }, .value = null, .ok = 1.0 }));
    defer f.deinit();
    const users = f.users();
    try testing.expect(try users.findOneAndUpdate(io, .of(.root), .{ ._id = 9 }, .{ .@"$set" = .{ .n = 1 } }, .{ .allocator = testing.allocator }) == null);
    try testing.expect(try users.findOneAndReplace(io, .of(.root), .{ ._id = 9 }, .{ .n = 1 }, .{ .allocator = testing.allocator }) == null);
    try testing.expect(try users.findOneAndDelete(io, .of(.root), .{ ._id = 9 }, .{ .allocator = testing.allocator }) == null);

    var d: mongo.Diagnostics = .{};
    f.answerWith(bson.literal(.{ .ok = 1.0 }));
    try testing.expectError(error.ProtocolViolation, users.findOneAndDelete(io, .of(.root), .{ ._id = 9 }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of findAndModify holds no value; the command may have run", d.message());
    f.answerWith(bson.literal(.{ .value = "Ann", .ok = 1.0 }));
    try testing.expectError(error.ProtocolViolation, users.findOneAndDelete(io, .of(.root), .{ ._id = 9 }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the value in the reply of findAndModify is neither a document nor null", d.message());
}

test "ok 0 is CommandFailed, with the reply in failure_reply" {
    const io = testing.io;
    const refused = bson.literal(.{ .ok = 0.0, .errmsg = "E11000 duplicate key error", .code = 11000, .codeName = "DuplicateKey" });
    var f: Fixture = .{};
    try f.init(refused);
    defer f.deinit();
    var d: mongo.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    try testing.expectError(error.CommandFailed, f.users().findOneAndUpdate(io, .of(.root), .{ ._id = 1 }, .{ .@"$set" = .{ .email = "x" } }, .{
        .allocator = testing.allocator,
        .diagnostics = &d,
        .failure_reply = &failure,
    }));
    defer failure.?.deinit();
    try testing.expectEqualSlices(u8, refused.bytes, failure.?.bytes);
    try testing.expectEqual(@as(i32, 11000), d.server.?.code);
    try testing.expectEqualStrings("E11000 duplicate key error", d.message());
}

test "a bad collection name or filter is InvalidArgument, and nothing is sent" {
    const io = testing.io;
    var f: Fixture = .{};
    try f.init(found);
    defer f.deinit();
    const db: mongo.Database = .init(f.served.client(), "app", &f.ids);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, db.collection("").findOneAndDelete(io, .of(.root), .{}, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    const bad: []const u8 = "\xff";
    try testing.expectError(error.InvalidArgument, db.collection("users").findOneAndDelete(io, .of(.root), .{ .name = bad }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the filter cannot be written as BSON"));
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, db.collection("users").findOneAndUpdate(io, .of(.root), .{}, .{ .@"$set" = .{ .a = 1 } }, .{ .allocator = testing.allocator, .sort = broken, .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the sort cannot be written as BSON"));
    try testing.expectEqual(@as(usize, 0), f.script.received(io));
}
