//! The JSON reader of the header and the payload. Its tokens come from
//! `std.json.Scanner`, which holds the text to RFC 8259 and refuses
//! invalid UTF-8 and unpaired surrogates; any error of the scanner,
//! nesting deeper than `max_json_depth` and anything but white space
//! after the top value are `Malformed`.

const std = @import("std");
const root = @import("root.zig");

pub const Reader = struct {
    scanner: std.json.Scanner,
    arena: std.mem.Allocator,

    pub const Error = error{ Malformed, OutOfMemory };

    /// A reader of `bytes`. The strings it returns point into `bytes`, or
    /// into `arena` when they had escapes; the scanner's stack lives there
    /// too.
    pub fn init(arena: std.mem.Allocator, bytes: []const u8) Reader {
        return .{ .scanner = .initCompleteInput(arena, bytes), .arena = arena };
    }

    /// The kind of the next token, which stays unread.
    pub fn peek(r: *Reader) Error!std.json.TokenType {
        return r.scanner.peekNextTokenType() catch error.Malformed;
    }

    /// Reads the `{` of an object: the top value, or the value of a key.
    pub fn beginObject(r: *Reader) Error!void {
        if (try r.peek() != .object_begin) return error.Malformed;
        _ = try r.next();
        try r.deeper();
    }

    /// The next key of the object being read, its escapes decoded; null
    /// at the object's end, whose `}` it reads. The caller reads or skips
    /// the key's value before the next key.
    pub fn nextKey(r: *Reader) Error!?[]const u8 {
        return switch (try r.next()) {
            .object_end => null,
            .string => |text| text,
            .allocated_string => |text| text,
            else => error.Malformed,
        };
    }

    /// The next value, which must be a string, its escapes decoded.
    pub fn string(r: *Reader) Error![]const u8 {
        if (try r.peek() != .string) return error.Malformed;
        return switch (try r.next()) {
            .string => |text| text,
            .allocated_string => |text| text,
            else => error.Malformed,
        };
    }

    /// The next value, which must be a number: its text as the JSON
    /// writes it, such as "-1.5e3".
    pub fn number(r: *Reader) Error![]const u8 {
        if (try r.peek() != .number) return error.Malformed;
        return switch (try r.next()) {
            .number => |text| text,
            .allocated_number => |text| text,
            else => error.Malformed,
        };
    }

    /// The next value, which must be `true` or `false`.
    pub fn boolean(r: *Reader) Error!bool {
        return switch (try r.peek()) {
            .true, .false => try r.next() == .true,
            else => error.Malformed,
        };
    }

    /// Whether the next value is `null`; if it is, it is read.
    pub fn isNull(r: *Reader) Error!bool {
        if (try r.peek() != .null) return false;
        _ = try r.next();
        return true;
    }

    /// Reads the `[` of an array; `nextItem` walks its items.
    pub fn beginArray(r: *Reader) Error!void {
        if (try r.peek() != .array_begin) return error.Malformed;
        _ = try r.next();
        try r.deeper();
    }

    /// The number of items of the array that `beginArray` has just opened,
    /// counted ahead by a reader of its own, which walks the array once
    /// without allocating, so that a list takes the memory of its items
    /// alone. Malformed JSON counts as nothing: this reader then refuses it.
    pub fn countItems(r: *const Reader) Error!usize {
        const at = r.scanner.cursor;
        if (at == 0 or at > r.scanner.input.len or r.scanner.input[at - 1] != '[') return error.Malformed;
        // The scanner's stack, a bit per level: within max_json_depth it
        // stays in its first allocation.
        var stack: [256]u8 = undefined;
        var memory: std.heap.FixedBufferAllocator = .init(&stack);
        var ahead: Reader = .init(memory.allocator(), r.scanner.input[at - 1 ..]);
        try ahead.beginArray();
        var count: usize = 0;
        while (try ahead.nextItem()) : (count += 1) try ahead.skip();
        return count;
    }

    /// Whether the array being read has another item, which the caller
    /// then reads or skips; false at the array's end, whose `]` it reads.
    pub fn nextItem(r: *Reader) Error!bool {
        if (try r.peek() != .array_end) return true;
        _ = try r.next();
        return false;
    }

    /// Past the next value, whatever it holds. Its nesting counts toward
    /// `max_json_depth` as if it were read.
    pub fn skip(r: *Reader) Error!void {
        switch (try r.peek()) {
            .object_end, .array_end, .end_of_document => return error.Malformed,
            else => {},
        }
        const height = r.scanner.stackHeight();
        while (true) {
            const token = r.scanner.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Malformed,
            };
            switch (token) {
                .object_begin, .array_begin => try r.deeper(),
                .partial_number,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => continue,
                .end_of_document => return error.Malformed,
                else => {},
            }
            if (r.scanner.stackHeight() == height) return;
        }
    }

    /// After the top value: only white space may follow it.
    pub fn finish(r: *Reader) Error!void {
        if (try r.next() != .end_of_document) return error.Malformed;
    }

    /// The next token, a string or a number whole.
    fn next(r: *Reader) Error!std.json.Token {
        return r.scanner.nextAllocMax(r.arena, .alloc_if_needed, std.math.maxInt(usize)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Malformed,
        };
    }

    /// Just after a `{` or a `[`: one level deeper, which must stay within
    /// `max_json_depth`; the top value is level 1.
    fn deeper(r: *Reader) Error!void {
        if (r.scanner.stackHeight() > root.max_json_depth) return error.Malformed;
    }
};

const testing = std.testing;

test "the reader walks one object and skips what it does not read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Reader = .init(arena_state.allocator(), " {\"a\": \"x\", \"b\": [1, {\"c\": null}, \"\x5cu0041\"], \"d\": \"e\x5cu0066\", \"\x5cu0067\": true} ");
    try r.beginObject();
    try testing.expectEqualStrings("a", (try r.nextKey()).?);
    try testing.expectEqual(.string, try r.peek());
    try testing.expectEqualStrings("x", try r.string());
    try testing.expectEqualStrings("b", (try r.nextKey()).?);
    try r.skip();
    try testing.expectEqualStrings("d", (try r.nextKey()).?);
    try testing.expectEqualStrings("ef", try r.string());
    try testing.expectEqualStrings("g", (try r.nextKey()).?);
    try testing.expectEqual(.true, try r.peek());
    try r.skip();
    try testing.expectEqual(null, try r.nextKey());
    try r.finish();
}

test "a value of another kind, broken JSON and text after the value are Malformed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var not_string: Reader = .init(arena, "{\"a\":5}");
    try not_string.beginObject();
    _ = try not_string.nextKey();
    try testing.expectError(error.Malformed, not_string.string());

    for ([_][]const u8{ "[]", "\"x\"", "5", "null", "", " ", "\xef\xbb\xbf{}" }) |text| {
        var r: Reader = .init(arena, text);
        try testing.expectError(error.Malformed, r.beginObject());
    }

    var trailing: Reader = .init(arena, "{} x");
    try trailing.beginObject();
    try testing.expectEqual(null, try trailing.nextKey());
    try testing.expectError(error.Malformed, trailing.finish());

    var unclosed: Reader = .init(arena, "{\"a\":[1,2}");
    try unclosed.beginObject();
    _ = try unclosed.nextKey();
    try testing.expectError(error.Malformed, unclosed.skip());

    var at_end: Reader = .init(arena, "{}");
    try at_end.beginObject();
    try testing.expectError(error.Malformed, at_end.skip());
}

test "numbers, booleans, null and arrays" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Reader = .init(arena_state.allocator(), "{\"n\":-1.5e3,\"t\":true,\"f\":false,\"z\":null,\"a\":[1,[]],\"s\":\"x\"}");
    try r.beginObject();
    _ = try r.nextKey();
    try testing.expectEqualStrings("-1.5e3", try r.number());
    _ = try r.nextKey();
    try testing.expect(try r.boolean());
    _ = try r.nextKey();
    try testing.expect(!try r.isNull());
    try testing.expect(!try r.boolean());
    _ = try r.nextKey();
    try testing.expect(try r.isNull());
    _ = try r.nextKey();
    try r.beginArray();
    try testing.expect(try r.nextItem());
    try testing.expectEqualStrings("1", try r.number());
    try testing.expect(try r.nextItem());
    try r.beginArray();
    try testing.expect(!try r.nextItem());
    try testing.expect(!try r.nextItem());
    _ = try r.nextKey();
    try testing.expectError(error.Malformed, r.number());
    try testing.expectError(error.Malformed, r.boolean());
    try testing.expectError(error.Malformed, r.beginArray());
    try testing.expectEqualStrings("x", try r.string());
    try testing.expectEqual(null, try r.nextKey());
    try r.finish();
}

test "countItems counts the items of the array just opened" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r: Reader = .init(arena, "{\"a\": [1, [2, 3], {\"b\": [4]}, \"x,]\x5c\"\"], \"c\": [ ], \"d\": [1,");
    try r.beginObject();
    _ = try r.nextKey();
    try r.beginArray();
    try testing.expectEqual(4, try r.countItems());
    // The count reads nothing of the array for this reader.
    try testing.expectEqualStrings("1", try r.number());
    try testing.expect(try r.nextItem());
    try r.beginArray();
    try testing.expectEqual(2, try r.countItems());
    while (try r.nextItem()) try r.skip();
    for (0..2) |_| {
        try testing.expect(try r.nextItem());
        try r.skip();
    }
    try testing.expect(!try r.nextItem());
    _ = try r.nextKey();
    try r.beginArray();
    try testing.expectEqual(0, try r.countItems());
    try testing.expect(!try r.nextItem());
    _ = try r.nextKey();
    try r.beginArray();
    try testing.expectError(error.Malformed, r.countItems());

    // Only just after the `[` of beginArray.
    var at_object: Reader = .init(arena, "{\"a\":[]}");
    try at_object.beginObject();
    try testing.expectError(error.Malformed, at_object.countItems());
}

/// `{"x":` and `arrays` arrays inside each other, then `}`.
fn nested(arena: std.mem.Allocator, arrays: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"x\":");
    try out.appendNTimes(arena, '[', arrays);
    try out.appendNTimes(arena, ']', arrays);
    try out.append(arena, '}');
    return out.items;
}

test "the top object counts as one level of max_json_depth" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var deepest: Reader = .init(arena, try nested(arena, root.max_json_depth - 1));
    try deepest.beginObject();
    _ = try deepest.nextKey();
    try deepest.skip();
    try testing.expectEqual(null, try deepest.nextKey());
    try deepest.finish();

    var too_deep: Reader = .init(arena, try nested(arena, root.max_json_depth));
    try too_deep.beginObject();
    _ = try too_deep.nextKey();
    try testing.expectError(error.Malformed, too_deep.skip());

    // An array read by beginArray counts the same.
    var read_deep: Reader = .init(arena, try nested(arena, root.max_json_depth));
    try read_deep.beginObject();
    _ = try read_deep.nextKey();
    for (0..root.max_json_depth - 1) |_| try read_deep.beginArray();
    try testing.expectError(error.Malformed, read_deep.beginArray());
}
