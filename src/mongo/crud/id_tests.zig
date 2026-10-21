//! Tests of the `_id` that inserts give documents: the bytes that go out.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = @import("mongo-bson");
const id = @import("id.zig");
const results = @import("../results.zig");

/// A generator whose ids differ only in their seconds and counters.
fn generator() bson.ObjectId.Generator {
    return .{ .random = .{ 1, 2, 3, 4, 5 }, .counter = .init(0) };
}

/// The ObjectId of the first element of `doc`, which must be `_id`.
fn firstId(doc: bson.RawDocument) !bson.ObjectId {
    const first = (try doc.first()) orelse return error.TestEmptyDocument;
    try testing.expectEqualStrings("_id", first.key);
    return first.value.object_id;
}

test "a document with an _id of its own at the top level goes as it is, wherever the _id stands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids = generator();

    const raw = bson.literal(.{ .name = "Ann", .tags = .{"a"}, ._id = 7 });
    try testing.expectEqual(raw.bytes.ptr, (try id.withId(a, testing.io, &ids, raw)).bytes.ptr);
    var b: bson.Builder = .init(testing.allocator);
    try b.putString("name", "Ann");
    try b.putInt32("_id", 7);
    const built = try b.finish();
    defer built.deinit();
    try testing.expectEqual(built.bytes.ptr, (try id.withId(a, testing.io, &ids, built)).bytes.ptr);

    const User = struct { name: []const u8, _id: i32, age: i32 };
    const user = try id.withId(a, testing.io, &ids, User{ .name = "Ann", ._id = 7, .age = 30 });
    try testing.expectEqualSlices(u8, bson.literal(.{ .name = "Ann", ._id = 7, .age = 30 }).bytes, user.bytes);
    const Maybe = struct { name: []const u8, _id: ?[]const u8 = null };
    const named = try id.withId(a, testing.io, &ids, Maybe{ .name = "Ann", ._id = "ann" });
    try testing.expectEqualSlices(u8, bson.literal(.{ .name = "Ann", ._id = "ann" }).bytes, named.bytes);
    const literal = try id.withId(a, testing.io, &ids, .{ .name = "Ann", ._id = .{ .day = 1 } });
    try testing.expectEqualSlices(u8, bson.literal(.{ .name = "Ann", ._id = .{ .day = 1 } }).bytes, literal.bytes);
    // Not one id was made.
    try testing.expectEqual(@as(u32, 0), ids.counter.load(.monotonic));
}

test "a RawDocument or an OwnedDocument without _id is copied with an ObjectId of the generator first; the caller's bytes stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids = generator();

    // A nested _id is not the document's.
    const raw = bson.literal(.{ .name = "Ann", .owner = .{ ._id = 1 } });
    const before = try testing.allocator.dupe(u8, raw.bytes);
    defer testing.allocator.free(before);
    const sent = try id.withId(a, testing.io, &ids, raw);
    try testing.expect(sent.bytes.ptr != raw.bytes.ptr);
    try testing.expectEqualSlices(u8, before, raw.bytes);
    const made = try firstId(sent);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, made.bytes[4..9]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, made.bytes[9..12]);
    const expected = try bson.encode(testing.allocator, .{ ._id = made, .name = "Ann", .owner = .{ ._id = 1 } }, .{});
    defer expected.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, sent.bytes);
    try sent.validate();

    var b: bson.Builder = .init(testing.allocator);
    try b.putString("name", "Bob");
    const built = try b.finish();
    defer built.deinit();
    const second = try id.withId(a, testing.io, &ids, built);
    const next = try firstId(second);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1 }, next.bytes[9..12]);
    const bob = try bson.encode(testing.allocator, .{ ._id = next, .name = "Bob" }, .{});
    defer bob.deinit();
    try testing.expectEqualSlices(u8, bob.bytes, second.bytes);
}

test "the elements of a RawDocument are copied as they are, of deprecated types too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ids = generator();
    const symbol: bson.RawDocument = try .init(bson.testing.vectors.named("symbol"));
    const sent = try id.withId(arena.allocator(), testing.io, &ids, symbol);
    _ = try firstId(sent);
    try testing.expectEqualSlices(u8, symbol.bytes[4..], sent.bytes[21..]);
    try testing.expectEqual(@as(usize, symbol.bytes.len + 17), sent.bytes.len);
    try testing.expectEqualStrings("s", (try sent.get("a")).?.symbol);
}

test "a struct without _id, or with an _id of null, is written with an ObjectId first, and no BSON null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ids = generator();

    const Plain = struct { name: []const u8, age: i32 };
    const plain = try id.withId(a, testing.io, &ids, Plain{ .name = "Ann", .age = 30 });
    const first = try firstId(plain);
    const ann = try bson.encode(testing.allocator, .{ ._id = first, .name = "Ann", .age = 30 }, .{});
    defer ann.deinit();
    try testing.expectEqualSlices(u8, ann.bytes, plain.bytes);

    // The _id of null stands last in the struct: the made one goes first,
    // and the field is not written.
    const User = struct { name: []const u8, _id: ?bson.ObjectId = null };
    const user = try id.withId(a, testing.io, &ids, User{ .name = "Bob" });
    const second = try firstId(user);
    const bob = try bson.encode(testing.allocator, .{ ._id = second, .name = "Bob" }, .{});
    defer bob.deinit();
    try testing.expectEqualSlices(u8, bob.bytes, user.bytes);

    const literal = try id.withId(a, testing.io, &ids, .{ ._id = null, .name = "Cid" });
    const third = try firstId(literal);
    const cid = try bson.encode(testing.allocator, .{ ._id = third, .name = "Cid" }, .{});
    defer cid.deinit();
    try testing.expectEqualSlices(u8, cid.bytes, literal.bytes);

    // .{} is the empty document: it gets an _id alone.
    const empty = try id.withId(a, testing.io, &ids, .{});
    const fourth = try firstId(empty);
    const alone = try bson.encode(testing.allocator, .{ ._id = fourth }, .{});
    defer alone.deinit();
    try testing.expectEqualSlices(u8, alone.bytes, empty.bytes);

    // Each insert of a document without _id takes the next count.
    for ([_]bson.ObjectId{ first, second, third, fourth }, 0..) |made, i| {
        try testing.expectEqual(@as(u24, @intCast(i)), std.mem.readInt(u24, made.bytes[9..12], .big));
    }
}

test "an _id that is BSON null of its own goes as it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ids = generator();
    const Doc = struct { _id: bson.Value, name: []const u8 };
    const sent = try id.withId(arena.allocator(), testing.io, &ids, Doc{ ._id = .null, .name = "Ann" });
    try testing.expectEqualSlices(u8, bson.literal(.{ ._id = null, .name = "Ann" }).bytes, sent.bytes);
}

test "the _id of a document as the result reports it, copied" {
    const doc = bson.literal(.{ .name = "Ann", ._id = "ann" });
    const value = try id.idOf(testing.allocator, doc);
    defer results.freeValue(testing.allocator, value);
    try testing.expectEqualStrings("ann", value.string);
    try testing.expect(value.string.ptr != (try doc.get("_id")).?.string.ptr);
}
