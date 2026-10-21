//! Tests of `bson.encodeKeyed` and `bson.decodeKeyed`: the keys of a
//! struct's top-level fields from a map, the names of Zig in the documents
//! inside, fields that are neither written nor read, and the paths of
//! decode errors by the keys of the document.

const std = @import("std");
const testing = std.testing;
const bson = @import("root.zig");

const S = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,
    created_at: bson.DateTime,
    profile: ?struct { zipCode: []const u8 } = null,
};

const K: []const bson.FieldKey = &.{
    .{ .field = "id", .key = "_id" },
    .{ .field = "created_at", .key = "createdAt" },
};

const id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;

const ann: S = .{
    .id = id,
    .name = "Ann",
    .created_at = .{ .milliseconds = 1_760_000_000_000 },
    .profile = .{ .zipCode = "75001" },
};

/// The keys of `doc`, in their order, are `expected`.
fn expectKeys(expected: []const []const u8, doc: bson.RawDocument) !void {
    var it = doc.iterator();
    for (expected) |key| {
        const element = (try it.next()) orelse return error.TestExpectedMoreKeys;
        try testing.expectEqualStrings(key, element.key);
    }
    try testing.expect((try it.next()) == null);
}

/// `decodeKeyed` of `doc` as `S` by `K` fails with `expected`, at `path`.
fn expectFailure(doc: bson.RawDocument, options: bson.DecodeOptions, expected: anyerror, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: bson.DecodeDiagnostics = .{};
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &diagnostics;
    try testing.expectError(expected, bson.decodeKeyed(S, K, arena.allocator(), doc, with_diagnostics));
    try testing.expectEqualStrings(path, diagnostics.path());
}

test "encodeKeyed writes top-level fields under their keys and nested fields by their Zig names" {
    const doc = try bson.encodeKeyed(testing.allocator, ann, K, .{});
    defer doc.deinit();
    try expectKeys(&.{ "_id", "name", "createdAt", "profile" }, doc.raw());
    try expectKeys(&.{"zipCode"}, (try doc.raw().get("profile")).?.document);
    // The values as encode writes them under those keys.
    const expected = try bson.encode(testing.allocator, .{ ._id = id, .name = "Ann", .createdAt = ann.created_at, .profile = .{ .zipCode = "75001" } }, .{});
    defer expected.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, doc.bytes);
}

test "decodeKeyed reads what encodeKeyed wrote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try bson.encodeKeyed(testing.allocator, ann, K, .{});
    defer doc.deinit();
    try testing.expectEqualDeep(ann, try bson.decodeKeyed(S, K, arena.allocator(), doc.raw(), .{}));

    // skip_nulls leaves the null profile out, and the missing key reads
    // back as null.
    var bob = ann;
    bob.name = "Bob";
    bob.profile = null;
    const lean = try bson.encodeKeyed(testing.allocator, bob, K, .{ .skip_nulls = true });
    defer lean.deinit();
    try expectKeys(&.{ "_id", "name", "createdAt" }, lean.raw());
    try testing.expectEqualDeep(bob, try bson.decodeKeyed(S, K, arena.allocator(), lean.raw(), .{}));
}

test "a field with a null key is neither written nor read" {
    const without_id: []const bson.FieldKey = &.{.{ .field = "id", .key = null }};
    const doc = try bson.encodeKeyed(testing.allocator, ann, without_id, .{});
    defer doc.deinit();
    try expectKeys(&.{ "name", "created_at", "profile" }, doc.raw());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stored = try bson.encode(testing.allocator, .{ .id = id, .name = "Ann", .created_at = ann.created_at }, .{});
    defer stored.deinit();
    const user = try bson.decodeKeyed(S, without_id, arena.allocator(), stored.raw(), .{});
    try testing.expect(user.id == null);
    try testing.expectEqualStrings("Ann", user.name);
    try testing.expectEqual(ann.created_at, user.created_at);
}

test "no keys is encode and decode" {
    const doc = try bson.encodeKeyed(testing.allocator, ann, &.{}, .{});
    defer doc.deinit();
    const plain = try bson.encode(testing.allocator, ann, .{});
    defer plain.deinit();
    try testing.expectEqualSlices(u8, plain.bytes, doc.bytes);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expected = try bson.decode(S, arena.allocator(), plain.raw(), .{});
    try testing.expectEqualDeep(expected, try bson.decodeKeyed(S, &.{}, arena.allocator(), plain.raw(), .{}));
}

test "a decode error names BSON keys" {
    try expectFailure(bson.literal(.{ .createdAt = "x" }), .{}, error.WrongType, "createdAt");
    try expectFailure(bson.literal(.{ .profile = .{ .zipCode = 5 } }), .{}, error.WrongType, "profile.zipCode");
    try expectFailure(bson.literal(.{ .name = "Ann" }), .{}, error.MissingField, "createdAt");
    // The Zig name of a field with a key of its own is a key like any other.
    try expectFailure(bson.literal(.{ .created_at = 1 }), .{ .unknown_fields = .fail }, error.UnknownField, "created_at");
}
