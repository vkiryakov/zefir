//! Tests of `redis.Client.pipeline` against `redis.testing.FakeServer`
//! over loopback, with commands of `cmd.raw`: a tuple of commands and many
//! commands of one type, the errors of single commands as values in their
//! places, an exchange that breaks off with how many replies came, and the
//! checks of every command before anything goes out. Every test runs under
//! a time limit of 5 s; the test of 1000 commands gets 30 s under
//! ThreadSanitizer.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const time = @import("../engine/time.zig");
const time_limit = @import("time_limit.zig");
const within5s = time_limit.within5s;

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

/// A client of `options`, connected.
fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

fn connectionOf(io: Io, server: *FakeServer, i: usize) !u32 {
    return (try server.entry(io, i)).connection;
}

/// The commands of many keys, each SET k<i> v, built at run time.
const Set = cmd.Raw(void, []const []const u8);

/// Answers every command with +OK.
const Ok = struct {
    pub fn answer(_: *Ok, _: Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        return .ok;
    }
};

test "a tuple of commands gives a tuple of their replies, each a value or an error, from one connection" {
    try within5s(testing.io, tupleOfCommands, .{testing.io});
}

fn tupleOfCommands(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "views" }, .{ .integer = 1 }),
        .expect(.{ "PEXPIRE", "views", "86400000" }, .{ .integer = 1 }),
        .expect(.{ "GET", "motd" }, .{ .string = "hi" }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try client.pipeline(io, .of(.root), .{
        cmd.raw(i64, .{ "INCR", "views" }),
        cmd.raw(bool, .{ "PEXPIRE", "views", 86400000 }),
        cmd.raw(?[]const u8, .{ "GET", "motd" }),
    }, .{ .allocator = arena.allocator() });
    comptime std.debug.assert(@TypeOf(r) == @Tuple(&.{ redis.CommandError!i64, redis.CommandError!bool, redis.CommandError!?[]const u8 }));
    try testing.expectEqual(@as(i64, 1), try r[0]);
    try testing.expect(try r[1]);
    try testing.expectEqualStrings("hi", (try r[2]).?);
    for (0..3) |i| try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, i));
    try server.finish(io);
}

/// The time limit of `manyCommands`, and the deadline of its pipeline:
/// ThreadSanitizer makes the server's work on each of the 1000 commands
/// many times slower, all the more on a busy runner.
const many_limit: Io.Duration = if (builtin.sanitize_thread) .fromSeconds(30) else .fromSeconds(5);

test "1000 commands of one type behind a pointer to their array give a slice of results from .allocator, and go out in their order" {
    try time_limit.withinLimit(testing.io, many_limit, manyCommands, .{testing.io});
}

fn manyCommands(io: Io) !void {
    var ok: Ok = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&ok) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var names: [1000][8]u8 = undefined;
    var parts: [1000][3][]const u8 = undefined;
    var commands: [1000]Set = undefined;
    for (&commands, &parts, &names, 0..) |*command, *part, *name, i| {
        part.* = .{ "SET", std.fmt.bufPrint(name, "k{d}", .{i}) catch unreachable, "v" };
        command.* = cmd.raw(void, @as([]const []const u8, part));
    }
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(counting.allocator());
    defer arena.deinit();
    const done = try client.pipeline(io, within(io, many_limit), &commands, .{ .allocator = arena.allocator() });
    comptime std.debug.assert(@TypeOf(done) == []const (redis.CommandError!void));
    try testing.expectEqual(@as(usize, 1000), done.len);
    for (done) |each| try each;
    try testing.expect(counting.allocated_bytes >= 1000 * @sizeOf(redis.CommandError!void));
    try testing.expectEqual(@as(usize, 1000), server.received(io));
    for (0..1000) |i| {
        const entry = try server.entry(io, i);
        try testing.expectEqualStrings(parts[i][1], entry.args[1]);
        try testing.expectEqual(@as(u32, 1), entry.connection);
    }
}

test "an error of one command is the value in its place, the others are read, and the diagnostics name the first such command" {
    try within5s(testing.io, errorInPlace, .{testing.io});
}

fn errorInPlace(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "a" }, .{ .integer = 1 }),
        .expect(.{ "INCR", "b" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "INCR", "c" }, .{ .string = "abc" }),
        .expect(.{ "INCR", "d" }, .{ .integer = 4 }),
        .expect(.{ "GET", "k" }, .{ .integer = 5 }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    const r = try client.pipeline(io, .of(.root), .{
        cmd.raw(i64, .{ "INCR", "a" }),
        cmd.raw(i64, .{ "INCR", "b" }),
        cmd.raw(i64, .{ "INCR", "c" }),
        cmd.raw(i64, .{ "INCR", "d" }),
    }, .{ .diagnostics = &d });
    try testing.expectEqual(@as(i64, 1), try r[0]);
    try testing.expectError(error.ServerError, r[1]);
    try testing.expectError(error.UnexpectedReply, r[2]);
    try testing.expectEqual(@as(i64, 4), try r[3]);
    try testing.expectEqual(@as(?usize, 1), d.command);
    try testing.expect(d.isCode("WRONGTYPE"));
    try testing.expectEqual(@as(?usize, null), d.answered);
    // The connection stays: the next call goes on it.
    try testing.expectEqual(@as(?i64, 5), try client.run(io, .of(.root), cmd.raw(?i64, .{ "GET", "k" }), .{}));
    try testing.expectEqual(@as(u32, 1), try connectionOf(io, &server, 4));
    try server.finish(io);
}

test "a connection that breaks after two replies is ConnectionLost for the whole pipeline, with answered 2, and clears the pool" {
    try within5s(testing.io, brokenAfterTwo, .{testing.io});
}

fn brokenAfterTwo(io: Io) !void {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "a" }, .{ .integer = 1 }),
        .expect(.{ "INCR", "b" }, .{ .integer = 2 }),
        .expect(.{ "INCR", "c" }, .close_connection),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, client.pipeline(io, .of(.root), .{
        cmd.raw(i64, .{ "INCR", "a" }),
        cmd.raw(i64, .{ "INCR", "b" }),
        cmd.raw(i64, .{ "INCR", "c" }),
    }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 2), d.answered);
    try testing.expectEqual(@as(?usize, null), d.command);
    try testing.expect(std.mem.endsWith(u8, d.message(), " closed the connection"));
    try testing.expectEqual(@as(u64, 1), client.stats().clears);
    try server.finish(io);
}

test "a deadline that passes in the middle is Timeout with the replies that came, and closes the connection" {
    try within5s(testing.io, deadlineInTheMiddle, .{testing.io});
}

const two: FakeServer.Reply = .{ .integer = 2 };
const after300: FakeServer.Reply = .{ .delayed = .{ .after = .fromMilliseconds(300), .reply = &two } };

fn deadlineInTheMiddle(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "a" }, .{ .integer = 1 }),
        .expect(.{ "INCR", "b" }, after300),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Timeout, client.pipeline(io, within(io, .fromMilliseconds(100)), .{
        cmd.raw(i64, .{ "INCR", "a" }),
        cmd.raw(i64, .{ "INCR", "b" }),
    }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 1), d.answered);
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    try testing.expectEqual(@as(usize, 0), client.stats().connections);
    // A timeout closes its own connection only.
    try testing.expectEqual(@as(u64, 0), client.stats().clears);
}

test "a bad command, no commands, and a slice without .allocator are InvalidArgument, and nothing goes out" {
    try within5s(testing.io, checkedFirst, .{testing.io});
}

fn checkedFirst(io: Io) !void {
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), .{
        cmd.raw(i64, .{ "INCR", "a" }),
        cmd.raw(i64, .{ "INCR", "b" }),
        cmd.raw(i64, .{ "ZADD", "z", std.math.nan(f64), "m" }),
    }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.cmd.raw: args[2] is NaN, which a server does not take", d.message());
    try testing.expectEqual(@as(?usize, 2), d.command);
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), .{ cmd.raw(i64, .{ "INCR", "a" }), cmd.raw([]const u8, .{ "GET", "k" }) }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the reply of GET holds strings: pass .allocator", d.message());
    try testing.expectEqual(@as(?usize, 1), d.command);
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), .{}, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.pipeline: no commands: pass one or more", d.message());
    try testing.expectEqual(@as(?usize, null), d.command);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none: []const Set = &.{};
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), none, .{ .allocator = arena.allocator(), .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.pipeline: no commands: pass one or more", d.message());
    const one: []const Set = &.{cmd.raw(void, @as([]const []const u8, &.{ "SET", "k", "v" }))};
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), one, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("redis.Client.pipeline: the results of a slice of commands are a slice: pass .allocator", d.message());
    try testing.expectEqual(@as(usize, 0), server.received(io));
    try testing.expectEqual(@as(usize, 1), client.stats().idle);
}
