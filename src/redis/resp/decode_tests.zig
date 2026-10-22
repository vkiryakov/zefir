//! Tests of the decoder: each type a reply reads into against each kind of
//! frame of the design's §3.3, server errors at the top and inside an
//! array, and what happens after a reply does not fit: the reply is read
//! to its end without memory, and the next one reads.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const frames = @import("frames.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const Reader = resp.Reader;
const Value = resp.Value;

/// The reply after each one of these tests: it must read whole once the
/// decoder is done, whatever it returned.
const next_reply = "+OK\r\n";

fn expectNextReply(in: *std.Io.Reader) !void {
    var after: Reader = .init(in, 64);
    try testing.expectEqual(Reader.Element.simple_string, try after.next());
    var buffer: [2]u8 = undefined;
    try testing.expectEqualStrings("OK", (try after.payloadPrefix(&buffer)).bytes);
    try testing.expect(after.done());
    try testing.expectEqual(in.end, in.seek);
}

/// Reads the reply of `bytes` into `T`, with its memory in `arena`, and
/// checks that the next reply reads.
fn decodeOk(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) !T {
    const input = try std.mem.concat(testing.allocator, u8, &.{ bytes, next_reply });
    defer testing.allocator.free(input);
    var in: std.Io.Reader = .fixed(input);
    var reader: Reader = .init(&in, 1 << 20);
    var diagnostics: Diagnostics = .{};
    const result = resp.decode(T, &reader, arena, &diagnostics) catch |err| {
        std.debug.print("{s} into {s}: {t}: {s}\n", .{ bytes, @typeName(T), err, diagnostics.message() });
        return err;
    };
    try expectNextReply(&in);
    return result;
}

fn expectDecoded(comptime T: type, expected: T, bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try decodeOk(T, arena.allocator(), bytes);
    testing.expectEqualDeep(expected, got) catch |err| {
        std.debug.print("frame: {s}\n", .{bytes});
        return err;
    };
}

/// Reads the reply of `bytes` into `T` and expects `expected`. The decoder
/// may take `allocations` blocks of memory, for what it read before the
/// error, and not one more: the rest of the reply is skipped without
/// memory, and the next reply reads. Returns what the diagnostics say.
fn expectDecodeError(comptime T: type, expected: anyerror, bytes: []const u8, allocations: usize) !Diagnostics {
    const input = try std.mem.concat(testing.allocator, u8, &.{ bytes, next_reply });
    defer testing.allocator.free(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var failing: std.testing.FailingAllocator = .init(arena.allocator(), .{ .fail_index = allocations });
    var in: std.Io.Reader = .fixed(input);
    var reader: Reader = .init(&in, 1 << 20);
    var diagnostics: Diagnostics = .{};
    const result = resp.decode(T, &reader, failing.allocator(), &diagnostics);
    testing.expectError(expected, result) catch |err| {
        std.debug.print("frame: {s} into {s}\n", .{ bytes, @typeName(T) });
        return err;
    };
    try expectNextReply(&in);
    return diagnostics;
}

fn expectUnexpected(comptime T: type, bytes: []const u8) !void {
    const d = try expectDecodeError(T, error.UnexpectedReply, bytes, 0);
    try testing.expectEqualStrings("", d.code());
    try testing.expectEqual(@as(?Diagnostics.Phase, .receive), d.phase);
}

test "void takes any reply but an error, and drops it" {
    try expectDecoded(void, {}, "+OK\r\n");
    try expectDecoded(void, {}, ":1\r\n");
    try expectDecoded(void, {}, "_\r\n");
    try expectDecoded(void, {}, "*2\r\n*1\r\n:1\r\n%1\r\n$1\r\na\r\n~1\r\n-ERR inside\r\n");
    // Nothing is kept, so nothing is allocated.
    try expectDecoded(void, {}, "$5\r\nhello\r\n");
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    _ = try decodeOk(void, failing.allocator(), "*1\r\n$3\r\nabc\r\n");
}

test "bool takes #t and #f, the integers 1 and 0, and the strings 1 and 0" {
    try expectDecoded(bool, true, "#t\r\n");
    try expectDecoded(bool, false, "#f\r\n");
    try expectDecoded(bool, true, ":1\r\n");
    try expectDecoded(bool, false, ":0\r\n");
    try expectDecoded(bool, true, "$1\r\n1\r\n");
    try expectDecoded(bool, false, "$1\r\n0\r\n");
    try expectDecoded(bool, true, "+1\r\n");
    try expectUnexpected(bool, ":2\r\n");
    try expectUnexpected(bool, ":-1\r\n");
    try expectUnexpected(bool, "$4\r\ntrue\r\n");
    try expectUnexpected(bool, "$2\r\n10\r\n");
    try expectUnexpected(bool, "_\r\n");
}

test "an integer takes :, and $, + and ( with a decimal number in its range" {
    try expectDecoded(i64, 42, ":42\r\n");
    try expectDecoded(i64, 42, "$2\r\n42\r\n");
    try expectDecoded(i64, 42, "+42\r\n");
    try expectDecoded(i64, 42, "(42\r\n");
    try expectDecoded(i64, -7, "$2\r\n-7\r\n");
    try expectDecoded(i64, 0, "$1\r\n0\r\n");
    try expectDecoded(i64, std.math.minInt(i64), ":-9223372036854775808\r\n");
    try expectDecoded(i64, std.math.maxInt(i64), "(9223372036854775807\r\n");
    try expectDecoded(u64, std.math.maxInt(u64), "(18446744073709551615\r\n");
    try expectDecoded(u64, std.math.maxInt(u64), "$20\r\n18446744073709551615\r\n");
    try expectDecoded(u8, 255, ":255\r\n");
    try expectDecoded(i128, -170141183460469231731687303715884105728, "(-170141183460469231731687303715884105728\r\n");

    const d = try expectDecodeError(i64, error.UnexpectedReply, "$3\r\nabc\r\n", 0);
    try testing.expectEqualStrings("the reply is a bulk string of 3 bytes, and the call asked for i64", d.message());
    try expectUnexpected(i64, "(9223372036854775808\r\n");
    try expectUnexpected(i64, "$0\r\n\r\n");
    try expectUnexpected(u64, ":-1\r\n");
    try expectUnexpected(u8, ":300\r\n");
    try expectUnexpected(u8, "$3\r\n256\r\n");
    try expectUnexpected(i64, "$3\r\n042\r\n");
    try expectUnexpected(i64, "$2\r\n-0\r\n");
    try expectUnexpected(i64, "$3\r\n+42\r\n");
    try expectUnexpected(i64, "$4\r\n1_00\r\n");
    try expectUnexpected(i64, "$3\r\n 42\r\n");
    try expectUnexpected(i64, "$1\r\n-\r\n");
    try expectUnexpected(i64, ",1.5\r\n");
    try expectUnexpected(i64, "#t\r\n");
    try expectUnexpected(i64, "_\r\n");
    try expectUnexpected(i64, "*1\r\n:1\r\n");
    // A string longer than any i64 is refused whole, without memory.
    try expectUnexpected(i64, "$30\r\n123456789012345678901234567890\r\n");
    const u = try expectDecodeError(u8, error.UnexpectedReply, ":300\r\n", 0);
    try testing.expectEqualStrings("the reply is an integer, and the call asked for u8", u.message());
}

test "a float takes doubles, integers, and strings that hold a number" {
    try expectDecoded(f64, 1.5, ",1.5\r\n");
    try expectDecoded(f64, std.math.inf(f64), ",inf\r\n");
    try expectDecoded(f64, -std.math.inf(f64), ",-inf\r\n");
    try expectDecoded(f64, 1000, ",1e3\r\n");
    try expectDecoded(f64, 3, ",3\r\n");
    try expectDecoded(f64, 7, ":7\r\n");
    try expectDecoded(f64, 12.5, "$4\r\n12.5\r\n");
    try expectDecoded(f64, 12.5, "+12.5\r\n");
    try expectDecoded(f64, -2.5e-3, "$7\r\n-2.5e-3\r\n");
    try expectDecoded(f64, std.math.inf(f64), "$3\r\ninf\r\n");
    try expectDecoded(f32, 0.1, "$3\r\n0.1\r\n");
    try expectDecoded(f32, 1.5, ",1.5\r\n");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(std.math.isNan(try decodeOk(f64, arena.allocator(), ",nan\r\n")));
    const zero = try decodeOk(f64, arena.allocator(), ",-0\r\n");
    try testing.expectEqual(0, zero);
    try testing.expect(std.math.signbit(zero));

    // A long text: INCRBYFLOAT writes large results without an exponent.
    const long = "1" ++ @as([300]u8, @splat('0'));
    try expectDecoded(f64, 1e300, std.fmt.comptimePrint("${d}\r\n{s}\r\n", .{ long.len, long }));

    try expectUnexpected(f64, "$3\r\nabc\r\n");
    try expectUnexpected(f64, "$2\r\n.5\r\n");
    try expectUnexpected(f64, "$4\r\n0x10\r\n");
    try expectUnexpected(f64, "$0\r\n\r\n");
    try expectUnexpected(f64, "(12\r\n");
    try expectUnexpected(f64, "#t\r\n");
    try expectUnexpected(f64, "_\r\n");
}

test "a string takes bulk, simple and verbatim strings, big numbers, and the text of numbers" {
    try expectDecoded([]const u8, "Ann", "$3\r\nAnn\r\n");
    try expectDecoded([]const u8, "OK", "+OK\r\n");
    try expectDecoded([]const u8, "Some string", "=15\r\ntxt:Some string\r\n");
    try expectDecoded([]const u8, "123", "(123\r\n");
    try expectDecoded([]const u8, "42", ":42\r\n");
    try expectDecoded([]const u8, "-42", ":-42\r\n");
    try expectDecoded([]const u8, "1.5", ",1.5\r\n");
    try expectDecoded([]const u8, "inf", ",inf\r\n");
    try expectDecoded([]const u8, "", "$0\r\n\r\n");
    try expectDecoded([]const u8, "a\r\nb\x00c", "$6\r\na\r\nb\x00c\r\n");
    try expectUnexpected([]const u8, "*1\r\n$1\r\na\r\n");
    try expectUnexpected([]const u8, "_\r\n");
    try expectUnexpected([]const u8, "#f\r\n");
    try expectUnexpected([]const u8, "%1\r\n+k\r\n+v\r\n");
}

test "an optional takes null, and the rest by its child; an empty string is not null" {
    try expectDecoded(?[]const u8, null, "_\r\n");
    try expectDecoded(?[]const u8, null, "$-1\r\n");
    try expectDecoded(?[]const u8, null, "*-1\r\n");
    try expectDecoded(?[]const u8, "", "$0\r\n\r\n");
    try expectDecoded(?[]const u8, "tok", "$3\r\ntok\r\n");
    try expectDecoded(?i64, null, "_\r\n");
    try expectDecoded(?i64, 3, ":3\r\n");
    try expectUnexpected(?i64, "$3\r\nabc\r\n");
}

const Plan = enum { free, pro };

test "an exhaustive enum takes the name of a tag, as + or $" {
    try expectDecoded(Plan, .pro, "+pro\r\n");
    try expectDecoded(Plan, .free, "$4\r\nfree\r\n");
    try expectDecoded(?Plan, null, "_\r\n");
    const d = try expectDecodeError(Plan, error.UnexpectedReply, "+PRO\r\n", 0);
    try testing.expectEqualStrings("the reply is a simple string of 3 bytes, and the call asked for resp.decode_tests.Plan", d.message());
    try expectUnexpected(Plan, "+enterprise\r\n");
    try expectUnexpected(Plan, "+pr\r\n");
    try expectUnexpected(Plan, "+\r\n");
    try expectUnexpected(Plan, ":1\r\n");
    try expectUnexpected(Plan, "=7\r\ntxt:pro\r\n");
}

test "a slice takes an array or a set, its elements by its child" {
    try expectDecoded([]const []const u8, &.{ "a", "b" }, "*2\r\n$1\r\na\r\n$1\r\nb\r\n");
    try expectDecoded([]const []const u8, &.{ "a", "b" }, "~2\r\n$1\r\na\r\n+b\r\n");
    try expectDecoded([]const []const u8, &.{}, "*0\r\n");
    try expectDecoded([]const ?[]const u8, &.{ "a", null }, "*2\r\n$1\r\na\r\n_\r\n");
    try expectDecoded([]const i64, &.{ 1, -2, 3 }, "*3\r\n:1\r\n$2\r\n-2\r\n+3\r\n");
    try expectDecoded([]const []const i64, &.{ &.{1}, &.{}, &.{ 2, 3 } }, "*3\r\n*1\r\n:1\r\n*0\r\n~2\r\n:2\r\n:3\r\n");

    // The null, the second element, comes after the slice of two and the
    // copy of "a": those two blocks and no more.
    const d = try expectDecodeError([]const []const u8, error.UnexpectedReply, "*2\r\n$1\r\na\r\n_\r\n", 2);
    try testing.expectEqualStrings("the reply holds a null where the call asked for []const u8", d.message());
    _ = try expectDecodeError([]const []const u8, error.UnexpectedReply, "*3\r\n_\r\n$1\r\na\r\n*2\r\n:1\r\n:2\r\n", 1);
    try expectUnexpected([]const []const u8, "%1\r\n+k\r\n+v\r\n");
    try expectUnexpected([]const []const u8, "$1\r\na\r\n");
    try expectUnexpected([]const i64, "_\r\n");
}

test "an array takes an array or a set of exactly as many elements" {
    try expectDecoded([3]i64, .{ 1, 2, 3 }, "*3\r\n:1\r\n:2\r\n:3\r\n");
    try expectDecoded([2][]const u8, .{ "a", "b" }, "~2\r\n$1\r\na\r\n$1\r\nb\r\n");
    const d = try expectDecodeError([3]i64, error.UnexpectedReply, "*2\r\n:1\r\n:2\r\n", 0);
    try testing.expectEqualStrings("the reply is an array of 2 elements, and the call asked for [3]i64", d.message());
    try expectUnexpected([3]i64, "*4\r\n:1\r\n:2\r\n:3\r\n:4\r\n");
    try expectUnexpected([1]i64, "*1\r\n$1\r\nx\r\n");
}

const Pair = struct { []const u8, i64 };

test "a tuple takes an array of exactly as many elements, each by its type" {
    try expectDecoded(Pair, .{ "a", 1 }, "*2\r\n$1\r\na\r\n:1\r\n");
    try expectDecoded(struct { ?[]const u8, f64, bool }, .{ null, 2.5, true }, "*3\r\n_\r\n,2.5\r\n#t\r\n");
    const d = try expectDecodeError(Pair, error.UnexpectedReply, "*3\r\n$1\r\na\r\n:1\r\n:2\r\n", 0);
    try testing.expectEqualStrings("the reply is an array of 3 elements, and the call asked for struct { []const u8, i64 }", d.message());
    try expectUnexpected(Pair, "~2\r\n$1\r\na\r\n:1\r\n");
    _ = try expectDecodeError(Pair, error.UnexpectedReply, "*2\r\n$1\r\na\r\n$1\r\nb\r\n", 1);
}

test "redis.Value takes every frame but an error at the top" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (frames.valid) |case| {
        const bytes = case[0];
        var expected_in: std.Io.Reader = .fixed(bytes);
        var expected_reader: Reader = .init(&expected_in, 1 << 20);
        const expected = try resp.readValue(&expected_reader, arena.allocator());
        if (expected == .err) {
            _ = try expectDecodeError(Value, error.ServerError, bytes, 0);
            continue;
        }
        const got = try decodeOk(Value, arena.allocator(), bytes);
        if (expected == .double and std.math.isNan(expected.double)) {
            try testing.expect(got == .double);
            try testing.expect(std.math.isNan(got.double));
            continue;
        }
        testing.expectEqualDeep(expected, got) catch |err| {
            std.debug.print("frame: {s}\n", .{bytes});
            return err;
        };
    }
    // Inside an aggregate, an error is a value of its own.
    try expectDecoded(Value, .{ .array = &.{ .{ .integer = 1 }, .{ .err = .{ .code = "ERR", .message = "ERR boom" } } } }, "*2\r\n:1\r\n-ERR boom\r\n");
    try expectDecoded([]const Value, &.{ .{ .string = "a" }, .null }, "*2\r\n$1\r\na\r\n_\r\n");
}

test "an error at the top is ServerError for every type, with its code and text" {
    const wrongtype = "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n";
    const syntax = "!21\r\nSYNTAX invalid syntax\r\n";
    inline for (.{ void, bool, i64, u8, f64, []const u8, ?[]const u8, Plan, ?Plan, []const []const u8, [3]i64, struct { []const u8, i64 }, Value, []const Value }) |T| {
        const d = try expectDecodeError(T, error.ServerError, wrongtype, 0);
        try testing.expectEqualStrings("WRONGTYPE", d.code());
        try testing.expectEqualStrings("WRONGTYPE Operation against a key holding the wrong kind of value", d.message());
        try testing.expectEqual(@as(?Diagnostics.Phase, .receive), d.phase);
        const blob = try expectDecodeError(T, error.ServerError, syntax, 0);
        try testing.expectEqualStrings("SYNTAX", blob.code());
        try testing.expectEqualStrings("SYNTAX invalid syntax", blob.message());
    }
}

test "an error inside an array is ServerError with its code, and the reply is read to its end" {
    // One block: the slice of two.
    const d = try expectDecodeError([]const i64, error.ServerError, "*2\r\n:1\r\n-ERR boom\r\n", 1);
    try testing.expectEqualStrings("ERR", d.code());
    try testing.expectEqualStrings("ERR boom", d.message());
    const after = try expectDecodeError([]const i64, error.ServerError, "*3\r\n-ERR first\r\n*2\r\n:1\r\n:2\r\n$3\r\nabc\r\n", 1);
    try testing.expectEqualStrings("ERR first", after.message());
    const nested = try expectDecodeError([]const []const i64, error.ServerError, "*2\r\n*1\r\n:1\r\n*1\r\n!3\r\nOOM\r\n", 3);
    try testing.expectEqualStrings("OOM", nested.code());
    _ = try expectDecodeError(struct { i64, []const u8 }, error.ServerError, "*2\r\n:1\r\n-NOPERM no\r\n", 0);
    _ = try expectDecodeError(?i64, error.ServerError, "-ERR x\r\n", 0);
}

test "without diagnostics, an error still reads the reply to its end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = "*2\r\n-ERR boom\r\n$3\r\nabc\r\n" ++ next_reply;
    var in: std.Io.Reader = .fixed(bytes);
    var reader: Reader = .init(&in, 1 << 20);
    try testing.expectError(error.ServerError, resp.decode([]const i64, &reader, arena.allocator(), null));
    try expectNextReply(&in);
    var again: std.Io.Reader = .fixed("$3\r\nabc\r\n" ++ next_reply);
    var reader_again: Reader = .init(&again, 1 << 20);
    try testing.expectError(error.UnexpectedReply, resp.decode(i64, &reader_again, null, null));
    try expectNextReply(&again);
}

test "a reply that needs memory and has no allocator is OutOfMemory" {
    var in: std.Io.Reader = .fixed("$3\r\nabc\r\n");
    var reader: Reader = .init(&in, 1 << 20);
    try testing.expectError(error.OutOfMemory, resp.decode([]const u8, &reader, null, null));
    var value_in: std.Io.Reader = .fixed(":1\r\n");
    var value_reader: Reader = .init(&value_in, 1 << 20);
    try testing.expectError(error.OutOfMemory, resp.decode(Value, &value_reader, null, null));
}

test "an error of RESP3 itself is the reader's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: std.Io.Reader = .fixed("*2\r\n:1\r\n@\r\n");
    var reader: Reader = .init(&in, 1 << 20);
    try testing.expectError(error.ProtocolViolation, resp.decode([]const i64, &reader, arena.allocator(), null));
    var big: std.Io.Reader = .fixed("$100\r\n");
    var small: Reader = .init(&big, 64);
    try testing.expectError(error.ReplyTooLarge, resp.decode([]const u8, &small, arena.allocator(), null));
}

test "the texts of UnexpectedReply name kinds and sizes, never values" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "$6\r\nsecret\r\n", "the reply is a bulk string of 6 bytes, and the call asked for i64" },
        .{ "+secret\r\n", "the reply is a simple string of 6 bytes, and the call asked for i64" },
        .{ "=10\r\ntxt:secret\r\n", "the reply is a verbatim string of 6 bytes, and the call asked for i64" },
        .{ "$1\r\nx\r\n", "the reply is a bulk string of 1 byte, and the call asked for i64" },
        .{ "_\r\n", "the reply is a null, and the call asked for i64" },
        .{ "#t\r\n", "the reply is a boolean, and the call asked for i64" },
        .{ ",1.5\r\n", "the reply is a double, and the call asked for i64" },
        .{ "(99999999999999999999\r\n", "the reply is a big number, and the call asked for i64" },
        .{ "*1\r\n:1\r\n", "the reply is an array of 1 element, and the call asked for i64" },
        .{ "%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n", "the reply is a map of 2 pairs, and the call asked for i64" },
        .{ "~0\r\n", "the reply is a set of 0 elements, and the call asked for i64" },
    };
    for (cases) |case| {
        const d = try expectDecodeError(i64, error.UnexpectedReply, case[0], 0);
        testing.expectEqualStrings(case[1], d.message()) catch |err| {
            std.debug.print("frame: {s}\n", .{case[0]});
            return err;
        };
    }
}

test "needsAllocator tells which types take memory" {
    comptime {
        for ([_]type{ i64, u8, bool, f64, void, Plan, ?i64, [3]i64, struct { i64, bool } }) |T| {
            std.debug.assert(!resp.needsAllocator(T));
        }
        const Profile = struct { name: []const u8, age: u8 };
        for ([_]type{ []const u8, ?[]const u8, []const i64, Value, []const Value, Profile, ?Profile, [2][]const u8, struct { i64, []const u8 } }) |T| {
            std.debug.assert(resp.needsAllocator(T));
        }
    }
}
