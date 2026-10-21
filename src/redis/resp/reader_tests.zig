//! Tests of `resp.Reader`: every type of RESP3 frame by frame, what is
//! refused as a ProtocolViolation, the limits that come before memory,
//! skipping, and strings larger than the buffer of the reader under it.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const frames = @import("frames.zig");

const Reader = resp.Reader;
const Element = Reader.Element;

/// Room for any reply of these tests.
const roomy = 1 << 20;

/// Reads one reply from `bytes` and prints its shape: each element as
/// `kind(value)`, each aggregate as `kind[n](elements)`. The bytes of
/// strings are read into memory from `gpa`, and the reply must end where
/// the reader says it does: at the end of `bytes`. The caller frees the
/// result with `testing.allocator`.
fn shape(bytes: []const u8, budget: usize, gpa: std.mem.Allocator) ![]u8 {
    var in: std.Io.Reader = .fixed(bytes);
    var reader: Reader = .init(&in, budget);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    // How many elements each open aggregate still holds.
    var left: std.ArrayList(usize) = .empty;
    defer left.deinit(testing.allocator);
    while (true) {
        const element = try reader.next();
        var holds: ?usize = null;
        switch (element) {
            .null => try w.writeAll("null"),
            .boolean => |value| try w.print("boolean({})", .{value}),
            .integer => |value| try w.print("integer({d})", .{value}),
            .double => |value| try w.print("double({d})", .{value}),
            .simple_string, .simple_error, .big_number, .bulk_string, .bulk_error => {
                const text = try reader.payloadAlloc(gpa);
                defer gpa.free(text);
                try w.print("{t}({s})", .{ element, text });
            },
            .verbatim_string => |verbatim| {
                const text = try reader.payloadAlloc(gpa);
                defer gpa.free(text);
                try w.print("verbatim_string[{s}]({s})", .{ &verbatim.format, text });
            },
            .array, .set, .push => |n| {
                try w.print("{t}[{d}](", .{ element, n });
                holds = n;
            },
            .map => |n| {
                try w.print("map[{d}](", .{n});
                holds = 2 * n;
            },
        }
        if (holds) |n| {
            if (n > 0) {
                try left.append(testing.allocator, n);
                continue;
            }
            try w.writeAll(")");
        }
        // The element is whole: count it in the aggregates that hold it.
        while (left.items.len > 0) {
            const last = &left.items[left.items.len - 1];
            last.* -= 1;
            if (last.* > 0) {
                try w.writeAll(" ");
                break;
            }
            _ = left.pop();
            try w.writeAll(")");
        }
        if (left.items.len == 0) break;
    }
    try testing.expect(reader.done());
    try testing.expectEqual(bytes.len, in.seek);
    return out.toOwnedSlice();
}

fn expectShape(expected: []const u8, bytes: []const u8) !void {
    const got = try shape(bytes, roomy, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// `count` arrays of one element nested in each other around `:1`.
fn nested(count: usize) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(testing.allocator);
    for (0..count) |_| try bytes.appendSlice(testing.allocator, "*1\r\n");
    try bytes.appendSlice(testing.allocator, ":1\r\n");
    return bytes.toOwnedSlice(testing.allocator);
}

test "every type of RESP3, frame by frame" {
    for (frames.valid) |case| expectShape(case[1], case[0]) catch |err| {
        std.debug.print("frame: {s}\n", .{case[0]});
        return err;
    };
}

test "a double of -0 keeps its sign" {
    var in: std.Io.Reader = .fixed(",-0\r\n");
    var reader: Reader = .init(&in, roomy);
    const element = try reader.next();
    try testing.expect(element == .double);
    try testing.expect(std.math.signbit(element.double));
    try testing.expectEqual(0, element.double);
}

test "an empty bulk string is a string, not null" {
    var in: std.Io.Reader = .fixed("$0\r\n\r\n");
    var reader: Reader = .init(&in, roomy);
    try testing.expectEqual(Element{ .bulk_string = 0 }, try reader.next());
    const text = try reader.payloadAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
    try testing.expect(reader.done());
}

test "bytes that break RESP3 are a ProtocolViolation" {
    for (frames.broken) |bytes| {
        const result = shape(bytes, roomy, testing.allocator);
        if (result) |got| testing.allocator.free(got) else |_| {}
        testing.expectError(error.ProtocolViolation, result) catch |err| {
            std.debug.print("frame: {s}\n", .{bytes});
            return err;
        };
    }
}

test "a length line of 64 KiB and a byte, without CRLF, is a ProtocolViolation" {
    for ("$*") |tag| {
        const bytes = try testing.allocator.alloc(u8, 1 + 64 * 1024 + 1);
        defer testing.allocator.free(bytes);
        bytes[0] = tag;
        @memset(bytes[1..], '1');
        try testing.expectError(error.ProtocolViolation, shape(bytes, roomy, testing.allocator));
    }
}

test "replies over the budget or too deep are ReplyTooLarge before any memory is taken" {
    const failing = testing.failing_allocator;
    const hundred = &@as([100]u8, @splat('a'));
    try testing.expectError(error.ReplyTooLarge, shape("$100\r\n" ++ hundred ++ "\r\n", 64, failing));
    try testing.expectError(error.ReplyTooLarge, shape("+" ++ hundred ++ "\r\n", 64, failing));
    try testing.expectError(error.ReplyTooLarge, shape("*1000000\r\n", 64 * 1024, failing));
    try testing.expectError(error.ReplyTooLarge, shape("%30000\r\n", 64 * 1024, failing));

    const deepest = try nested(Reader.max_depth);
    defer testing.allocator.free(deepest);
    const got = try shape(deepest, roomy, failing);
    testing.allocator.free(got);

    const too_deep = try nested(Reader.max_depth + 1);
    defer testing.allocator.free(too_deep);
    try testing.expectError(error.ReplyTooLarge, shape(too_deep, roomy, failing));
    // An empty array one level too deep, in place of the integer.
    const empty_too_deep = try nested(Reader.max_depth);
    defer testing.allocator.free(empty_too_deep);
    @memcpy(empty_too_deep[empty_too_deep.len - 4 ..], "*0\r\n");
    try testing.expectError(error.ReplyTooLarge, shape(empty_too_deep, roomy, failing));

    // A Lua table can nest about 8000 levels deep: no recursion, no stack
    // overflow, just ReplyTooLarge.
    const lua = try nested(8000);
    defer testing.allocator.free(lua);
    try testing.expectError(error.ReplyTooLarge, shape(lua, roomy, failing));
}

test "skipping the rest of a reply takes no memory and stops at its end" {
    const first = "*3\r\n$1\r\na\r\n*1\r\n:1\r\n_\r\n";
    var in: std.Io.Reader = .fixed(first ++ "+OK\r\n");
    var reader: Reader = .init(&in, roomy);
    try testing.expectEqual(Element{ .array = 3 }, try reader.next());
    try reader.skipReply();
    try testing.expect(reader.done());
    try testing.expectEqual(first.len, in.seek);

    var after: Reader = .init(&in, roomy);
    try testing.expectEqual(Element.simple_string, try after.next());
    var buffer: [8]u8 = undefined;
    const prefix = try after.payloadPrefix(&buffer);
    try testing.expectEqualStrings("OK", prefix.bytes);
    try testing.expectEqual(2, prefix.len);
    try testing.expect(after.done());
}

test "skipReply on a fresh reader skips one whole reply" {
    const first = "%1\r\n+k\r\n*2\r\n|1\r\n+a\r\n+b\r\n$3\r\nabc\r\n(12\r\n";
    var in: std.Io.Reader = .fixed(first ++ ":1\r\n");
    var reader: Reader = .init(&in, roomy);
    try reader.skipReply();
    try testing.expect(reader.done());
    try testing.expectEqual(first.len, in.seek);
}

test "skipElement skips one element with all it holds" {
    var in: std.Io.Reader = .fixed("*3\r\n*2\r\n:1\r\n$2\r\nab\r\n-ERR x\r\n+x\r\n");
    var reader: Reader = .init(&in, roomy);
    try testing.expectEqual(Element{ .array = 3 }, try reader.next());
    try testing.expectEqual(Element{ .array = 2 }, try reader.next());
    try reader.skipElement();
    try testing.expectEqual(Element.simple_error, try reader.next());
    try reader.skipElement();
    try testing.expect(!reader.done());
    try testing.expectEqual(Element.simple_string, try reader.next());
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("x", (try reader.payloadPrefix(&buffer)).bytes);
    try testing.expect(reader.done());
}

test "payloadPrefix keeps the start of a string and skips the rest" {
    var in: std.Io.Reader = .fixed("*2\r\n-ERR unknown command 'FOO'\r\n$10\r\n0123456789\r\n");
    var reader: Reader = .init(&in, roomy);
    _ = try reader.next();
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(Element.simple_error, try reader.next());
    const err = try reader.payloadPrefix(&buffer);
    try testing.expectEqualStrings("ERR unkn", err.bytes);
    try testing.expectEqual(25, err.len);
    try testing.expectEqual(Element{ .bulk_string = 10 }, try reader.next());
    const bulk = try reader.payloadPrefix(&buffer);
    try testing.expectEqualStrings("01234567", bulk.bytes);
    try testing.expectEqual(10, bulk.len);
    try testing.expect(reader.done());
}

/// `bytes` through a reader of a 16 KiB buffer that gets 4 KiB at a time,
/// as from a socket.
const Socket = struct {
    buffer: [16 * 1024]u8 = undefined,
    calls: [1]std.testing.Reader.Call = undefined,
    source: std.testing.Reader = undefined,

    /// The socket must stay where it is while the reader is in use.
    fn init(s: *Socket, bytes: []const u8) *std.Io.Reader {
        s.calls = .{.{ .buffer = bytes }};
        s.source = .init(&s.buffer, &s.calls);
        s.source.artificial_limit = .limited(4096);
        return &s.source.interface;
    }
};

test "a bulk string larger than the buffer under the reader reads whole" {
    const value = try testing.allocator.alloc(u8, 20_000);
    defer testing.allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @truncate(i);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "$20000\r\n");
    try bytes.appendSlice(testing.allocator, value);
    try bytes.appendSlice(testing.allocator, "\r\n");

    var socket: Socket = .{};
    var reader: Reader = .init(socket.init(bytes.items), 64 * 1024);
    try testing.expectEqual(Element{ .bulk_string = 20_000 }, try reader.next());
    const read = try reader.payloadAlloc(testing.allocator);
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, value, read);
    try testing.expect(reader.done());

    // The same in pieces, as a subscriber copies a message.
    var again: Socket = .{};
    var chunked: Reader = .init(again.init(bytes.items), 64 * 1024);
    _ = try chunked.next();
    var copy: std.ArrayList(u8) = .empty;
    defer copy.deinit(testing.allocator);
    while (try chunked.payloadChunk()) |piece| try copy.appendSlice(testing.allocator, piece);
    try testing.expectEqualSlices(u8, value, copy.items);
    try testing.expect(chunked.done());
}

test "a simple string longer than the buffer under the reader reads whole" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.append(testing.allocator, '-');
    @memset(try bytes.addManyAsSlice(testing.allocator, 40_000), 'x');
    try bytes.appendSlice(testing.allocator, "\r\n:1\r\n");

    var socket: Socket = .{};
    const in = socket.init(bytes.items);
    var reader: Reader = .init(in, 64 * 1024);
    try testing.expectEqual(Element.simple_error, try reader.next());
    const text = try reader.payloadAlloc(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqual(40_000, text.len);
    try testing.expect(std.mem.allEqual(u8, text, 'x'));
    try testing.expect(reader.done());

    var after: Reader = .init(in, 64);
    try testing.expectEqual(Element{ .integer = 1 }, try after.next());
}

test "the end of the stream inside a reply is EndOfStream" {
    const cases = [_][]const u8{ "", "+OK", "+OK\r", "$3\r\nAn", "*2\r\n:1\r\n", "%1\r\n+k\r\n", ",1.5", ":12" };
    for (cases) |bytes| {
        const result = shape(bytes, roomy, testing.allocator);
        if (result) |got| testing.allocator.free(got) else |_| {}
        try testing.expectError(error.EndOfStream, result);
    }
}
