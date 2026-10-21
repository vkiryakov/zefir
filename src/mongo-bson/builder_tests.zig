//! Tests of writing BSON with `Builder`: its bytes against the vectors,
//! nesting, and the documents it refuses to write.

const std = @import("std");
const testing = std.testing;
const bson = @import("root.zig");
const vectors = @import("vectors.zig");
const Builder = bson.Builder;
const Value = bson.Value;

test "putValue writes every vector that is not deprecated byte for byte" {
    for (vectors.valid) |vector| {
        if (deprecated(vector.value)) continue;
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        var b: Builder = .init(testing.allocator);
        defer b.deinit();
        try b.putValue("a", vector.value);
        const doc = try b.finish();
        defer doc.deinit();
        try testing.expectEqualSlices(u8, vector.bson, doc.bytes);
    }
}

test "the put function of each type writes its vector byte for byte" {
    for (vectors.valid) |vector| {
        if (deprecated(vector.value)) continue;
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        var b: Builder = .init(testing.allocator);
        defer b.deinit();
        switch (vector.value) {
            .double => |v| try b.putDouble("a", v),
            .string => |v| try b.putString("a", v),
            .document => |v| try b.putDocument("a", v),
            .array => |v| try b.putArray("a", v),
            .binary => |v| try b.putBinary("a", v),
            .object_id => |v| try b.putObjectId("a", v),
            .boolean => |v| try b.putBoolean("a", v),
            .date_time => |v| try b.putDateTime("a", v),
            .null => try b.putNull("a"),
            .regex => |v| try b.putRegex("a", v),
            .javascript => |v| try b.putJavaScript("a", v),
            .int32 => |v| try b.putInt32("a", v),
            .timestamp => |v| try b.putTimestamp("a", v),
            .int64 => |v| try b.putInt64("a", v),
            .decimal128 => |v| try b.putDecimal128("a", v),
            .min_key => try b.putMinKey("a"),
            .max_key => try b.putMaxKey("a"),
            .undefined, .db_pointer, .symbol, .javascript_with_scope => return error.TestUnexpectedResult,
        }
        const doc = try b.finish();
        defer doc.deinit();
        try testing.expectEqualSlices(u8, vector.bson, doc.bytes);
    }
}

test "nested documents and arrays come out as the reply vector" {
    const doc = try buildReply(testing.allocator);
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectors.reply, doc.bytes);
}

test "a builder that runs out of memory frees what it holds" {
    try testing.checkAllAllocationFailures(testing.allocator, buildReplyAndFree, .{});
}

test "in an array the builder writes the keys itself" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.beginArray("a");
    try b.putInt32("", 1);
    try b.putString("", "x");
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("array"), doc.bytes);
}

test "a key in an array is refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.beginArray("a");
    try testing.expectError(error.InvalidBson, b.putInt32("0", 1));
    try testing.expectError(error.InvalidBson, b.beginDocument("0"));
}

test "a key with a 0 byte is refused, and the builder goes on as before" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try testing.expectError(error.InvalidBson, b.putInt32("a\x00b", 1));
    try testing.expectError(error.InvalidBson, b.beginDocument("\x00"));
    try b.putInt32("a", 1);
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("int32"), doc.bytes);
}

test "a string, a code, a key or a regular expression that is not UTF-8 is refused, and the builder goes on as before" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    // A byte that UTF-8 never uses, a sequence cut short, a surrogate, an
    // overlong encoding, a lone continuation byte.
    try testing.expectError(error.InvalidBson, b.putString("a", "\xff"));
    try testing.expectError(error.InvalidBson, b.putJavaScript("a", "x=\xd0"));
    try testing.expectError(error.InvalidBson, b.putValue("a", .{ .string = "\xed\xa0\x80" }));
    try testing.expectError(error.InvalidBson, b.putInt32("k\xc0\xaf", 1));
    try testing.expectError(error.InvalidBson, b.beginDocument("\x80"));
    try testing.expectError(error.InvalidBson, b.putRegex("a", .{ .pattern = "^\xff", .options = "" }));
    try testing.expectError(error.InvalidBson, b.putRegex("a", .{ .pattern = "^a", .options = "\xff" }));
    try b.putInt32("a", 1);
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("int32"), doc.bytes);
}

test "a regular expression with a 0 byte is refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try testing.expectError(error.InvalidBson, b.putRegex("a", .{ .pattern = "^a\x00", .options = "" }));
    try testing.expectError(error.InvalidBson, b.putRegex("a", .{ .pattern = "^a", .options = "i\x00" }));
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectors.empty, doc.bytes);
}

test "the options of a regular expression are written sorted, as the spec asks" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    const options = "mi";
    try b.putRegex("a", .{ .pattern = "^a.c", .options = options });
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("regular expression"), doc.bytes);
    try testing.expectEqualStrings("mi", options);
}

test "100 levels of nesting are written, a 101st is refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    for (0..99) |_| try b.beginDocument("a");
    try testing.expectError(error.InvalidBson, b.beginDocument("a"));
    try testing.expectError(error.InvalidBson, b.beginArray("a"));
    for (0..99) |_| try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    const expected = try vectors.nested(testing.allocator, 100);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, doc.bytes);
}

test "putDocument checks the document and counts its levels" {
    const levels_99 = try vectors.nested(testing.allocator, 99);
    defer testing.allocator.free(levels_99);
    const levels_100 = try vectors.nested(testing.allocator, 100);
    defer testing.allocator.free(levels_100);

    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    // With the top-level document, 100 levels would make 101.
    try testing.expectError(error.InvalidBson, b.putDocument("a", .{ .bytes = levels_100 }));
    try testing.expectError(error.InvalidBson, b.putArray("a", .{ .bytes = levels_100 }));
    for (vectors.broken) |vector| {
        if (vector.caught_by == .init) continue;
        try testing.expectError(error.InvalidBson, b.putDocument("a", .{ .bytes = vector.bytes }));
    }
    try b.putDocument("a", .{ .bytes = levels_99 });
    const doc = try b.finish();
    defer doc.deinit();
    try (try bson.RawDocument.init(doc.bytes)).validate();
}

test "end without an open document, and finish with one open, are refused" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try testing.expectError(error.InvalidBson, b.end());
    try b.beginDocument("a");
    try testing.expectError(error.InvalidBson, b.finish());
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("empty document"), doc.bytes);
}

test "deprecated types are read but never written" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    for (vectors.valid) |vector| {
        if (!deprecated(vector.value)) continue;
        try testing.expectError(error.InvalidBson, b.putValue("a", vector.value));
    }
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectors.empty, doc.bytes);
}

test "a builder made as a struct literal works as one made with init" {
    var b: Builder = .{ .allocator = testing.allocator };
    defer b.deinit();
    try b.beginArray("a");
    try b.putInt32("", 1);
    try b.putString("", "x");
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("array"), doc.bytes);
}

test "an empty builder gives {}, and a builder builds again after finish" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    const empty = try b.finish();
    defer empty.deinit();
    try testing.expectEqualSlices(u8, vectors.empty, empty.bytes);
    try b.putInt32("a", 1);
    const again = try b.finish();
    defer again.deinit();
    try testing.expectEqualSlices(u8, vectorNamed("int32"), again.bytes);
}

fn deprecated(value: Value) bool {
    return switch (value) {
        .undefined, .db_pointer, .symbol, .javascript_with_scope => true,
        else => false,
    };
}

fn vectorNamed(comptime name: []const u8) []const u8 {
    inline for (vectors.valid) |vector| {
        if (comptime std.mem.eql(u8, vector.name, name)) return vector.bson;
    }
    @compileError("no vector named " ++ name);
}

/// The reply vector, written with nested documents and an array.
fn buildReply(allocator: std.mem.Allocator) !bson.OwnedDocument {
    var b: Builder = .init(allocator);
    defer b.deinit();
    try b.beginDocument("cursor");
    try b.beginArray("firstBatch");
    try b.beginDocument("");
    try b.putObjectId("_id", .{ .bytes = vectors.object_id });
    try b.putString("name", "Ann");
    try b.end();
    try b.end();
    try b.putInt64("id", 0);
    try b.putString("ns", "app.users");
    try b.end();
    try b.putDouble("ok", 1.0);
    return b.finish();
}

fn buildReplyAndFree(allocator: std.mem.Allocator) !void {
    const doc = try buildReply(allocator);
    doc.deinit();
}
