//! Tests of `FakeServer.Reply` without a server: the bytes of each kind of
//! reply, read back by the client's own reader, and the replies that break
//! RESP3.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const reply = @import("reply.zig");

const Reply = reply.Reply;
const Value = resp.Value;

/// The bytes of `r`; the caller frees them with `testing.allocator`.
fn written(r: Reply) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try reply.write(&out.writer, r);
    return out.toOwnedSlice();
}

fn expectBytes(expected: []const u8, r: Reply) !void {
    const bytes = try written(r);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

/// Reads the bytes of `r` back as replies, as the client reads them, into
/// `values`, and checks that they end where the bytes do.
fn readBack(arena: std.mem.Allocator, r: Reply, values: []Value) !void {
    const bytes = try written(r);
    defer testing.allocator.free(bytes);
    var in: std.Io.Reader = .fixed(bytes);
    for (values) |*value| {
        var reader: resp.Reader = .init(&in, 1 << 20);
        value.* = try resp.readValue(&reader, arena);
        try testing.expect(reader.done());
    }
    try testing.expectEqual(bytes.len, in.seek);
}

test "each reply as the bytes of RESP3" {
    try expectBytes("+OK\r\n", .ok);
    try expectBytes("_\r\n", .nil);
    try expectBytes(":-3\r\n", .{ .integer = -3 });
    try expectBytes(":9223372036854775807\r\n", .{ .integer = std.math.maxInt(i64) });
    try expectBytes("$3\r\nAnn\r\n", .{ .string = "Ann" });
    // An empty string is a value: `$0`, not a null.
    try expectBytes("$0\r\n\r\n", .{ .string = "" });
    // Any byte goes out as it is.
    try expectBytes("$6\r\na\r\nb\x00c\r\n", .{ .string = "a\r\nb\x00c" });
    try expectBytes(",12.5\r\n", .{ .double = 12.5 });
    try expectBytes(",inf\r\n", .{ .double = std.math.inf(f64) });
    try expectBytes(",-inf\r\n", .{ .double = -std.math.inf(f64) });
    try expectBytes(",nan\r\n", .{ .double = std.math.nan(f64) });
    try expectBytes("#t\r\n", .{ .boolean = true });
    try expectBytes("#f\r\n", .{ .boolean = false });
    try expectBytes("*2\r\n+OK\r\n_\r\n", .{ .array = &.{ .ok, .nil } });
    try expectBytes("*0\r\n", .{ .array = &.{} });
    try expectBytes("~2\r\n$1\r\na\r\n$1\r\nb\r\n", .{ .set = &.{ .{ .string = "a" }, .{ .string = "b" } } });
    try expectBytes("%1\r\n$1\r\na\r\n:1\r\n", .{ .pairs = &.{.{ .{ .string = "a" }, .{ .integer = 1 } }} });
    try expectBytes(">2\r\n$4\r\npong\r\n$0\r\n\r\n", .{ .push = &.{ .{ .string = "pong" }, .{ .string = "" } } });
    try expectBytes(
        "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n",
        .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" },
    );
    try expectBytes("+PONG\r\n", .{ .raw = "+PONG\r\n" });
    try expectBytes("*2\r\n:1\r\n*1\r\n%0\r\n", .{ .array = &.{ .{ .integer = 1 }, .{ .array = &.{.{ .pairs = &.{} }} } } });
}

test "the helpers: a map of strings, the confirmations of SUBSCRIBE, a message to a subscriber" {
    try expectBytes("%1\r\n$4\r\nname\r\n$3\r\nAnn\r\n", .map(&.{.{ "name", "Ann" }}));
    try expectBytes(
        "%2\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n",
        .map(&.{ .{ "name", "Ann" }, .{ "age", "30" } }),
    );
    try expectBytes(
        ">3\r\n$9\r\nsubscribe\r\n$6\r\norders\r\n:1\r\n>3\r\n$9\r\nsubscribe\r\n$4\r\nnews\r\n:2\r\n",
        .subscribed(&.{ "orders", "news" }),
    );
    try expectBytes(">3\r\n$7\r\nmessage\r\n$6\r\norders\r\n$3\r\nnew\r\n", .message("orders", "new"));
    // A channel and a message are bytes, `\r\n` and `\x00` included.
    try expectBytes(">3\r\n$7\r\nmessage\r\n$4\r\no\r\ns\r\n$3\r\nn\x00w\r\n", .message("o\r\ns", "n\x00w"));
}

test "each well-formed reply reads back through the client's reader as the value it means" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { Reply, Value };
    const cases = [_]Case{
        .{ .ok, .{ .string = "OK" } },
        .{ .nil, .null },
        .{ .{ .integer = -3 }, .{ .integer = -3 } },
        .{ .{ .string = "" }, .{ .string = "" } },
        .{ .{ .string = "a\r\nb\x00c" }, .{ .string = "a\r\nb\x00c" } },
        .{ .{ .double = 12.5 }, .{ .double = 12.5 } },
        .{ .{ .double = -std.math.inf(f64) }, .{ .double = -std.math.inf(f64) } },
        .{ .{ .boolean = false }, .{ .boolean = false } },
        .{ .{ .array = &.{ .ok, .nil } }, .{ .array = &.{ .{ .string = "OK" }, .null } } },
        .{ .{ .set = &.{.{ .integer = 7 }} }, .{ .set = &.{.{ .integer = 7 }} } },
        .{
            .{ .pairs = &.{ .{ .{ .string = "b" }, .{ .integer = 2 } }, .{ .{ .string = "a" }, .nil } } },
            .{ .map = &.{
                .{ .key = .{ .string = "b" }, .value = .{ .integer = 2 } },
                .{ .key = .{ .string = "a" }, .value = .null },
            } },
        },
        // A push reads as an array.
        .{ .{ .push = &.{ .{ .string = "pong" }, .{ .string = "" } } }, .{ .array = &.{ .{ .string = "pong" }, .{ .string = "" } } } },
        .{
            .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" },
            .{ .err = .{ .code = "WRONGTYPE", .message = "WRONGTYPE Operation against a key holding the wrong kind of value" } },
        },
        .{ .{ .raw = "=8\r\ntxt:text\r\n" }, .{ .string = "text" } },
        .{ .map(&.{.{ "name", "Ann" }}), .{ .map = &.{.{ .key = .{ .string = "name" }, .value = .{ .string = "Ann" } }} } },
        .{ .message("orders", "new"), .{ .array = &.{ .{ .string = "message" }, .{ .string = "orders" }, .{ .string = "new" } } } },
    };
    for (cases) |case| {
        var value: [1]Value = undefined;
        readBack(a, case[0], &value) catch |err| {
            std.debug.print("reply: {any}\n", .{case[0]});
            return err;
        };
        testing.expectEqualDeep(case[1], value[0]) catch |err| {
            std.debug.print("reply: {any}\n", .{case[0]});
            return err;
        };
    }

    // The confirmations of two channels are two replies.
    var confirmations: [2]Value = undefined;
    try readBack(a, .subscribed(&.{ "orders", "news" }), &confirmations);
    try testing.expectEqualDeep(Value{ .array = &.{ .{ .string = "subscribe" }, .{ .string = "orders" }, .{ .integer = 1 } } }, confirmations[0]);
    try testing.expectEqualDeep(Value{ .array = &.{ .{ .string = "subscribe" }, .{ .string = "news" }, .{ .integer = 2 } } }, confirmations[1]);

    // A double reads back bit for bit, and NaN as NaN.
    for ([_]f64{ 0.1, 1e300, 5e-324, -0.0, std.math.floatMax(f64), std.math.nan(f64) }) |x| {
        var value: [1]Value = undefined;
        try readBack(a, .{ .double = x }, &value);
        if (value[0] != .double) return error.TestNotADouble;
        if (std.math.isNan(x)) {
            try testing.expect(std.math.isNan(value[0].double));
        } else {
            try testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(value[0].double)));
        }
    }
}

test "each malformed reply breaks RESP3: the client reads a protocol violation, or the end of its input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    inline for (@typeInfo(reply.Malformed).@"enum".field_names) |name| {
        const defect = @field(reply.Malformed, name);
        const bytes = try written(.{ .malformed = defect });
        defer testing.allocator.free(bytes);
        var in: std.Io.Reader = .fixed(bytes);
        var reader: resp.Reader = .init(&in, 1 << 20);
        const read = resp.readValue(&reader, arena.allocator());
        switch (defect) {
            .unknown_type, .bad_length => try testing.expectError(error.ProtocolViolation, read),
            .truncated => try testing.expectError(error.EndOfStream, read),
        }
    }
    // A malformed element breaks the reply that holds it.
    const bytes = try written(.{ .array = &.{ .{ .integer = 1 }, .{ .malformed = .unknown_type } } });
    defer testing.allocator.free(bytes);
    var in: std.Io.Reader = .fixed(bytes);
    var reader: resp.Reader = .init(&in, 1 << 20);
    try testing.expectError(error.ProtocolViolation, resp.readValue(&reader, arena.allocator()));
}

test "a delay, a close or a refusal inside an aggregate is written as an error in its place" {
    const late: Reply = .ok;
    try expectBytes(
        "*2\r\n:1\r\n-ERR zefir FakeServer: a delayed reply inside an aggregate: delays, closing and refusing act on a whole reply\r\n",
        .{ .array = &.{ .{ .integer = 1 }, .{ .delayed = .{ .after = .fromMilliseconds(10), .reply = &late } } } },
    );
    try expectBytes(
        "*1\r\n-ERR zefir FakeServer: close_connection inside an aggregate: delays, closing and refusing act on a whole reply\r\n",
        .{ .array = &.{.close_connection} },
    );
    try expectBytes(
        "~1\r\n-ERR zefir FakeServer: refuse_connections inside an aggregate: delays, closing and refusing act on a whole reply\r\n",
        .{ .set = &.{.refuse_connections} },
    );
}
