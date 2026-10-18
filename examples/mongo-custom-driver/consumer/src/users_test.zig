//! The tests of the application in users.zig: the same steps on two
//! drivers. On `mongo.testing.FakeDriver` the script answers as mongod
//! does and the journal shows what went out; with `-Dlive-uri`, they run
//! on minidriver against that mongod.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("zefir-core");
const mongo = @import("zefir-mongo");
const minidriver = @import("mongo-minidriver");
const build_options = @import("build_options");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Users = @import("users.zig").Users;

/// What the application does, step by step, and what it must get.
fn exercise(io: Io, db: mongo.Database) !void {
    const gpa = testing.allocator;
    const op: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(30))));
    const users: Users = .init(db);
    try users.setUp(io, op, gpa);
    _ = try users.register(io, op, gpa, .{ .email = "ann@example.com", .name = "Ann", .age = 30 });
    try testing.expectError(error.EmailTaken, users.register(io, op, gpa, .{ .email = "ann@example.com", .name = "Another Ann", .age = 31 }));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ann = (try users.byEmail(io, op, arena.allocator(), "ann@example.com")) orelse return error.TestUserNotFound;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expectEqual(@as(i32, 30), ann.age);
    try testing.expect(ann._id != null);

    try testing.expect(try users.rename(io, op, gpa, "ann@example.com", "Ann Lee"));
    const renamed = (try users.byEmail(io, op, arena.allocator(), "ann@example.com")) orelse return error.TestUserNotFound;
    try testing.expectEqualStrings("Ann Lee", renamed.name);
    try testing.expect(!try users.rename(io, op, gpa, "nobody@example.com", "Nobody"));

    try testing.expectEqual(@as(u64, 1), try users.count(io, op, gpa));
    try testing.expect(try users.remove(io, op, gpa, "ann@example.com"));
    try testing.expect(!try users.remove(io, op, gpa, "ann@example.com"));
    try testing.expectEqual(@as(u64, 0), try users.count(io, op, gpa));
}

const ann_id: bson.ObjectId = .{ .bytes = .{ 0x65, 0x2f, 0x1a, 0x00, 1, 2, 3, 4, 5, 0, 0, 1 } };

/// The reply of a find that finds Ann under `name`.
fn found(comptime name: []const u8) bson.RawDocument {
    return bson.literal(.{
        .cursor = .{ .firstBatch = .{.{ ._id = ann_id, .email = "ann@example.com", .name = name, .age = 30 }}, .id = @as(i64, 0), .ns = "app.users" },
        .ok = 1.0,
    });
}

/// What mongod answers to the steps of `exercise`, in their order.
const answers = [_]Script.Answer{
    .{ .reply = bson.literal(.{ .numIndexesBefore = 1, .numIndexesAfter = 2, .createdCollectionAutomatically = true, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{
        .n = 0,
        .writeErrors = .{.{ .index = 0, .code = 11000, .errmsg = "E11000 duplicate key error collection: app.users index: email_1 dup key: { email: \"ann@example.com\" }" }},
        .ok = 1.0,
    }) },
    .{ .reply = found("Ann") },
    .{ .reply = bson.literal(.{ .n = 1, .nModified = 1, .ok = 1.0 }) },
    .{ .reply = found("Ann Lee") },
    .{ .reply = bson.literal(.{ .n = 0, .nModified = 0, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{ .cursor = .{ .firstBatch = .{.{ ._id = 1, .n = 1 }}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{ .n = 0, .ok = 1.0 }) },
    .{ .reply = bson.literal(.{ .cursor = .{ .firstBatch = [0]i32{}, .id = @as(i64, 0), .ns = "app.users" }, .ok = 1.0 }) },
};

/// Fails unless the field `key` of `got` is that of `expected`, byte for
/// byte.
fn expectField(expected: bson.RawDocument, got: bson.RawDocument, key: []const u8) !void {
    const want = (try expected.get(key)) orelse return error.TestNoField;
    const have = (try got.get(key)) orelse {
        std.debug.print("{f} has no {s}\n", .{ got, key });
        return error.TestNoField;
    };
    const want_bytes = switch (want) {
        .document, .array => |doc| doc.bytes,
        else => return error.TestNotADocument,
    };
    const have_bytes = switch (have) {
        .document, .array => |doc| doc.bytes,
        else => return error.TestNotADocument,
    };
    if (!std.mem.eql(u8, want_bytes, have_bytes)) {
        std.debug.print("{s} of {f} is not that of {f}\n", .{ key, got, expected });
        return error.TestUnexpectedField;
    }
}

test "the application on FakeDriver: what it sends, and what it makes of mongod's answers" {
    const io = testing.io;
    var queue: Script.Queue = .{ .answers = &answers };
    var script: Script = .init(testing.allocator, queue.handler());
    defer script.deinit();
    var fake: mongo.testing.FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    try exercise(io, .init(fake.client(), "app", &ids));
    try testing.expectEqual(@as(usize, 0), queue.left());

    // The unique index on email.
    const index = script.entry(io, 0);
    try testing.expectEqualStrings("createIndexes", index.name);
    try expectField(bson.literal(.{ .indexes = .{.{ .key = .{ .email = 1 }, .name = "email_1", .unique = true }} }), index.body, "indexes");
    // The new user, with the _id the insert made first.
    const insert = script.entry(io, 1);
    var documents = insert.sequence.?.documents();
    const user = documents.next().?;
    const first = (try user.first()).?;
    try testing.expectEqualStrings("_id", first.key);
    try testing.expect(first.value == .object_id);
    try testing.expectEqualStrings("ann@example.com", (try user.get("email")).?.string);
    // A user found by email, one at most.
    const find = script.entry(io, 3);
    try testing.expectEqualStrings("find", find.name);
    try expectField(bson.literal(.{ .filter = .{ .email = "ann@example.com" } }), find.body, "filter");
    try testing.expectEqual(@as(i64, 1), try (try find.body.get("limit")).?.asI64());
}

test "the application on minidriver against the live mongod" {
    const uri = build_options.live_uri orelse return error.SkipZigTest;
    const io = testing.io;
    var driver: minidriver.Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer driver.deinit();
    try driver.connect(io, .root);
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(driver.client(), "zefir_minidriver_users", &ids);
    const op: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(30))));
    try db.drop(io, op, .{ .allocator = testing.allocator });
    defer db.drop(io, op, .{ .allocator = testing.allocator }) catch {};
    try exercise(io, db);
}
