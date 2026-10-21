//! Tests of the documents of the collection API: the three forms of a
//! document, and the lists of them.

const std = @import("std");
const testing = std.testing;
const mongo = @import("../root.zig");
const bson = @import("mongo-bson");
const document = @import("document.zig");

const User = struct { name: []const u8, age: i32 };

fn annByBuilder() !bson.OwnedDocument {
    var b: bson.Builder = .init(testing.allocator);
    errdefer b.deinit();
    try b.putString("name", "Ann");
    try b.putInt32("age", 30);
    return b.finish();
}

test "a RawDocument and an OwnedDocument go as they are, a struct and a literal as the codec writes them, and .{} is {}" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ann = bson.literal(.{ .name = "Ann", .age = 30 });

    // Borrowed, not copied.
    try testing.expectEqual(ann.bytes.ptr, (try document.encode(a, ann)).bytes.ptr);
    const built = try annByBuilder();
    defer built.deinit();
    try testing.expectEqual(built.bytes.ptr, (try document.encode(a, built)).bytes.ptr);

    try testing.expectEqualSlices(u8, ann.bytes, (try document.encode(a, User{ .name = "Ann", .age = 30 })).bytes);
    try testing.expectEqualSlices(u8, ann.bytes, (try document.encode(a, .{ .name = "Ann", .age = 30 })).bytes);
    try testing.expectEqualSlices(u8, bson.RawDocument.empty.bytes, (try document.encode(a, .{})).bytes);
}

test "a null in a filter is BSON null, never a field left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const email: ?[]const u8 = null;
    const filter = try document.encode(arena.allocator(), .{ .email = email });
    try testing.expectEqualSlices(u8, bson.literal(.{ .email = null }).bytes, filter.bytes);
}

test "a document the codec cannot write is InvalidBson" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidBson, document.encode(arena.allocator(), .{ .name = @as([]const u8, "\xff") }));
}

test "which types are documents and which are lists" {
    try testing.expectEqual(document.Kind.document, document.kind(bson.RawDocument));
    try testing.expectEqual(document.Kind.document, document.kind(bson.OwnedDocument));
    try testing.expectEqual(document.Kind.document, document.kind(User));
    try testing.expectEqual(document.Kind.document, document.kind(@TypeOf(.{ .name = "Ann" })));
    // .{} is the empty document, and the empty list only where a list goes.
    try testing.expectEqual(document.Kind.document, document.kind(@TypeOf(.{})));
    try testing.expect(document.isEmptyTuple(@TypeOf(.{})));

    try testing.expectEqual(document.Kind.list, document.kind([]const bson.RawDocument));
    try testing.expectEqual(document.Kind.list, document.kind([]const User));
    try testing.expectEqual(document.Kind.list, document.kind([2]User));
    try testing.expectEqual(document.Kind.list, document.kind(*const [2]User));
    try testing.expectEqual(document.Kind.list, document.kind(@TypeOf(.{ .{ .a = 1 }, User{ .name = "Ann", .age = 30 } })));
    try testing.expectEqual(document.Kind.list, document.kind(@TypeOf(&.{ .{ .a = 1 }, .{ .b = 2 } })));
    try testing.expectEqual(document.Kind.list, document.kind(@TypeOf(&.{})));

    try testing.expectEqual(document.Kind.other, document.kind(u32));
    try testing.expectEqual(document.Kind.other, document.kind([]const u8));
    try testing.expectEqual(document.Kind.other, document.kind(*const User));
    try testing.expectEqual(document.Kind.other, document.kind(bson.Value));
}

/// Maps an item to its document as it is: `context` is the arena.
fn same(arena: std.mem.Allocator, _: usize, value: anytype) !bson.RawDocument {
    return document.encode(arena, value);
}

test "a slice, an array and a tuple are lists whose items take any of the three forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ann = bson.literal(.{ .name = "Ann", .age = 30 });
    const bob = bson.literal(.{ .name = "Bob", .age = 40 });
    const built = try annByBuilder();
    defer built.deinit();

    const raws = [_]bson.RawDocument{ ann, bob };
    const from_slice = try document.mapItems(a, @as([]const bson.RawDocument, &raws), a, same);
    const users = [_]User{ .{ .name = "Ann", .age = 30 }, .{ .name = "Bob", .age = 40 } };
    const from_array = try document.mapItems(a, users, a, same);
    const from_pointer = try document.mapItems(a, &users, a, same);
    const from_tuple = try document.mapItems(a, .{ built, .{ .name = "Bob", .age = 40 } }, a, same);
    const from_pointer_to_tuple = try document.mapItems(a, &.{ ann, User{ .name = "Bob", .age = 40 } }, a, same);
    for ([_][]const bson.RawDocument{ from_slice, from_array, from_pointer, from_tuple, from_pointer_to_tuple }) |items| {
        try testing.expectEqual(@as(usize, 2), items.len);
        try testing.expectEqualSlices(u8, ann.bytes, items[0].bytes);
        try testing.expectEqualSlices(u8, bob.bytes, items[1].bytes);
    }

    try testing.expectEqual(@as(usize, 0), (try document.mapItems(a, .{}, a, same)).len);
    try testing.expectEqual(@as(usize, 0), (try document.mapItems(a, &.{}, a, same)).len);
    try testing.expectEqual(@as(usize, 0), (try document.mapItems(a, @as([]const User, &.{}), a, same)).len);
}

test "a list of RawDocuments goes as it is" {
    const raws = [_]bson.RawDocument{ bson.literal(.{ .a = 1 }), bson.literal(.{ .b = 2 }) };
    const slice: []const bson.RawDocument = &raws;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try document.encodeList(arena.allocator(), slice);
    try testing.expectEqual(slice.ptr, items.ptr);
    try testing.expectEqual(@as(usize, 2), (try document.encodeList(arena.allocator(), .{ .{ .a = 1 }, raws[1] })).len);
}
