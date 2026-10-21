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
}
