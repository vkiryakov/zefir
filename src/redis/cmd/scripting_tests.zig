//! Tests of the scripts of `redis.cmd` and of `redis.Script` against
//! `redis.testing.FakeServer`: the SHA1 of a script at comptime and at run
//! time; EVAL with its keys and arguments and what a script returns;
//! `evalScript` as EVALSHA in `run`, then EVAL on the same connection
//! after NOSCRIPT, and as EVAL at once in a pipeline and a transaction.
//! Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("../root.zig");
const cmd = redis.cmd;
const FakeServer = redis.testing.FakeServer;
const Fixture = @import("fixture.zig").Fixture;
const within5s = @import("../tests/time_limit.zig").within5s;

/// The functions of `redis.cmd` that this file tests, for the check that
/// every function of the catalog has a test.
pub const covered = [_][]const u8{ "eval", "evalScript" };

const return_one: redis.Script = .init("return 1");
const long: redis.Script = .init("-- " ++ @as([1024]u8, @splat('a')) ++ "\nreturn 1");

/// Takes a ticket while some are left: -1 when none is, else how many are
/// left.
const take_ticket: redis.Script = .init(
    \\local left = tonumber(redis.call('GET', KEYS[1]) or '0')
    \\if left <= 0 then return -1 end
    \\return redis.call('DECR', KEYS[1])
);

comptime {
    if (!std.mem.eql(u8, &return_one.sha1, "e0e1f9fabfc9d4800c877a703b823ac0578ff8db")) {
        @compileError("the SHA1 of return 1 at comptime is not the one of SCRIPT LOAD");
    }
}

test "the SHA1 of a script of a constant is computed at comptime, also for 1 KiB, and the same at run time for a text read then" {
    // A text in memory that only run time knows.
    var read: [8]u8 = "return 1".*;
    const made: redis.Script = .init(&read);
    try testing.expectEqualStrings("e0e1f9fabfc9d4800c877a703b823ac0578ff8db", &made.sha1);
    try testing.expectEqualStrings("return 1", made.source);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(long.source, &digest, .{});
    try testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), &long.sha1);
}

test "eval sends the text with the count of its keys, the keys and the arguments, and reads what the script returns: a number, a table, null, an error" {
    try within5s(testing.io, eval, .{testing.io});
}

fn eval(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "EVAL", "return 1", "0" }, .{ .integer = 1 }),
        .expect(.{ "EVAL", "return {KEYS[1], ARGV[1], ARGV[2]}", "1", "k", "7", "1.5" }, .{ .array = &.{ .{ .string = "k" }, .{ .string = "7" }, .{ .string = "1.5" } } }),
        .expect(.{ "EVAL", "return ARGV[1]", "2", "a", "b", "x" }, .{ .string = "x" }),
        .expect(.{ "EVAL", "return false", "0" }, .nil),
        .expect(.{ "EVAL", "return redis.error_reply('MYERR x')", "0" }, .{ .err = "MYERR x" }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(i64, 1), try t.run(io, cmd.eval(i64, "return 1", &.{}, .{})));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "k", "7", "1.5" }), try t.run(io, cmd.eval([]const []const u8, "return {KEYS[1], ARGV[1], ARGV[2]}", &.{"k"}, .{ 7, 1.5 })));
    try testing.expectEqualDeep(@as([]const u8, "x"), try t.run(io, cmd.eval([]const u8, "return ARGV[1]", &.{ "a", "b" }, &.{"x"})));
    try testing.expectEqual(@as(?i64, null), try t.run(io, cmd.eval(?i64, "return false", &.{}, &.{})));
    try testing.expectError(error.ServerError, t.run(io, cmd.eval(i64, "return redis.error_reply('MYERR x')", &.{}, .{})));
    try testing.expect(t.d.isCode("MYERR"));
    try testing.expectError(error.InvalidArgument, t.run(io, cmd.eval(i64, "return 1", &.{}, .{ 1, std.math.nan(f64) })));
    try testing.expectEqualStrings("redis.cmd.eval: args[1] is NaN, which a server does not take", t.d.message());
    try testing.expectEqual(@as(usize, 5), server.received(io));
    try server.finish(io);
}

test "evalScript in run sends EVALSHA; after NOSCRIPT, which ran nothing, EVAL with the text on the same connection" {
    try within5s(testing.io, evalsha, .{testing.io});
}

fn evalsha(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "EVALSHA", &take_ticket.sha1, "1", "tickets:concert" }, .{ .err = "NOSCRIPT No matching script. Please use EVAL." }),
        .expect(.{ "EVAL", take_ticket.source, "1", "tickets:concert" }, .{ .integer = 41 }),
        .expect(.{ "EVALSHA", &take_ticket.sha1, "1", "tickets:concert" }, .{ .integer = 40 }),
        .expect(.{ "EVALSHA", &return_one.sha1, "0" }, .{ .err = "NOSCRIPT No matching script. Please use EVAL." }),
        .expect(.{ "EVAL", return_one.source, "0" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    try testing.expectEqual(@as(i64, 41), try t.run(io, cmd.evalScript(i64, &take_ticket, &.{"tickets:concert"}, .{})));
    try testing.expectEqualStrings("", t.d.message());
    try testing.expectEqual((try server.entry(io, 0)).connection, (try server.entry(io, 1)).connection);
    // The server has it now.
    try testing.expectEqual(@as(i64, 40), try t.run(io, cmd.evalScript(i64, &take_ticket, &.{"tickets:concert"}, .{})));
    // Without diagnostics too.
    try testing.expectEqual(@as(i64, 1), try t.client.run(io, .of(.root), cmd.evalScript(i64, &return_one, &.{}, .{}), .{}));
    try server.finish(io);
}

test "evalScript in a pipeline and in a transaction sends EVAL at once" {
    try within5s(testing.io, inBatches, .{testing.io});
}

fn inBatches(io: Io) !void {
    const queued: FakeServer.Reply = .{ .raw = "+QUEUED\r\n" };
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "EVAL", take_ticket.source, "1", "tickets:concert" }, .{ .integer = 39 }),
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "EVAL", take_ticket.source, "1", "tickets:concert" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{.{ .integer = 38 }} }),
    });
    defer server.stop(io);
    var t: Fixture = undefined;
    try t.init(io, &server);
    defer t.deinit();

    const ticket = cmd.evalScript(i64, &take_ticket, &.{"tickets:concert"}, .{});
    const piped = try t.client.pipeline(io, .of(.root), .{ticket}, .{});
    try testing.expectEqual(@as(i64, 39), try piped[0]);
    var conn = try t.client.acquire(io, .of(.root));
    defer conn.release(io);
    const done = (try conn.transaction(io, .of(.root), .{ticket}, .{})) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 38), try done[0]);
    try testing.expectEqual(@as(usize, 0), server.count(io, "EVALSHA"));
    try server.finish(io);
}
