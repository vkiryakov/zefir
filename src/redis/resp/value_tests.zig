//! Tests of `redis.Value`: every frame of RESP3 read whole into a value,
//! errors inside aggregates, the depth limit, and where the strings live.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");

const Value = resp.Value;
const Reader = resp.Reader;

/// Reads one reply from `bytes` into a value in `arena`, and checks that
/// the reply ends at the end of `bytes`.
fn read(arena: std.mem.Allocator, bytes: []const u8) !Value {
    var in: std.Io.Reader = .fixed(bytes);
    var reader: Reader = .init(&in, 1 << 20);
    const value = try resp.readValue(&reader, arena);
    try testing.expect(reader.done());
    try testing.expectEqual(bytes.len, in.seek);
    return value;
}

test "every frame of RESP3 as a Value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { []const u8, Value };
    const cases = [_]Case{
        .{ "+OK\r\n", .{ .string = "OK" } },
        .{ "-ERR unknown command 'FOO'\r\n", .{ .err = .{ .code = "ERR", .message = "ERR unknown command 'FOO'" } } },
        .{ ":-42\r\n", .{ .integer = -42 } },
        .{ "$3\r\nAnn\r\n", .{ .string = "Ann" } },
        .{ "$0\r\n\r\n", .{ .string = "" } },
        .{ "_\r\n", .null },
        .{ "$-1\r\n", .null },
        .{ "*-1\r\n", .null },
        .{ "#t\r\n", .{ .boolean = true } },
        .{ "#f\r\n", .{ .boolean = false } },
        .{ ",1.5\r\n", .{ .double = 1.5 } },
        .{ ",inf\r\n", .{ .double = std.math.inf(f64) } },
        .{ ",-inf\r\n", .{ .double = -std.math.inf(f64) } },
        .{ ",1e3\r\n", .{ .double = 1000 } },
        .{ ",3\r\n", .{ .double = 3 } },
        .{ "(3492890328409238509324850943850943825024385\r\n", .{ .big_number = "3492890328409238509324850943850943825024385" } },
        .{ "!21\r\nSYNTAX invalid syntax\r\n", .{ .err = .{ .code = "SYNTAX", .message = "SYNTAX invalid syntax" } } },
        .{ "=15\r\ntxt:Some string\r\n", .{ .string = "Some string" } },
        .{
            "*3\r\n:1\r\n*2\r\n+a\r\n$1\r\nb\r\n%1\r\n+k\r\n~2\r\n#t\r\n_\r\n",
            .{ .array = &.{
                .{ .integer = 1 },
                .{ .array = &.{ .{ .string = "a" }, .{ .string = "b" } } },
                .{ .map = &.{.{ .key = .{ .string = "k" }, .value = .{ .set = &.{ .{ .boolean = true }, .null } } }} },
            } },
        },
        // A map keeps the order the server sent.
        .{ "%2\r\n+b\r\n:2\r\n+a\r\n:1\r\n", .{ .map = &.{
            .{ .key = .{ .string = "b" }, .value = .{ .integer = 2 } },
            .{ .key = .{ .string = "a" }, .value = .{ .integer = 1 } },
        } } },
        .{ "*0\r\n", .{ .array = &.{} } },
        .{ "%0\r\n", .{ .map = &.{} } },
        .{ "~0\r\n", .{ .set = &.{} } },
        .{ "*2\r\n~0\r\n:7\r\n", .{ .array = &.{ .{ .set = &.{} }, .{ .integer = 7 } } } },
        // A push has no kind of its own in Value: it reads as an array.
        .{ ">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$3\r\nnew\r\n", .{ .array = &.{
            .{ .string = "message" }, .{ .string = "orders" }, .{ .string = "new" },
        } } },
        .{
            "|1\r\n+key-popularity\r\n%2\r\n$1\r\na\r\n,0.1923\r\n$1\r\nb\r\n,0.0012\r\n" ++
                "*2\r\n:2039123\r\n:9543892\r\n",
            .{ .array = &.{ .{ .integer = 2039123 }, .{ .integer = 9543892 } } },
        },
    };
    for (cases) |case| {
        const value = read(arena.allocator(), case[0]) catch |err| {
            std.debug.print("frame: {s}\n", .{case[0]});
            return err;
        };
        testing.expectEqualDeep(case[1], value) catch |err| {
            std.debug.print("frame: {s}\n", .{case[0]});
            return err;
        };
    }

    const nan = try read(arena.allocator(), ",nan\r\n");
    try testing.expect(nan == .double and std.math.isNan(nan.double));
    const minus_zero = try read(arena.allocator(), ",-0\r\n");
    try testing.expect(minus_zero == .double and minus_zero.double == 0 and std.math.signbit(minus_zero.double));
}

test "an error inside an array is a value, with its whole text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try read(arena.allocator(), "*2\r\n:1\r\n-ERR boom\r\n");
    try testing.expectEqualDeep(Value{ .array = &.{
        .{ .integer = 1 },
        .{ .err = .{ .code = "ERR", .message = "ERR boom" } },
    } }, value);
    // An error of one word is its own code.
    try testing.expectEqualDeep(Value{ .err = .{ .code = "NOSCRIPT", .message = "NOSCRIPT" } }, try read(arena.allocator(), "-NOSCRIPT\r\n"));
}

test "a Value nests up to the reader's depth, and no deeper" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]usize{ Reader.max_depth, Reader.max_depth + 1, 8000 }) |levels| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        for (0..levels) |_| try bytes.appendSlice(testing.allocator, "*1\r\n");
        try bytes.appendSlice(testing.allocator, ":1\r\n");
        if (levels > Reader.max_depth) {
            try testing.expectError(error.ReplyTooLarge, read(arena.allocator(), bytes.items));
            continue;
        }
        var value = try read(arena.allocator(), bytes.items);
        for (0..levels) |_| {
            try testing.expectEqual(1, value.array.len);
            value = value.array[0];
        }
        try testing.expectEqualDeep(Value{ .integer = 1 }, value);
    }
}

test "the strings of a Value live in the arena, not in the reader's buffer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const frame = "*4\r\n+simple\r\n$4\r\nbulk\r\n=8\r\ntxt:text\r\n(12\r\n";
    var bytes: [frame.len]u8 = frame.*;
    const value = try read(arena.allocator(), &bytes);
    @memset(&bytes, 'x');
    try testing.expectEqualDeep(Value{ .array = &.{
        .{ .string = "simple" },
        .{ .string = "bulk" },
        .{ .string = "text" },
        .{ .big_number = "12" },
    } }, value);
}

test "a Value can be read on from an element already read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: std.Io.Reader = .fixed("*2\r\n+a\r\n:1\r\n");
    var reader: Reader = .init(&in, 1024);
    const first = try reader.next();
    const value = try resp.readValueFrom(&reader, first, arena.allocator());
    try testing.expectEqualDeep(Value{ .array = &.{ .{ .string = "a" }, .{ .integer = 1 } } }, value);
    try testing.expect(reader.done());
}
