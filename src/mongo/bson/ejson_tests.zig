//! Tests of `{f}` on `RawDocument`: Relaxed Extended JSON for every type,
//! escapes, numbers and dates at their edges, and broken documents.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const vectors = @import("vectors.zig");
const RawDocument = bson.RawDocument;
const Builder = bson.Builder;

test "every vector prints as its Relaxed Extended JSON" {
    for (vectors.valid) |vector| {
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        try testing.expectFmt(vector.json, "{f}", .{try RawDocument.init(vector.bson)});
    }
}

test "the reply and the empty document print with their nesting" {
    try testing.expectFmt(
        "{\"cursor\":{\"firstBatch\":[{\"_id\":{\"$oid\":\"56e1fc72e0c917e9c4714161\"},\"name\":\"Ann\"}]," ++
            "\"id\":0,\"ns\":\"app.users\"},\"ok\":1.0}",
        "{f}",
        .{try RawDocument.init(vectors.reply)},
    );
    try testing.expectFmt("{}", "{f}", .{RawDocument.empty});
}

test "strings and keys are escaped" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putString("q\"uote", "\"\\/\n\r\t\x08\x0c\x01\x1f\x7f ~é");
    try b.putJavaScript("back\\slash", "a\"b");
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectFmt(
        "{\"q\\\"uote\":\"\\\"\\\\/\\n\\r\\t\\b\\f\\u0001\\u001f\\u007f ~é\",\"back\\\\slash\":{\"$code\":\"a\\\"b\"}}",
        "{f}",
        .{doc.raw()},
    );
}

test "bytes that are not UTF-8 print as U+FFFD, each on its own" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    // A lone continuation byte, an overlong encoding, a surrogate, a byte
    // that UTF-8 never uses, and a sequence cut short by the end.
    try b.putString("s", "a\x80b\xc0\x80c\xed\xa0\x80d\xffe\xd0");
    try b.putInt32("k\xff", 1);
    const doc = try b.finish();
    defer doc.deinit();
    try testing.expectFmt(
        "{\"s\":\"a\\ufffdb\\ufffd\\ufffdc\\ufffd\\ufffd\\ufffdd\\ufffde\\ufffd\",\"k\\ufffd\":1}",
        "{f}",
        .{doc.raw()},
    );
}

test "doubles print as the shortest JSON number that reads back, with a point or an exponent" {
    for ([_]struct { f64, []const u8 }{
        .{ 0.0, "0.0" },
        .{ 100.0, "100.0" },
        .{ -1.5, "-1.5" },
        .{ 0.1, "0.1" },
        .{ 123456789.125, "123456789.125" },
        .{ 1e20, "100000000000000000000.0" },
        .{ 1e21, "1e21" },
        .{ 0.000001, "0.000001" },
        .{ 1e-7, "1e-7" },
        .{ 1.2345678901234568e18, "1234567890123456800.0" },
        .{ 5e-324, "5e-324" },
        .{ 1.7976931348623157e308, "1.7976931348623157e308" },
        .{ -1e300, "-1e300" },
    }) |case| {
        var b: Builder = .init(testing.allocator);
        defer b.deinit();
        try b.putDouble("d", case[0]);
        const doc = try b.finish();
        defer doc.deinit();
        var expected: [64]u8 = undefined;
        try testing.expectFmt(try std.fmt.bufPrint(&expected, "{{\"d\":{s}}}", .{case[1]}), "{f}", .{doc.raw()});
    }
}

test "dates from 1970 through 9999 print as ISO-8601, others as milliseconds" {
    for ([_]struct { i64, []const u8 }{
        .{ 0, "{\"$date\":\"1970-01-01T00:00:00Z\"}" },
        .{ 1, "{\"$date\":\"1970-01-01T00:00:00.001Z\"}" },
        .{ 951782400000, "{\"$date\":\"2000-02-29T00:00:00Z\"}" },
        .{ 1792326000123, "{\"$date\":\"2026-10-18T12:20:00.123Z\"}" },
        .{ 253402300799999, "{\"$date\":\"9999-12-31T23:59:59.999Z\"}" },
        .{ 253402300800000, "{\"$date\":{\"$numberLong\":\"253402300800000\"}}" },
        .{ -1, "{\"$date\":{\"$numberLong\":\"-1\"}}" },
        .{ std.math.minInt(i64), "{\"$date\":{\"$numberLong\":\"-9223372036854775808\"}}" },
        .{ std.math.maxInt(i64), "{\"$date\":{\"$numberLong\":\"9223372036854775807\"}}" },
    }) |case| {
        var b: Builder = .init(testing.allocator);
        defer b.deinit();
        try b.putDateTime("t", .{ .milliseconds = case[0] });
        const doc = try b.finish();
        defer doc.deinit();
        var expected: [96]u8 = undefined;
        try testing.expectFmt(try std.fmt.bufPrint(&expected, "{{\"t\":{s}}}", .{case[1]}), "{f}", .{doc.raw()});
    }
}

test "100 levels of nesting print in full" {
    const bytes = try vectors.nested(testing.allocator, 100);
    defer testing.allocator.free(bytes);
    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{try RawDocument.init(bytes)});
    defer testing.allocator.free(text);
    try testing.expectEqual(99 * "{\"a\":".len + "{}".len + 99, text.len);
    try testing.expectStringStartsWith(text, "{\"a\":{\"a\":");
    const closing: [99]u8 = @splat('}');
    try testing.expectStringEndsWith(text, "{\"a\":{}" ++ closing);
}

test "a broken document prints as <invalid BSON>" {
    for (vectors.broken) |vector| {
        if (vector.caught_by == .init) continue;
        errdefer std.debug.print("vector: {s}\n", .{vector.name});
        try testing.expectFmt("<invalid BSON>", "{f}", .{try RawDocument.init(vector.bytes)});
    }
    const too_deep = try vectors.nested(testing.allocator, 101);
    defer testing.allocator.free(too_deep);
    try testing.expectFmt("<invalid BSON>", "{f}", .{try RawDocument.init(too_deep)});
    // Bytes that skipped init.
    try testing.expectFmt("<invalid BSON>", "{f}", .{RawDocument{ .bytes = "\x05\x00" }});
}
