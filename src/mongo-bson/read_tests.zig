//! Tests of reading BSON: every type from its vector, broken bytes, the
//! nesting limit, the accessors of `RawDocument` and the numbers of
//! `Value`.

const std = @import("std");
const testing = std.testing;
const bson = @import("root.zig");
const vectors = @import("vectors.zig");
const RawDocument = bson.RawDocument;
const Value = bson.Value;

test "every vector reads back its value, and nothing after it" {
    for (vectors.valid) |vector| {
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        const doc = try RawDocument.init(vector.bson);
        try doc.validate();
        var it = doc.iterator();
        const element = (try it.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("a", element.key);
        try expectEqualValues(vector.value, element.value);
        try testing.expect(try it.next() == null);
        try testing.expect(try it.next() == null);
    }
}

test "the empty document has no elements" {
    const doc = try RawDocument.init(vectors.empty);
    try doc.validate();
    var it = doc.iterator();
    try testing.expect(try it.next() == null);
    try testing.expect(try doc.first() == null);
    try testing.expectEqualSlices(u8, vectors.empty, RawDocument.empty.bytes);
}

test "broken bytes give error.InvalidBson from init or from validate" {
    for (vectors.broken) |vector| {
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        switch (vector.caught_by) {
            .init => try testing.expectError(error.InvalidBson, RawDocument.init(vector.bytes)),
            .validate => {
                const doc = try RawDocument.init(vector.bytes);
                try testing.expectError(error.InvalidBson, doc.validate());
                // Code that skips validate meets the same bytes lazily:
                // an error or the end, never a panic.
                walkLazily(doc);
            },
        }
    }
}

test "an iterator stops at a broken element and keeps reporting it" {
    const doc = try RawDocument.init(brokenNamed("second element broken"));
    var it = doc.iterator();
    const first = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a", first.key);
    try testing.expect(first.value == .null);
    try testing.expectError(error.InvalidBson, it.next());
    try testing.expectError(error.InvalidBson, it.next());
}

test "a broken element inside a document waits for validate or for its own iterator" {
    const doc = try RawDocument.init(brokenNamed("broken element inside a document"));
    var it = doc.iterator();
    const element = (try it.next()) orelse return error.TestUnexpectedResult;
    var inner = element.value.document.iterator();
    try testing.expectError(error.InvalidBson, inner.next());
    try testing.expectError(error.InvalidBson, doc.validate());
}

test "100 levels of nesting pass validate, 101 do not" {
    const allowed = try vectors.nested(testing.allocator, 100);
    defer testing.allocator.free(allowed);
    try (try RawDocument.init(allowed)).validate();

    const too_deep = try vectors.nested(testing.allocator, 101);
    defer testing.allocator.free(too_deep);
    const doc = try RawDocument.init(too_deep);
    try testing.expectError(error.InvalidBson, doc.validate());
}

test "get, getPath and first find the elements of a reply" {
    const reply = try RawDocument.init(vectors.reply);
    try reply.validate();
    try testing.expectEqualStrings("cursor", ((try reply.first()) orelse return error.TestUnexpectedResult).key);
    try testing.expectEqual(1.0, try ((try reply.get("ok")) orelse return error.TestUnexpectedResult).asF64());
    try testing.expectEqual(0, try ((try reply.getPath("cursor.id")) orelse return error.TestUnexpectedResult).asI64());
    try testing.expectEqualStrings("app.users", ((try reply.getPath("cursor.ns")) orelse return error.TestUnexpectedResult).string);
    const name = (try reply.getPath("cursor.firstBatch.0.name")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", name.string);
    const id = (try reply.getPath("cursor.firstBatch.0._id")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &vectors.object_id, &id.object_id.bytes);
}

test "get and getPath give null for what is not there" {
    const reply = try RawDocument.init(vectors.reply);
    try testing.expect(try reply.get("missing") == null);
    try testing.expect(try reply.get("") == null);
    try testing.expect(try reply.get("cursor.id") == null);
    try testing.expect(try reply.getPath("cursor.missing") == null);
    try testing.expect(try reply.getPath("cursor.firstBatch.1") == null);
    // ok is a double, so nothing lies under it.
    try testing.expect(try reply.getPath("ok.anything") == null);
    try testing.expect(try reply.getPath("") == null);
    try testing.expect(try reply.getPath("cursor.") == null);
}

test "getPath reports a broken element on its way" {
    const doc = try RawDocument.init(brokenNamed("broken element inside a document"));
    try testing.expectError(error.InvalidBson, doc.getPath("a.b"));
}

test "dupe copies a document into the allocator" {
    const reply = try RawDocument.init(vectors.reply);
    const copy = try reply.dupe(testing.allocator);
    defer copy.deinit();
    try testing.expectEqualSlices(u8, vectors.reply, copy.bytes);
    try testing.expect(copy.bytes.ptr != vectors.reply.ptr);
    const name = (try copy.raw().getPath("cursor.firstBatch.0.name")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", name.string);
}

test "asI64 takes every number that is an integer within i64" {
    try testing.expectEqual(-5, try (Value{ .int32 = -5 }).asI64());
    try testing.expectEqual(3_000_000_000, try (Value{ .int64 = 3_000_000_000 }).asI64());
    try testing.expectEqual(std.math.maxInt(i64), try (Value{ .int64 = std.math.maxInt(i64) }).asI64());
    try testing.expectEqual(42, try (Value{ .double = 42.0 }).asI64());
    try testing.expectEqual(0, try (Value{ .double = -0.0 }).asI64());
    try testing.expectEqual(std.math.minInt(i64), try (Value{ .double = -0x1p63 }).asI64());
    try testing.expectEqual(0x7ffffffffffffc00, try (Value{ .double = 0x1.fffffffffffffp62 }).asI64());
}

test "asI64 refuses fractions, NaN, infinities, numbers out of range and other types" {
    try testing.expectError(error.NotAnInteger, (Value{ .double = 2.5 }).asI64());
    try testing.expectError(error.NotAnInteger, (Value{ .double = -0.5 }).asI64());
    try testing.expectError(error.NotAnInteger, (Value{ .double = std.math.nan(f64) }).asI64());
    try testing.expectError(error.NotAnInteger, (Value{ .double = std.math.inf(f64) }).asI64());
    try testing.expectError(error.NotAnInteger, (Value{ .double = -std.math.inf(f64) }).asI64());
    try testing.expectError(error.Overflow, (Value{ .double = 1e300 }).asI64());
    try testing.expectError(error.Overflow, (Value{ .double = -1e300 }).asI64());
    try testing.expectError(error.Overflow, (Value{ .double = 0x1p63 }).asI64());
    try testing.expectError(error.WrongType, (Value{ .string = "1" }).asI64());
    try testing.expectError(error.WrongType, (Value{ .boolean = true }).asI64());
    try testing.expectError(error.WrongType, (Value{ .date_time = .{ .milliseconds = 1 } }).asI64());
    try testing.expectError(error.WrongType, Value.asI64(.null));
}

test "asF64 takes every number, NaN and infinities included" {
    try testing.expectEqual(1.0, try (Value{ .int32 = 1 }).asF64());
    try testing.expectEqual(3e9, try (Value{ .int64 = 3_000_000_000 }).asF64());
    try testing.expectEqual(0x1p63, try (Value{ .int64 = std.math.maxInt(i64) }).asF64());
    try testing.expectEqual(2.5, try (Value{ .double = 2.5 }).asF64());
    try testing.expect(std.math.isNan(try (Value{ .double = std.math.nan(f64) }).asF64()));
    try testing.expectEqual(-std.math.inf(f64), try (Value{ .double = -std.math.inf(f64) }).asF64());
    try testing.expectError(error.WrongType, (Value{ .string = "1.5" }).asF64());
    try testing.expectError(error.WrongType, (Value{ .decimal128 = .{ .bytes = vectors.hex("0f000000000000000000000000003e30").* } }).asF64());
}

/// Compares two values; doubles by their bits, so that -0.0 differs from
/// 0.0, and every NaN equals every NaN.
pub fn expectEqualValues(expected: Value, actual: Value) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .double => |d| {
            if (std.math.isNan(d)) return testing.expect(std.math.isNan(actual.double));
            try testing.expectEqual(@as(u64, @bitCast(d)), @as(u64, @bitCast(actual.double)));
        },
        else => try testing.expectEqualDeep(expected, actual),
    }
}

fn brokenNamed(comptime name: []const u8) []const u8 {
    inline for (vectors.broken) |vector| {
        if (comptime std.mem.eql(u8, vector.name, name)) return vector.bytes;
    }
    @compileError("no broken vector named " ++ name);
}

/// Walks every element of `doc` and of the documents in it without
/// `validate`, as code that skips it would; stops at the first error.
fn walkLazily(doc: RawDocument) void {
    var it = doc.iterator();
    while (it.next() catch return) |element| {
        switch (element.value) {
            .document, .array => |inner| walkLazily(inner),
            .javascript_with_scope => |code| walkLazily(code.scope),
            else => {},
        }
    }
}
