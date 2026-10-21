//! Tests of `cmd.raw` without a client: the bytes it writes, the reply it
//! reads, and the check before sending.

const std = @import("std");
const testing = std.testing;
const cmd = @import("../cmd.zig");
const contract = @import("contract.zig");
const resp = @import("../resp.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

/// The bytes that `command.write` gives. The caller frees them with
/// `testing.allocator`.
fn written(command: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try command.write(.init(&out.writer));
    return out.toOwnedSlice();
}

fn expectWritten(expected: []const u8, command: anytype) !void {
    try command.check(null);
    const bytes = try written(command);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

/// Reads the reply of `bytes` as `command` does.
fn readReply(command: anytype, bytes: []const u8) !@TypeOf(command).Reply {
    var in: std.Io.Reader = .fixed(bytes);
    var reader: resp.Reader = .init(&in, 1 << 20);
    const reply = try command.read(&reader, null, null);
    try testing.expectEqual(bytes.len, in.seek);
    return reply;
}

test "raw writes a tuple of strings and numbers as the command" {
    try expectWritten("*4\r\n$4\r\nZADD\r\n$7\r\nleaders\r\n$4\r\n12.5\r\n$3\r\nann\r\n", cmd.raw(i64, .{ "ZADD", "leaders", 12.5, "ann" }));
    const key: []const u8 = "views:/home";
    const by: i64 = -3;
    try expectWritten("*3\r\n$6\r\nINCRBY\r\n$11\r\nviews:/home\r\n$2\r\n-3\r\n", cmd.raw(i64, .{ "INCRBY", key, by }));
    // A list of strings in the tuple stands for as many arguments.
    const keys: []const []const u8 = &.{ "a", "b" };
    try expectWritten("*3\r\n$3\r\nDEL\r\n$1\r\na\r\n$1\r\nb\r\n", cmd.raw(u64, .{ "DEL", keys }));
    try expectWritten("*2\r\n$3\r\nSET\r\n$1\r\n1\r\n", cmd.raw(void, .{ "SET", true }));
}

test "raw writes a slice of strings built at run time" {
    var parts: [2][]const u8 = .{ "GET", "k" };
    const slice: []const []const u8 = &parts;
    try expectWritten("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", cmd.raw(?[]const u8, slice));
    try expectWritten("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", cmd.raw(?[]const u8, &parts));
}

test "the reply of raw reads into the type the call names" {
    const rank = cmd.raw(?i64, .{ "ZRANK", "leaders", "ann" });
    comptime std.debug.assert(@TypeOf(rank).Reply == ?i64);
    comptime std.debug.assert(contract.ReplyOf(@TypeOf(rank), "test") == ?i64);
    try testing.expectEqual(@as(?i64, null), try readReply(rank, "_\r\n"));
    try testing.expectEqual(@as(?i64, 3), try readReply(rank, ":3\r\n"));
    var d: Diagnostics = .{};
    var in: std.Io.Reader = .fixed("-WRONGTYPE Operation against a key holding the wrong kind of value\r\n");
    var reader: resp.Reader = .init(&in, 1 << 20);
    try testing.expectError(error.ServerError, rank.read(&reader, null, &d));
    try testing.expect(d.isCode("WRONGTYPE"));
}

test "raw without arguments, or with NaN, is InvalidArgument before anything is written" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, cmd.raw(i64, .{}).check(&d));
    try testing.expectEqualStrings("redis.cmd.raw: no arguments: the first is the name of the command", d.message());
    const none: []const []const u8 = &.{};
    try testing.expectError(error.InvalidArgument, cmd.raw(i64, none).check(null));
    const no_keys: []const []const u8 = &.{};
    try testing.expectError(error.InvalidArgument, cmd.raw(i64, .{no_keys}).check(null));

    const score: f64 = std.math.nan(f64);
    try testing.expectError(error.InvalidArgument, cmd.raw(i64, .{ "ZADD", "leaders", score, "ann" }).check(&d));
    try testing.expectEqualStrings("redis.cmd.raw: args[2] is NaN, which a server does not take", d.message());
    try testing.expectEqual(@as(?Diagnostics.Phase, null), d.phase);
}

test "a command value holds no state: written twice, it gives the same bytes" {
    const command = cmd.raw(i64, .{ "ZADD", "leaders", @as(f64, 0.1), "ann" });
    const first = try written(command);
    defer testing.allocator.free(first);
    const second = try written(command);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}
