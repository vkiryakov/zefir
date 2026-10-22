//! The scripts of `redis.cmd` against the server that REDIS_IMAGE names,
//! on redis-plain: EVAL with keys and arguments, and what a script returns
//! as the server converts it; a `redis.Script` by its SHA1, by its text
//! once SCRIPT FLUSH has emptied the cache of the server, and by its text
//! in a pipeline. Which of EVAL and EVALSHA went out, the server's own
//! INFO commandstats tells.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");
const within = e2e.within;
const Session = e2e.Session;

/// Takes a ticket while some are left: -1 when none is, else how many are
/// left.
const take_ticket: redis.Script = .init(
    \\local left = tonumber(redis.call('GET', KEYS[1]) or '0')
    \\if left <= 0 then return -1 end
    \\return redis.call('DECR', KEYS[1])
);

/// How many times the server ran the command `name`, by INFO commandstats.
fn calls(s: *Session, comptime name: []const u8) !u64 {
    return e2e.infoNumber(try s.run(cmd.raw([]const u8, .{ "INFO", "commandstats" })), "\r\ncmdstat_" ++ name ++ ":calls=") orelse 0;
}

test "eval runs a text with its keys and arguments: a table as an array, a number without its fraction, false as null, an error with its code" {
    try e2e.onZio(texts);
}

fn texts(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "e2e:script:k", "a", "42" }), try s.run(cmd.eval([]const []const u8, "return {KEYS[1], ARGV[1], ARGV[2]}", &.{"e2e:script:k"}, .{ "a", 42 })));
    try testing.expectEqual(@as(i64, 3), try s.run(cmd.eval(i64, "return 3.7", &.{}, .{})));
    try testing.expectEqual(@as(?i64, null), try s.run(cmd.eval(?i64, "return false", &.{}, &.{})));
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ServerError, s.client.run(io, within(io, .fromSeconds(10)), cmd.eval(i64, "return redis.error_reply('MYERR went wrong')", &.{}, .{}), .{ .diagnostics = &d }));
    try testing.expect(d.isCode("MYERR"));
}

test "evalScript runs by its SHA1; after SCRIPT FLUSH by its text, and the next call by its SHA1 again; in a pipeline by its text" {
    try e2e.onZio(scripts);
}

fn scripts(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const tickets = "e2e:script:tickets";
    try s.run(cmd.set(tickets, 2, .{}));
    try s.run(cmd.raw(void, .{ "SCRIPT", "FLUSH" }));
    const eval = try calls(&s, "eval");
    const evalsha = try calls(&s, "evalsha");

    // EVALSHA meets NOSCRIPT, and EVAL runs the script once.
    try testing.expectEqual(@as(i64, 1), try s.run(cmd.evalScript(i64, &take_ticket, &.{tickets}, .{})));
    try testing.expectEqual(eval + 1, try calls(&s, "eval"));
    try testing.expectEqual(evalsha + 1, try calls(&s, "evalsha"));
    // The server keeps it now.
    try testing.expectEqual(@as(i64, 0), try s.run(cmd.evalScript(i64, &take_ticket, &.{tickets}, .{})));
    try testing.expectEqual(eval + 1, try calls(&s, "eval"));
    try testing.expectEqual(evalsha + 2, try calls(&s, "evalsha"));

    const r = try s.client.pipeline(io, within(io, .fromSeconds(10)), .{ cmd.evalScript(i64, &take_ticket, &.{tickets}, .{}), cmd.get(i64, tickets) }, .{});
    try testing.expectEqual(@as(i64, -1), try r[0]);
    try testing.expectEqual(@as(?i64, 0), try r[1]);
    try testing.expectEqual(eval + 2, try calls(&s, "eval"));
    try testing.expectEqual(evalsha + 2, try calls(&s, "evalsha"));
}
