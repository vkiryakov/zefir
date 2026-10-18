//! Fuzzing of the BSON reader. `zig build test` runs each corpus entry
//! once, as a regression test; `zig build test --fuzz=1M` runs the fuzzer.
//! The property: any bytes are either refused by `RawDocument.init`, or
//! give a document whose walk ends, and nothing panics. Walking every
//! element through the iterators gets through exactly when `validate`
//! passes. A valid document prints as valid JSON and comes out of
//! `Builder` byte for byte; an invalid one prints as "<invalid BSON>".
//! Each input is also tried as the elements of a document, so that the
//! fuzzer does not have to find a matching length first.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const ejson = @import("ejson.zig");
const vectors = @import("vectors.zig");

fn fuzzReader(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    try check(input);

    var framed: [buffer.len + 5]u8 = undefined;
    std.mem.writeInt(i32, framed[0..4], @intCast(input.len + 5), .little);
    @memcpy(framed[4..][0..input.len], input);
    framed[input.len + 4] = 0;
    try check(framed[0 .. input.len + 5]);
}

fn check(bytes: []const u8) !void {
    const doc = bson.RawDocument.init(bytes) catch return;
    const valid = if (doc.validate()) |_| true else |_| false;
    try testing.expectEqual(valid, walk(doc));

    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{doc});
    defer testing.allocator.free(text);
    if (!valid) return testing.expectEqualStrings(ejson.invalid, text);
    try testing.expect(try std.json.validate(testing.allocator, text));
    try rebuild(doc);
}

/// Walks every element through the iterators, into documents, arrays and
/// scopes, as deep as `validate` allows, and reads each value as code
/// would. Returns whether it got through.
fn walk(doc: bson.RawDocument) bool {
    _ = doc.first() catch {};
    _ = doc.getPath("a.0.b") catch {};
    var stack: [bson.max_depth]bson.RawDocument.Iterator = undefined;
    stack[0] = doc.iterator();
    var depth: usize = 1;
    while (depth > 0) {
        const element = (stack[depth - 1].next() catch return false) orelse {
            depth -= 1;
            continue;
        };
        _ = element.value.asI64() catch {};
        _ = element.value.asF64() catch {};
        const inner = switch (element.value) {
            .document, .array => |d| d,
            .javascript_with_scope => |code| code.scope,
            else => continue,
        };
        if (depth == stack.len) return false;
        stack[depth] = inner.iterator();
        depth += 1;
    }
    return true;
}

/// Writes the elements of a valid document again with `Builder` and
/// compares the bytes; skipped when the document holds what the builder
/// writes otherwise on purpose: a deprecated type, or the options of a
/// regular expression out of order.
fn rebuild(doc: bson.RawDocument) !void {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    var it = doc.iterator();
    while (try it.next()) |element| {
        switch (element.value) {
            .undefined, .db_pointer, .symbol, .javascript_with_scope => return,
            .regex => |regex| if (!std.sort.isSorted(u8, regex.options, {}, std.sort.asc(u8))) return,
            else => {},
        }
        try b.putValue(element.key, element.value);
    }
    const copy = try b.finish();
    defer copy.deinit();
    try testing.expectEqualSlices(u8, doc.bytes, copy.bytes);
}

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first.
fn sample(comptime raw: []const u8) []const u8 {
    return comptime std.mem.toBytes(std.mem.nativeToLittle(u32, raw.len)) ++ raw;
}

/// The elements of a document, without its length and its final 0.
fn body(comptime doc: []const u8) []const u8 {
    return doc[4 .. doc.len - 1];
}

fn nested(comptime levels: usize) []const u8 {
    comptime {
        var bytes: [vectors.nestedLen(levels)]u8 = undefined;
        vectors.fillNested(&bytes, levels);
        const final = bytes;
        return &final;
    }
}

const corpus = make: {
    @setEvalBranchQuota(1_000_000);
    var entries: []const []const u8 = &.{};
    for (vectors.valid) |vector| {
        entries = entries ++ .{ sample(vector.bson), sample(body(vector.bson)) };
    }
    for (vectors.broken) |vector| entries = entries ++ .{sample(vector.bytes)};
    entries = entries ++ .{
        sample(vectors.reply),
        sample(body(vectors.reply)),
        sample(vectors.empty),
        sample(nested(100)),
        sample(nested(101)),
        // Options out of order, which the builder sorts.
        sample(vectors.hex("10000000 0b 6100 5e612e6300 6d6900 00")),
        // A code with scope inside an array, whose scope holds an array.
        sample(vectors.hex("2e000000 04 6100 26000000 0f 3000 1e000000 02000000 7800 14000000 04 7800 0c000000 10 3000 01000000 00 00 00 00")),
        // A key and a string that are not UTF-8.
        sample(vectors.hex("10000000 02 61ff00 03000000 c3ff00 00")),
    };
    break :make entries;
};

test "fuzz the reader" {
    try testing.fuzz({}, fuzzReader, .{ .corpus = corpus });
}
