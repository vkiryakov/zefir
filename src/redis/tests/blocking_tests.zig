//! Tests of the timeout of blocking commands: the derivation from the
//! deadline by itself, with exact values, and what goes to
//! `redis.testing.FakeServer` over loopback for two command types of the
//! tests, one whose timeout is in seconds as BLPOP's, one in milliseconds
//! as XREAD BLOCK's; in `run`, in a pipeline and in a transaction. Every
//! test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("../root.zig");
const cmd = redis.cmd;
const Client = redis.Client;
const Diagnostics = redis.Diagnostics;
const FakeServer = redis.testing.FakeServer;
const resp = @import("../resp.zig");
const contract = @import("../cmd/contract.zig");
const blocking = @import("../engine/blocking.zig");
const time = @import("../engine/time.zig");
const within5s = @import("time_limit.zig").within5s;
const expectFromDeadline = @import("../cmd/fixture.zig").expectFromDeadline;

/// BLPOP key timeout, the timeout in seconds; its reply read as a number.
const Pop = struct {
    key: []const u8,
    wait: redis.Block,

    pub const Reply = ?i64;
    pub const blocking: contract.Blocking = .{ .unit = .seconds, .instead = "redis.cmd.lpop" };

    pub fn check(c: Pop, d: ?*Diagnostics) error{InvalidArgument}!void {
        return contract.checkBlock(c.wait, "tests.Pop", d);
    }

    pub fn write(c: Pop, w: resp.Writer) resp.Writer.Error!void {
        return c.writeWith(w, contract.given(c.wait));
    }

    pub fn writeWith(c: Pop, w: resp.Writer, timeout_ms: u64) resp.Writer.Error!void {
        try w.arrayHeader(3);
        try w.bulk("BLPOP");
        try w.bulk(c.key);
        try contract.writeTimeout(w, .seconds, timeout_ms);
    }

    pub fn read(_: Pop, r: *resp.Reader, arena: ?std.mem.Allocator, d: ?*Diagnostics) resp.DecodeError!?i64 {
        return resp.decode(?i64, r, arena, d);
    }

    pub fn name(_: Pop) []const u8 {
        return "BLPOP";
    }

    pub fn timeout(c: Pop) redis.Block {
        return c.wait;
    }
};

/// XREAD BLOCK ms STREAMS key $, the timeout in milliseconds; its reply
/// read as a number.
const Read = struct {
    key: []const u8,
    wait: redis.Block,

    pub const Reply = ?i64;
    pub const blocking: contract.Blocking = .{ .unit = .milliseconds, .instead = "redis.cmd.xread without .block" };

    pub fn check(c: Read, d: ?*Diagnostics) error{InvalidArgument}!void {
        return contract.checkBlock(c.wait, "tests.Read", d);
    }

    pub fn write(c: Read, w: resp.Writer) resp.Writer.Error!void {
        return c.writeWith(w, contract.given(c.wait));
    }

    pub fn writeWith(c: Read, w: resp.Writer, timeout_ms: u64) resp.Writer.Error!void {
        try w.arrayHeader(6);
        try w.bulk("XREAD");
        try w.bulk("BLOCK");
        try contract.writeTimeout(w, .milliseconds, timeout_ms);
        try w.bulk("STREAMS");
        try w.bulk(c.key);
        try w.bulk("$");
    }

    pub fn read(_: Read, r: *resp.Reader, arena: ?std.mem.Allocator, d: ?*Diagnostics) resp.DecodeError!?i64 {
        return resp.decode(?i64, r, arena, d);
    }

    pub fn name(_: Read) []const u8 {
        return "XREAD";
    }

    pub fn timeout(c: Read) redis.Block {
        return c.wait;
    }
};

fn pop(wait: redis.Block) Pop {
    return .{ .key = "q", .wait = wait };
}

fn ms(n: i64) Io.Duration {
    return .fromMilliseconds(n);
}

test "the timeout of a blocking command is what the deadline leaves beyond 150 ms and the shortest round trip, rounded down to the millisecond, or its own when that is shorter" {
    try testing.expectEqual(@as(u64, 850), try blocking.derive(.{ .at_most = .fromSeconds(30) }, ms(1000), .zero));
    try testing.expectEqual(@as(u64, 200), try blocking.derive(.{ .at_most = ms(200) }, ms(1000), .zero));
    try testing.expectEqual(@as(u64, 850), try blocking.derive(.forever, ms(1000), .zero));
    try testing.expectEqual(@as(u64, 1), try blocking.derive(.{ .at_most = .fromSeconds(30) }, .fromMicroseconds(151_400), .zero));
    try testing.expectError(error.DeadlineExceeded, blocking.derive(.{ .at_most = .fromSeconds(30) }, .fromMicroseconds(150_900), .zero));
    try testing.expectEqual(@as(u64, 830), try blocking.derive(.forever, ms(1000), ms(20)));
    // Without a deadline: its own timeout, and 0, forever, for .forever.
    try testing.expectEqual(@as(u64, 1500), try blocking.derive(.{ .at_most = .fromMicroseconds(1_500_700) }, null, .zero));
    try testing.expectEqual(@as(u64, 0), try blocking.derive(.forever, null, .zero));
}

test "a timeout goes out in seconds with the fraction it has, or in milliseconds" {
    const cases = [_]struct { contract.Unit, u64, []const u8 }{
        .{ .seconds, 850, "0.85" },
        .{ .seconds, 1, "0.001" },
        .{ .seconds, 1500, "1.5" },
        .{ .seconds, 30_000, "30" },
        .{ .seconds, 0, "0" },
        .{ .seconds, std.math.maxInt(u64), "18446744073709551.615" },
        .{ .milliseconds, 850, "850" },
        .{ .milliseconds, 0, "0" },
    };
    for (cases) |case| {
        const unit, const timeout_ms, const text = case;
        var buffer: [64]u8 = undefined;
        var out: Io.Writer = .fixed(&buffer);
        try contract.writeTimeout(.init(&out), unit, timeout_ms);
        var expected: [64]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "${d}\r\n{s}\r\n", .{ text.len, text }), out.buffered());
    }
}

/// Answers every command with null, after `delay_ms`.
const Late = struct {
    delay_ms: std.atomic.Value(i64) = .init(0),

    pub fn answer(late: *Late, io: Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        try redis.testing.sleepAtLeast(io, ms(late.delay_ms.load(.acquire)));
        return .nil;
    }
};

/// The timeout in milliseconds that the command number `i` of the journal
/// sent: BLPOP's in seconds, XREAD's in milliseconds.
fn sent(io: Io, server: *FakeServer, i: usize) !u64 {
    const args = (try server.entry(io, i)).args;
    if (std.mem.eql(u8, args[0], "XREAD")) return std.fmt.parseInt(u64, args[2], 10);
    const text = args[2];
    const dot = std.mem.findScalar(u8, text, '.') orelse return 1000 * try std.fmt.parseInt(u64, text, 10);
    var fraction: [3]u8 = @splat('0');
    @memcpy(fraction[0 .. text.len - dot - 1], text[dot + 1 ..]);
    return 1000 * try std.fmt.parseInt(u64, text[0..dot], 10) + try std.fmt.parseInt(u64, &fraction, 10);
}

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn connected(io: Io, client: *Client, options: Client.Options) !void {
    client.* = try .init(testing.allocator, io, options);
    errdefer client.deinit();
    try client.connect(io, .root, null);
}

test "under a deadline a blocking command sends what the deadline leaves beyond the margin, in its units, or its own timeout when shorter" {
    try within5s(testing.io, fromDeadline, .{testing.io});
}

fn fromDeadline(io: Io) !void {
    var late: Late = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&late) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    const start = time.now(io);
    try testing.expectEqual(@as(?i64, null), try client.run(io, within(io, .fromSeconds(1)), pop(.{ .at_most = .fromSeconds(30) }), .{}));
    try testing.expectEqual(@as(?i64, null), try client.run(io, within(io, .fromSeconds(1)), Read{ .key = "s", .wait = .{ .at_most = .fromSeconds(30) } }, .{}));
    try testing.expectEqual(@as(?i64, null), try client.run(io, within(io, .fromSeconds(1)), pop(.forever), .{}));
    for (0..3) |i| try expectFromDeadline(io, start, try sent(io, &server, i));
    try testing.expectEqual(@as(?i64, null), try client.run(io, within(io, .fromSeconds(1)), pop(.{ .at_most = ms(200) }), .{}));
    try testing.expectEqual(@as(u64, 200), try sent(io, &server, 3));
}

test "a deadline that leaves 150 ms or less is DeadlineExceeded, nothing goes out, and the text names the command that does not block" {
    try within5s(testing.io, tooLittleLeft, .{testing.io});
}

fn tooLittleLeft(io: Io) !void {
    var late: Late = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&late) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, client.run(io, within(io, ms(100)), pop(.{ .at_most = .fromSeconds(30) }), .{ .diagnostics = &d }));
    try testing.expect(std.mem.startsWith(u8, d.message(), "a blocking command needs more than 150 ms left of the deadline"));
    try testing.expect(std.mem.endsWith(u8, d.message(), "use redis.cmd.lpop"));
    try testing.expectError(error.DeadlineExceeded, client.run(io, within(io, ms(100)), Read{ .key = "s", .wait = .forever }, .{ .diagnostics = &d }));
    try testing.expect(std.mem.endsWith(u8, d.message(), "use redis.cmd.xread without .block"));
    // The whole pipeline, whose other command does not block.
    try testing.expectError(error.DeadlineExceeded, client.pipeline(io, within(io, ms(100)), .{ cmd.raw(?i64, .{ "GET", "k" }), pop(.forever) }, .{ .diagnostics = &d }));
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    try testing.expectError(error.DeadlineExceeded, conn.run(io, within(io, ms(100)), pop(.forever), .{}));
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "a timeout under 1 ms or longer than the client counts is InvalidArgument, and nothing goes out" {
    try within5s(testing.io, badTimeouts, .{testing.io});
}

fn badTimeouts(io: Io) !void {
    var late: Late = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&late) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var d: Diagnostics = .{};
    for ([_]Io.Duration{ .fromMicroseconds(500), .fromSeconds(-1) }) |wait| {
        try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), pop(.{ .at_most = wait }), .{ .diagnostics = &d }));
        try testing.expectEqualStrings("tests.Pop: the timeout .at_most is under 1 ms, which a server takes as forever: give 1 ms or more, or .forever", d.message());
    }
    try testing.expectError(error.InvalidArgument, client.run(io, .of(.root), pop(.{ .at_most = .max }), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("tests.Pop: the timeout .at_most is longer than 9223372036854775807 ms, the most the client counts", d.message());
    try testing.expectError(error.InvalidArgument, client.pipeline(io, .of(.root), .{ cmd.raw(?i64, .{ "GET", "k" }), pop(.{ .at_most = .max }) }, .{ .diagnostics = &d }));
    try testing.expectEqual(@as(?usize, 1), d.command);
    try testing.expectEqual(@as(usize, 0), server.received(io));
}

test "without a deadline a blocking command sends its own timeout, and its call waits that long and timeout more; .forever sends 0 and waits as long as it takes" {
    try within5s(testing.io, withoutDeadline, .{testing.io});
}

fn withoutDeadline(io: Io) !void {
    var late: Late = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&late) });
    defer server.stop(io);
    {
        var client: Client = undefined;
        try connected(io, &client, .{ .url = server.url() });
        defer client.deinit();
        late.delay_ms.store(400, .release);
        try testing.expectEqual(@as(?i64, null), try client.run(io, .of(.root), pop(.{ .at_most = ms(300) }), .{}));
        try testing.expectEqual(@as(u64, 300), try sent(io, &server, 0));
    }
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .timeout = ms(100) });
    defer client.deinit();
    late.delay_ms.store(600, .release);
    var d: Diagnostics = .{};
    try testing.expectError(error.Timeout, client.run(io, .of(.root), pop(.{ .at_most = ms(300) }), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    late.delay_ms.store(300, .release);
    const start = time.now(io);
    try testing.expectEqual(@as(?i64, null), try client.run(io, .of(.root), pop(.forever), .{}));
    try testing.expect(start.durationTo(time.now(io)).toMilliseconds() >= 300);
    try testing.expectEqualStrings("0", (try server.entry(io, 2)).args[2]);
}

test "a pipeline takes the timeouts of its blocking commands from the deadline when it writes them, and without one waits for all of them and timeout more" {
    try within5s(testing.io, inPipeline, .{testing.io});
}

fn inPipeline(io: Io) !void {
    var late: Late = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&late) });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url(), .timeout = ms(500) });
    defer client.deinit();
    const start = time.now(io);
    const r = try client.pipeline(io, within(io, .fromSeconds(1)), .{ cmd.raw(?i64, .{ "GET", "k" }), pop(.{ .at_most = .fromSeconds(30) }), pop(.{ .at_most = ms(100) }) }, .{});
    try testing.expectEqual(@as(?i64, null), try r[1]);
    try expectFromDeadline(io, start, try sent(io, &server, 1));
    try testing.expectEqual(@as(u64, 100), try sent(io, &server, 2));
    // Without a deadline: 600 ms for each, and timeout, 500 ms, more, so
    // 1.7 s. The server answers each 610 ms late, 1.22 s in all: longer
    // than one of them and timeout, and well within the deadline.
    late.delay_ms.store(610, .release);
    const both = [_]Pop{ pop(.{ .at_most = ms(600) }), pop(.{ .at_most = ms(600) }) };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const done = try client.pipeline(io, .of(.root), &both, .{ .allocator = arena.allocator() });
    for (done) |each| try testing.expectEqual(@as(?i64, null), try each);
    try testing.expectEqual(@as(u64, 600), try sent(io, &server, 3));
}

test "in a transaction a blocking command does not block: its timeout goes as given, and a short deadline is no error" {
    try within5s(testing.io, inTransaction, .{testing.io});
}

fn inTransaction(io: Io) !void {
    const queued: FakeServer.Reply = .{ .raw = "+QUEUED\r\n" };
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{"MULTI"}, .ok),
        .expect(.{ "BLPOP", "q", "30" }, queued),
        .expect(.{ "XREAD", "BLOCK", "0", "STREAMS", "s", "$" }, queued),
        .expect(.{"EXEC"}, .{ .array = &.{ .nil, .nil } }),
    });
    defer server.stop(io);
    var client: Client = undefined;
    try connected(io, &client, .{ .url = server.url() });
    defer client.deinit();
    var conn = try client.acquire(io, .of(.root));
    defer conn.release(io);
    const r = (try conn.transaction(io, within(io, ms(100)), .{ pop(.{ .at_most = .fromSeconds(30) }), Read{ .key = "s", .wait = .forever } }, .{})) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?i64, null), try r[0]);
    try testing.expectEqual(@as(?i64, null), try r[1]);
    try server.finish(io);
}
