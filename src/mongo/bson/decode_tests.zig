//! Tests of `bson.decode`: each of its rules, the numbers it refuses, the
//! path of the field where it stops, copies, and round trips through
//! `bson.encode`.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const vectors = @import("vectors.zig");
const hex = vectors.hex;
const named = vectors.named;
const literal = bson.literal;

/// `decode` of `doc` as `T` fails with `expected`, at `path`.
fn expectFailure(comptime T: type, doc: bson.RawDocument, options: bson.DecodeOptions, expected: anyerror, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: bson.DecodeDiagnostics = .{};
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &diagnostics;
    try testing.expectError(expected, bson.decode(T, arena.allocator(), doc, with_diagnostics));
    try testing.expectEqualStrings(path, diagnostics.path());
}

const Status = enum { active, blocked };

test "a struct takes the keys of its fields in any order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const User = struct { name: []const u8, age: i32, admin: bool, status: Status };
    const user = try bson.decode(User, arena.allocator(), literal(.{ .status = "blocked", .age = 30, .admin = true, .name = "Ann" }), .{});
    try testing.expectEqualStrings("Ann", user.name);
    try testing.expectEqual(30, user.age);
    try testing.expect(user.admin);
    try testing.expectEqual(Status.blocked, user.status);
}

test "a missing field takes its default value, an optional null, and any other is an error with its path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Defaults = struct { a: i32 = 7, b: ?i32, c: ?i32 = 5, d: []const u8 = "x", e: struct { f: bool = true } = .{} };
    const got = try bson.decode(Defaults, arena.allocator(), literal(.{}), .{});
    try testing.expectEqual(7, got.a);
    try testing.expectEqual(null, got.b);
    try testing.expectEqual(5, got.c);
    try testing.expectEqualStrings("x", got.d);
    try testing.expect(got.e.f);

    const Required = struct { a: i32, inner: struct { b: i32 } };
    try expectFailure(Required, literal(.{ .inner = .{ .b = 1 } }), .{}, error.MissingField, "a");
    try expectFailure(Required, literal(.{ .a = 1, .inner = .{} }), .{}, error.MissingField, "inner.b");
}

test "BSON null is null for an optional, and of the wrong type for anything else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Maybe = struct { a: ?i32 };
    try testing.expectEqual(null, (try bson.decode(Maybe, arena.allocator(), literal(.{ .a = null }), .{})).a);
    try testing.expectEqual(1, (try bson.decode(Maybe, arena.allocator(), literal(.{ .a = 1 }), .{})).a);
    try expectFailure(struct { a: i32 }, literal(.{ .a = null }), .{}, error.WrongType, "a");
    try expectFailure(struct { a: i32 = 5 }, literal(.{ .a = null }), .{}, error.WrongType, "a");
}

test "unknown keys are skipped; .unknown_fields = .fail refuses them with their path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const One = struct { a: i32 };
    const doc = literal(.{ .z = "x", .a = 1, .y = .{ .w = .{ 1, 2 } } });
    try testing.expectEqual(1, (try bson.decode(One, arena.allocator(), doc, .{})).a);
    _ = try bson.decode(struct {}, arena.allocator(), doc, .{});
    try expectFailure(One, doc, .{ .unknown_fields = .fail }, error.UnknownField, "z");
    try expectFailure(struct { a: struct { b: i32 } }, literal(.{ .a = .{ .b = 1, .c = 2 } }), .{ .unknown_fields = .fail }, error.UnknownField, "a.c");
    try expectFailure(struct {}, doc, .{ .unknown_fields = .fail }, error.UnknownField, "z");
}

test "the key of a field that comes twice is an error; unknown keys may repeat" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putInt32("z", 1);
    try b.putInt32("z", 2);
    try b.putInt32("a", 1);
    try b.beginArray("items");
    try b.beginDocument("");
    try b.putInt32("a", 1);
    try b.putInt32("a", 1);
    try b.end();
    try b.end();
    try b.putInt32("a", 2);
    const doc = try b.finish();
    defer doc.deinit();
    try expectFailure(struct { a: i32 }, doc.raw(), .{}, error.DuplicateKey, "a");
    try expectFailure(struct { items: []const struct { a: i32 } }, doc.raw(), .{}, error.DuplicateKey, "items.0.a");
}

test "integers take int32, int64 and doubles that hold an integer, within their type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Long = struct { a: i64 };
    try testing.expectEqual(1, (try bson.decode(Long, allocator, literal(.{ .a = 1 }), .{})).a);
    try testing.expectEqual(3_000_000_000, (try bson.decode(Long, allocator, literal(.{ .a = 3_000_000_000 }), .{})).a);
    try testing.expectEqual(-3, (try bson.decode(Long, allocator, literal(.{ .a = -3.0 }), .{})).a);
    try testing.expectEqual(0, (try bson.decode(Long, allocator, literal(.{ .a = -0.0 }), .{})).a);
    try testing.expectEqual(std.math.minInt(i64), (try bson.decode(Long, allocator, literal(.{ .a = -0x1p63 }), .{})).a);
    const Byte = struct { a: u8 };
    try testing.expectEqual(255, (try bson.decode(Byte, allocator, literal(.{ .a = 255 }), .{})).a);
    try testing.expectEqual(255, (try bson.decode(Byte, allocator, literal(.{ .a = 255.0 }), .{})).a);
    try expectFailure(Byte, literal(.{ .a = 256 }), .{}, error.Overflow, "a");
    try expectFailure(Byte, literal(.{ .a = -1 }), .{}, error.Overflow, "a");
    try expectFailure(Byte, literal(.{ .a = "1" }), .{}, error.WrongType, "a");
    try expectFailure(Byte, literal(.{ .a = true }), .{}, error.WrongType, "a");
}

test "int64 3 000 000 000 in an i32, and 2.5, NaN, ±inf or 1e300 in an i64, are errors with the path, not panics" {
    try expectFailure(struct { n: i32 }, literal(.{ .n = 3_000_000_000 }), .{}, error.Overflow, "n");
    try expectFailure(struct { n: i32 }, literal(.{ .n = 2147483648.0 }), .{}, error.Overflow, "n");
    const Deep = struct { inner: struct { list: []const i64 } };
    for ([_]f64{ 2.5, -0.5, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |x| {
        errdefer std.debug.print("double: {}\n", .{x});
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        try b.put("inner", .{ .list = .{ 1, x } });
        const doc = try b.finish();
        defer doc.deinit();
        try expectFailure(Deep, doc.raw(), .{}, error.NotAnInteger, "inner.list.1");
    }
    for ([_]f64{ 1e300, -1e300, 0x1p63, -0x1p64 }) |x| {
        errdefer std.debug.print("double: {}\n", .{x});
        var b: bson.Builder = .init(testing.allocator);
        defer b.deinit();
        try b.put("inner", .{ .list = .{x} });
        const doc = try b.finish();
        defer doc.deinit();
        try expectFailure(Deep, doc.raw(), .{}, error.Overflow, "inner.list.0");
    }
}

test "floats take doubles and integers; an f32 refuses a finite double beyond its range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Double = struct { a: f64 };
    try testing.expectEqual(2.5, (try bson.decode(Double, allocator, literal(.{ .a = 2.5 }), .{})).a);
    try testing.expectEqual(2, (try bson.decode(Double, allocator, literal(.{ .a = 2 }), .{})).a);
    try testing.expectEqual(3e9, (try bson.decode(Double, allocator, literal(.{ .a = 3_000_000_000 }), .{})).a);
    try testing.expect(std.math.isNan((try bson.decode(Double, allocator, literal(.{ .a = std.math.nan(f64) }), .{})).a));
    const Single = struct { a: f32 };
    try testing.expectEqual(2.5, (try bson.decode(Single, allocator, literal(.{ .a = 2.5 }), .{})).a);
    try testing.expectEqual(std.math.inf(f32), (try bson.decode(Single, allocator, literal(.{ .a = std.math.inf(f64) }), .{})).a);
    try testing.expect(std.math.isNan((try bson.decode(Single, allocator, literal(.{ .a = std.math.nan(f64) }), .{})).a));
    try expectFailure(Single, literal(.{ .a = 1e300 }), .{}, error.Overflow, "a");
    try expectFailure(Single, literal(.{ .a = "2.5" }), .{}, error.WrongType, "a");
}

test "strings must be UTF-8, and are copied into the arena unless .copy_strings = false" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Named = struct { name: []const u8 };
    const doc = literal(.{ .name = "Ann" });
    const copied = try bson.decode(Named, arena.allocator(), doc, .{});
    try testing.expectEqualStrings("Ann", copied.name);
    try testing.expect(!inside(doc.bytes, copied.name));
    const borrowed = try bson.decode(Named, arena.allocator(), doc, .{ .copy_strings = false });
    try testing.expectEqualStrings("Ann", borrowed.name);
    try testing.expect(inside(doc.bytes, borrowed.name));

    // {"name": "\xff"}, as a server or a file may give it: the builder
    // would refuse it, and decode checks it.
    const bad = try bson.RawDocument.init(hex("11000000 02 6e616d6500 02000000 ff00 00"));
    try expectFailure(Named, bad, .{}, error.InvalidBson, "name");
    try expectFailure(Named, bad, .{ .copy_strings = false }, error.InvalidBson, "name");
    try expectFailure(struct { name: bson.Value }, bad, .{}, error.InvalidBson, "name");
    try expectFailure(struct { name: Status }, bad, .{}, error.InvalidBson, "name");
}

test "an enum takes the name of one of its tags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const WithStatus = struct { status: Status };
    try testing.expectEqual(Status.active, (try bson.decode(WithStatus, arena.allocator(), literal(.{ .status = "active" }), .{})).status);
    try expectFailure(WithStatus, literal(.{ .status = "gone" }), .{}, error.InvalidEnumTag, "status");
    try expectFailure(WithStatus, literal(.{ .status = 0 }), .{}, error.WrongType, "status");
}

test "slices take arrays of any length, [N]T exactly N items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const List = struct { a: []const i32 };
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, (try bson.decode(List, allocator, literal(.{ .a = .{ 1, 2, 3 } }), .{})).a);
    try testing.expectEqual(0, (try bson.decode(List, allocator, literal(.{ .a = &.{} }), .{})).a.len);
    const Names = struct { a: []const []const u8 };
    const names = (try bson.decode(Names, allocator, literal(.{ .a = .{ "x", "y" } }), .{})).a;
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("y", names[1]);
    const Pair = struct { a: [2]i32 };
    try testing.expectEqual([2]i32{ 1, 2 }, (try bson.decode(Pair, allocator, literal(.{ .a = .{ 1, 2 } }), .{})).a);
    try expectFailure(Pair, literal(.{ .a = .{1} }), .{}, error.LengthMismatch, "a");
    try expectFailure(Pair, literal(.{ .a = .{ 1, 2, 3 } }), .{}, error.LengthMismatch, "a");
    try expectFailure(struct { a: [0]i32 }, literal(.{ .a = .{1} }), .{}, error.LengthMismatch, "a");
    try expectFailure(List, literal(.{ .a = .{ 1, "x" } }), .{}, error.WrongType, "a.1");
    try expectFailure(List, literal(.{ .a = .{ .b = 1 } }), .{}, error.WrongType, "a");
    try expectFailure(struct { a: []const struct { b: i32 } }, literal(.{ .a = .{ .{ .b = 1 }, .{ .c = 2 } } }), .{}, error.MissingField, "a.1.b");
}

test "a struct takes a document, and nothing else" {
    try expectFailure(struct { a: struct { b: i32 } }, literal(.{ .a = .{ 1, 2 } }), .{}, error.WrongType, "a");
    try expectFailure(struct { a: struct { b: i32 } }, literal(.{ .a = 1 }), .{}, error.WrongType, "a");
    try expectFailure(struct { a: bson.RawDocument }, literal(.{ .a = .{ 1, 2 } }), .{}, error.WrongType, "a");
    try expectFailure(struct { a: bson.ObjectId }, literal(.{ .a = "eef732123cc60d97791de0cf" }), .{}, error.WrongType, "a");
}

const Special = struct {
    raw: bson.RawDocument,
    value: bson.Value,
    id: bson.ObjectId,
    at: bson.DateTime,
    stamp: bson.Timestamp,
    data: bson.Binary,
    number: bson.Decimal128,
    pattern: bson.Regex,
    nothing: bson.Null,
    min: bson.MinKey,
    max: bson.MaxKey,
};

const special: Special = .{
    .raw = .{ .bytes = vectors.reply },
    .value = .{ .string = "v" },
    .id = .{ .bytes = vectors.object_id },
    .at = .{ .milliseconds = 2231982819287 },
    .stamp = .{ .seconds = 2355942023, .increment = 105 },
    .data = .{ .subtype = .uuid, .bytes = &.{ 1, 2, 3 } },
    .number = .{ .bytes = hex("0f000000000000000000000000003e30").* },
    .pattern = .{ .pattern = "^a.c", .options = "im" },
    .nothing = .{},
    .min = .{},
    .max = .{},
};

test "documents, values and the special types are read as they are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = literal(special);
    for ([_]bool{ true, false }) |copy| {
        const got = try bson.decode(Special, arena.allocator(), doc, .{ .copy_strings = copy });
        try testing.expectEqualSlices(u8, vectors.reply, got.raw.bytes);
        try testing.expectEqualStrings("v", got.value.string);
        try testing.expectEqual(special.id, got.id);
        try testing.expectEqual(special.at, got.at);
        try testing.expectEqual(special.stamp, got.stamp);
        try testing.expectEqual(special.data.subtype, got.data.subtype);
        try testing.expectEqualSlices(u8, special.data.bytes, got.data.bytes);
        try testing.expectEqual(special.number, got.number);
        try testing.expectEqualStrings("^a.c", got.pattern.pattern);
        try testing.expectEqualStrings("im", got.pattern.options);
        // With copy_strings every slice lives in the arena, without it in the document.
        for ([_][]const u8{ got.raw.bytes, got.value.string, got.data.bytes, got.pattern.pattern, got.pattern.options }) |part| {
            try testing.expectEqual(!copy, inside(doc.bytes, part));
        }
    }
}

test "every vector reads back into a Value, the deprecated types too, and into its own type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (vectors.valid) |vector| {
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        const doc = try bson.RawDocument.init(vector.bson);
        for ([_]bool{ true, false }) |copy| {
            const got = try bson.decode(struct { a: bson.Value }, arena.allocator(), doc, .{ .copy_strings = copy });
            try expectEqualValues(vector.value, got.a);
        }
    }
    const pointer = try bson.decode(struct { a: bson.DbPointer }, arena.allocator(), try .init(named("DBPointer")), .{});
    try testing.expectEqualStrings("shop.orders", pointer.a.namespace);
    const code = try bson.decode(struct { a: bson.JavaScriptWithScope }, arena.allocator(), try .init(named("JavaScript with scope")), .{});
    try testing.expectEqualStrings("x", code.a.code);
    try testing.expectEqualSlices(u8, hex("0c000000 10 7800 01000000 00"), code.a.scope.bytes);
}

test "a broken element gives InvalidBson with the path of the document that holds it" {
    const broken = vectors.broken[vectors.broken.len - 1];
    try testing.expectEqualStrings("second element broken", broken.name);
    try expectFailure(struct { a: ?i32 = null }, try .init(broken.bytes), .{}, error.InvalidBson, "");
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.beginDocument("a");
    try b.beginArray("b");
    try b.end();
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    // Break the type byte of the array in a copy: {"a": {"b": <0x20>}}.
    const bytes = try testing.allocator.dupe(u8, doc.bytes);
    defer testing.allocator.free(bytes);
    bytes[11] = 0x20;
    try expectFailure(struct { a: struct { b: []const i32 } }, try .init(bytes), .{}, error.InvalidBson, "a");
}

test "a decode empties the diagnostics first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: bson.DecodeDiagnostics = .{};
    const Inner = struct { a: struct { b: i32 } };
    try testing.expectError(error.WrongType, bson.decode(Inner, arena.allocator(), literal(.{ .a = .{ .b = "x" } }), .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("a.b", diagnostics.path());
    try testing.expectError(error.MissingField, bson.decode(struct { c: i32 }, arena.allocator(), literal(.{}), .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("c", diagnostics.path());
    _ = try bson.decode(Inner, arena.allocator(), literal(.{ .a = .{ .b = 1 } }), .{ .diagnostics = &diagnostics });
    try testing.expectEqualStrings("", diagnostics.path());
}

test "a path too long for the diagnostics keeps its end" {
    const key: [250]u8 = @splat('k');
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.beginDocument("inner");
    try b.putInt32(&key, 1);
    try b.end();
    const doc = try b.finish();
    defer doc.deinit();
    try expectFailure(struct { inner: struct {} }, doc.raw(), .{ .unknown_fields = .fail }, error.UnknownField, "…." ++ key);

    var longer: bson.Builder = .init(testing.allocator);
    defer longer.deinit();
    try longer.putInt32(&(key ++ key), 1);
    const long_key = try longer.finish();
    defer long_key.deinit();
    try expectFailure(struct {}, long_key.raw(), .{ .unknown_fields = .fail }, error.UnknownField, "…");
}

test "decode gives error.OutOfMemory at each allocation it makes, and nothing else" {
    const Item = struct { name: []const u8, tags: []const []const u8 };
    const Doc = struct { items: []const Item, raw: bson.RawDocument, value: bson.Value };
    const doc = literal(.{ .items = .{ .{ .name = "a", .tags = .{ "x", "y" } }, .{ .name = "b", .tags = &.{} } }, .raw = .{ .c = 1 }, .value = .{ .d = "e" } });
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var arena: std.heap.ArenaAllocator = .init(failing.allocator());
        defer arena.deinit();
        const got = bson.decode(Doc, arena.allocator(), doc, .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try testing.expectEqualStrings("y", got.items[0].tags[1]);
        break;
    }
    try testing.expect(fail_index > 0);
}

test "what encode writes, decode reads back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Address = struct { city: []const u8, zip: ?[]const u8 = null };
    const User = struct {
        _id: bson.ObjectId,
        name: []const u8,
        age: u8,
        balance: i64,
        score: f64,
        status: Status,
        address: Address,
        tags: []const []const u8,
        history: []const Address,
        pair: [2]u32,
        nickname: ?[]const u8,
    };
    const user: User = .{
        ._id = .{ .bytes = vectors.object_id },
        .name = "Ann",
        .age = 30,
        .balance = -5_000_000_000,
        .score = 0.25,
        .status = .active,
        .address = .{ .city = "Berlin", .zip = "10115" },
        .tags = &.{ "a", "b" },
        .history = &.{.{ .city = "Wien" }},
        .pair = .{ 0, std.math.maxInt(u32) },
        .nickname = null,
    };
    for ([_]bool{ false, true }) |skip_nulls| {
        const doc = try bson.encode(testing.allocator, user, .{ .skip_nulls = skip_nulls });
        defer doc.deinit();
        const got = try bson.decode(User, arena.allocator(), doc.raw(), .{ .unknown_fields = .fail });
        try testing.expectEqualDeep(user, got);
    }
}

test "packed and extern structs are documents too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Flags = packed struct { read: bool, write: bool, level: u6 };
    const Point = extern struct { x: i32, y: f64 };
    const Both = struct { flags: Flags, point: Point };
    const value: Both = .{ .flags = .{ .read = true, .write = false, .level = 5 }, .point = .{ .x = 1, .y = 2.5 } };
    const doc = try bson.encode(testing.allocator, value, .{});
    defer doc.deinit();
    try testing.expectEqualSlices(u8, literal(.{ .flags = .{ .read = true, .write = false, .level = 5 }, .point = .{ .x = 1, .y = 2.5 } }).bytes, doc.bytes);
    try testing.expectEqualDeep(value, try bson.decode(Both, arena.allocator(), doc.raw(), .{}));
}

/// Whether `part` points into `bytes`.
fn inside(bytes: []const u8, part: []const u8) bool {
    const start = @intFromPtr(bytes.ptr);
    const at = @intFromPtr(part.ptr);
    return at >= start and at + part.len <= start + bytes.len;
}

fn expectEqualValues(expected: bson.Value, actual: bson.Value) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .double => |d| try testing.expectEqual(@as(u64, @bitCast(d)), @as(u64, @bitCast(actual.double))),
        .string => |s| try testing.expectEqualStrings(s, actual.string),
        .javascript => |s| try testing.expectEqualStrings(s, actual.javascript),
        .symbol => |s| try testing.expectEqualStrings(s, actual.symbol),
        .document => |d| try testing.expectEqualSlices(u8, d.bytes, actual.document.bytes),
        .array => |d| try testing.expectEqualSlices(u8, d.bytes, actual.array.bytes),
        .binary => |b| {
            try testing.expectEqual(b.subtype, actual.binary.subtype);
            try testing.expectEqualSlices(u8, b.bytes, actual.binary.bytes);
        },
        .regex => |r| {
            try testing.expectEqualStrings(r.pattern, actual.regex.pattern);
            try testing.expectEqualStrings(r.options, actual.regex.options);
        },
        .db_pointer => |p| {
            try testing.expectEqualStrings(p.namespace, actual.db_pointer.namespace);
            try testing.expectEqual(p.id, actual.db_pointer.id);
        },
        .javascript_with_scope => |c| {
            try testing.expectEqualStrings(c.code, actual.javascript_with_scope.code);
            try testing.expectEqualSlices(u8, c.scope.bytes, actual.javascript_with_scope.scope.bytes);
        },
        else => try testing.expectEqual(expected, actual),
    }
}
