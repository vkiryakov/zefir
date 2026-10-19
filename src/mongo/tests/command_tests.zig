//! Tests of the fields the driver adds to a command, against
//! `mongo.testing.FakeServer` over loopback: `$db` always, `maxTimeMS`
//! under the deadline of the context or of `timeoutMS`, less the shortest
//! round trip, and none in `getMore` and `killCursors`. Every test runs
//! under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const Client = @import("../Client.zig");
const time = @import("../engine/time.zig");
const within5s = @import("connection_tests.zig").within5s;

/// Answers every command with `{ok: 1.0}`.
const Ok = struct {
    pub fn answer(o: *Ok, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ o, io, arena, request };
        return .{ .reply = Script.ok };
    }
};

/// A scripted server on loopback, served until `stop`.
const Served = struct {
    ok: Ok = .{},
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [96]u8 = undefined,

    /// It points into itself: start it in place.
    fn start(s: *Served, io: Io) !void {
        s.* = .{ .script = undefined, .listener = undefined, .server = undefined };
        s.script = .init(testing.allocator, .init(&s.ok));
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    /// The server's URI with `query` after it, such as "?timeoutMS=500".
    fn uri(s: *Served, query: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&s.buffer, "mongodb://127.0.0.1:{d}/{s}", .{ FakeServer.port(&s.listener), query });
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }

    /// The body of the last command the server got.
    fn last(s: *Served, io: Io) !bson.RawDocument {
        const n = s.script.received(io);
        if (n == 0) return error.NotReceived;
        return (try s.script.entry(io, n - 1)).body;
    }
};

const count: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .count = "users" }) };

fn within(io: Io, duration: Io.Duration) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(time.now(io), duration)));
}

fn run(io: Io, driver: *Client, op: mongo.OperationContext, command: mongo.Command) !void {
    const reply = try driver.runCommand(io, op, command, .{ .allocator = testing.allocator });
    reply.deinit();
}

/// The `maxTimeMS` of `body`, which must hold one.
fn maxTimeOf(body: bson.RawDocument) !i64 {
    const value = (try body.get("maxTimeMS")) orelse return error.TestExpectedMaxTimeMS;
    try testing.expect(value == .int64);
    return value.int64;
}

test "a command without a deadline goes as it is, with $db and nothing else of the driver's" {
    try within5s(testing.io, noDeadline, .{testing.io});
}

fn noDeadline(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    try run(io, &driver, .of(.root), count);
    try testing.expectEqualSlices(u8, bson.literal(.{ .count = "users", .@"$db" = "app" }).bytes, (try served.last(io)).bytes);
}

test "under a deadline a command takes maxTimeMS, the time left in whole milliseconds, after its other fields" {
    try within5s(testing.io, underDeadline, .{testing.io});
}

fn underDeadline(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    try run(io, &driver, within(io, .fromMilliseconds(4000)), count);
    const body = try served.last(io);
    const ms = try maxTimeOf(body);
    try testing.expect(ms >= 3000 and ms <= 4000);
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putString("count", "users");
    try b.putInt64("maxTimeMS", ms);
    try b.putString("$db", "app");
    const expected = try b.finish();
    defer expected.deinit();
    try testing.expectEqualSlices(u8, expected.bytes, body.bytes);
}

test "timeoutMS gives a call without a deadline one, with maxTimeMS; the deadline of the context goes before it" {
    try within5s(testing.io, timeoutMS, .{testing.io});
}

fn timeoutMS(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("?timeoutMS=700") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    try run(io, &driver, .of(.root), count);
    const by_timeout = try maxTimeOf(try served.last(io));
    try testing.expect(by_timeout >= 1 and by_timeout <= 700);
    try run(io, &driver, within(io, .fromMilliseconds(4000)), count);
    const by_context = try maxTimeOf(try served.last(io));
    try testing.expect(by_context > 700 and by_context <= 4000);
}

test "maxTimeMS leaves the shortest round trip for the reply; less than 1 ms beyond it is DeadlineExceeded, nothing goes out, and the connection stays in the pool" {
    try within5s(testing.io, roundTrip, .{testing.io});
}

fn roundTrip(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    // Round trips of 400 ms, as of a server far away: two of them make the
    // shortest count.
    driver.round_trips = .{};
    driver.round_trips.add(io, .fromMilliseconds(400));
    driver.round_trips.add(io, .fromMilliseconds(450));
    var d: Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, driver.runCommand(io, within(io, .fromMilliseconds(300)), count, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("less than 1 ms beyond the shortest round trip to the server (400000 us) was left of the deadline before the command went out", d.message());
    try testing.expectEqual(Diagnostics.Phase.send, d.phase.?);
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
    const stats = driver.stats();
    try testing.expectEqual(@as(usize, 1), stats.idle);
    try testing.expectEqual(@as(u64, 0), stats.clears);

    try run(io, &driver, within(io, .fromMilliseconds(4000)), count);
    const ms = try maxTimeOf(try served.last(io));
    try testing.expect(ms >= 1 and ms <= 3600);
}

test "getMore and killCursors go without maxTimeMS under a deadline" {
    try within5s(testing.io, noMaxTimeForCursors, .{testing.io});
}

fn noMaxTimeForCursors(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("?timeoutMS=4000") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    const get_more = bson.literal(.{ .getMore = @as(i64, 7), .collection = "users" });
    const kill = bson.literal(.{ .killCursors = "users", .cursors = .{@as(i64, 7)} });
    for ([_]bson.RawDocument{ get_more, kill }) |body| {
        try run(io, &driver, within(io, .fromMilliseconds(4000)), .{ .database = "app", .body = body });
        try testing.expect(try (try served.last(io)).get("maxTimeMS") == null);
        try run(io, &driver, .of(.root), .{ .database = "app", .body = body });
        try testing.expect(try (try served.last(io)).get("maxTimeMS") == null);
    }
}

test "maxTimeMS of the caller goes as it is without a deadline; under timeoutMS it is InvalidArgument, and nothing goes out" {
    try within5s(testing.io, callersMaxTime, .{testing.io});
}

fn callersMaxTime(io: Io) !void {
    var served: Served = undefined;
    try served.start(io);
    defer served.stop(io);
    const own: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .count = "users", .maxTimeMS = 250 }) };
    {
        var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("") });
        defer driver.deinit();
        try driver.connect(io, .root, null);
        try run(io, &driver, .of(.root), own);
        try testing.expectEqualSlices(u8, bson.literal(.{ .count = "users", .maxTimeMS = 250, .@"$db" = "app" }).bytes, (try served.last(io)).bytes);
    }
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try served.uri("?timeoutMS=4000") });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    const received = served.script.received(io);
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, driver.runCommand(io, .of(.root), own, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the command holds maxTimeMS and timeoutMS of the connection string gives the call a deadline, from which the driver writes maxTimeMS: drop one of the two", d.message());
    try testing.expectEqual(received, served.script.received(io));
}
