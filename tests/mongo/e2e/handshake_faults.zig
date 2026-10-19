//! Connections whose handshake fails, against mongo-auth: the fail point
//! failCommand, limited to the appName of one client, makes mongod fail
//! the hello or the SCRAM conversation of that client's next connection.
//!
//! - A hello that the server cuts is a network error while the connection
//!   opens: `error.Unavailable` with the labels that CMAP gives a server
//!   that may be overloaded, SystemOverloadedError and RetryableError, and
//!   the pool keeps its other connections. So is a SCRAM conversation that
//!   the server cuts.
//! - A SCRAM conversation that the server refuses is
//!   `error.AuthenticationFailed`, and the pool is cleared: the server
//!   would refuse every new connection alike. The call after the clear
//!   probes, and finds the server taking the user again.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("root.zig");

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

/// `sleep`, a test command of mongo-auth, without a lock: the call holds
/// its connection for `millis`.
fn sleepFor(comptime millis: i32) mongo.Command {
    return .{ .database = "admin", .body = bson.literal(.{ .sleep = 1, .millis = millis, .lock = "none" }) };
}

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// A client of mongo-auth as the user sha256, named `app_name`.
fn clientOf(io: Io, driver: *mongo.Client, buffer: []u8, app_name: []const u8) !void {
    const uri = try std.fmt.bufPrint(buffer, "mongodb://sha256:sha256-pass@127.0.0.1:{d}/?maxPoolSize=2&appName={s}", .{ e2e.servers.auth_port, app_name });
    driver.* = try .init(testing.allocator, io, .{ .uri = uri });
}

fn connectOk(io: Io, driver: *mongo.Client) !void {
    var d: mongo.Diagnostics = .{};
    driver.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

/// The observer, which sets the fail points: the user both, root.
fn observer(io: Io, driver: *mongo.Client, buffer: []u8) !void {
    const uri = try std.fmt.bufPrint(buffer, "mongodb://both:both-pass@127.0.0.1:{d}/?appName=zefir-e2e-observer", .{e2e.servers.auth_port});
    driver.* = try .init(testing.allocator, io, .{ .uri = uri });
    errdefer driver.deinit();
    try connectOk(io, driver);
}

fn run(io: Io, c: *mongo.Client, command: mongo.Command) !void {
    var d: mongo.Diagnostics = .{};
    const reply = c.runCommand(io, .of(within(io, .fromSeconds(10))), command, .{ .allocator = testing.allocator, .diagnostics = &d }) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ nameOf(command), err, d.message() });
        return err;
    };
    reply.deinit();
}

/// The name of `command`: its first key.
fn nameOf(command: mongo.Command) []const u8 {
    const first = (command.body.first() catch return "?") orelse return "?";
    return first.key;
}

/// Makes the fail point failCommand fail the next command that `data`
/// names, once: `data` holds `failCommands`, the `appName` of the client
/// it is for, and how the command fails.
fn failOnce(io: Io, watch: *mongo.Client, comptime data: anytype) !void {
    try run(io, watch, .{ .database = "admin", .body = bson.literal(.{
        .configureFailPoint = "failCommand",
        .mode = .{ .times = 1 },
        .data = data,
    }) });
}

fn failPointOff(io: Io, watch: *mongo.Client) void {
    run(io, watch, .{ .database = "admin", .body = bson.literal(.{ .configureFailPoint = "failCommand", .mode = "off" }) }) catch {};
}

/// The message of a hello that the server at mongo-auth cuts.
fn cutHello(buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "the server at 127.0.0.1:{d} closed the connection during hello; a server that requires TLS does so, and v0.1 does not speak TLS", .{e2e.servers.auth_port});
}

/// The labels of overload, on no answer of a server.
fn expectOverloaded(d: *const mongo.Diagnostics) !void {
    const server = d.server orelse return error.TestNoLabels;
    try testing.expectEqual(@as(i32, 0), server.code);
    try testing.expect(server.labels.contains(.system_overloaded_error));
    try testing.expect(server.labels.contains(.retryable_error));
}

test "connect() whose hello the server cuts is Unavailable with the labels of overload, and connect() again succeeds" {
    try e2e.onZio(connectCut);
}

fn connectCut(io: Io) !void {
    var watch: mongo.Client = undefined;
    var watch_uri: [160]u8 = undefined;
    try observer(io, &watch, &watch_uri);
    defer watch.deinit();
    defer failPointOff(io, &watch);
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try clientOf(io, &driver, &buffer, "zefir-e2e-connect-cut");
    defer driver.deinit();
    try failOnce(io, &watch, .{ .failCommands = .{"isMaster"}, .appName = "zefir-e2e-connect-cut", .closeConnection = true });
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Unavailable, driver.connect(io, within(io, .fromSeconds(10)), &d));
    var expected: [192]u8 = undefined;
    try testing.expectEqualStrings(try cutHello(&expected), d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.handshake, d.phase.?);
    try expectOverloaded(&d);
    try testing.expectError(error.Unavailable, driver.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
    try connectOk(io, &driver);
    try run(io, &driver, ping);
    try testing.expectEqual(@as(u64, 0), driver.stats().clears);
}

test "a new connection whose hello the server cuts is Unavailable with the labels of overload, and the pool keeps its other connection" {
    try e2e.onZio(helloCut);
}

/// A call that holds a connection of `c` while the test opens another.
const Holder = struct {
    c: *mongo.Client,
    result: anyerror!void = {},

    fn hold(h: *Holder, io: Io) void {
        h.result = run(io, h.c, sleepFor(1000));
    }
};

fn awaitInUse(io: Io, driver: *mongo.Client, value: usize) !void {
    const give_up: core.Deadline = .after(Io.Clock.awake.now(io), .fromSeconds(20));
    while (driver.stats().in_use != value) {
        if (give_up.isExpired(Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn helloCut(io: Io) !void {
    var watch: mongo.Client = undefined;
    var watch_uri: [160]u8 = undefined;
    try observer(io, &watch, &watch_uri);
    defer watch.deinit();
    defer failPointOff(io, &watch);
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try clientOf(io, &driver, &buffer, "zefir-e2e-hello-cut");
    defer driver.deinit();
    try connectOk(io, &driver);
    const c = &driver;
    var holder: Holder = .{ .c = c };
    var holding = try io.concurrent(Holder.hold, .{ &holder, io });
    defer holding.cancel(io);
    try awaitInUse(io, c, 1);

    // The next call opens a connection, whose hello the server cuts.
    try failOnce(io, &watch, .{ .failCommands = .{"isMaster"}, .appName = "zefir-e2e-hello-cut", .closeConnection = true });
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Unavailable, c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    var expected: [192]u8 = undefined;
    try testing.expectEqualStrings(try cutHello(&expected), d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.handshake, d.phase.?);
    try expectOverloaded(&d);

    // Nothing was cleared: the connection of the call out stays, and
    // serves the next call.
    holding.await(io);
    try holder.result;
    var stats = c.stats();
    try testing.expectEqual(@as(u64, 0), stats.clears);
    try testing.expectEqual(@as(u64, 0), stats.generation);
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try run(io, c, ping);
    stats = c.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

test "a new connection whose SCRAM conversation the server cuts is Unavailable with the labels of overload, and the pool keeps its other connection" {
    try e2e.onZio(scramCut);
}

fn scramCut(io: Io) !void {
    var watch: mongo.Client = undefined;
    var watch_uri: [160]u8 = undefined;
    try observer(io, &watch, &watch_uri);
    defer watch.deinit();
    defer failPointOff(io, &watch);
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try clientOf(io, &driver, &buffer, "zefir-e2e-sasl-cut");
    defer driver.deinit();
    try connectOk(io, &driver);
    const c = &driver;
    var holder: Holder = .{ .c = c };
    var holding = try io.concurrent(Holder.hold, .{ &holder, io });
    defer holding.cancel(io);
    try awaitInUse(io, c, 1);

    // The next call opens a connection, whose proof of SCRAM the server
    // takes and answers by closing the connection.
    try failOnce(io, &watch, .{ .failCommands = .{"saslContinue"}, .appName = "zefir-e2e-sasl-cut", .closeConnection = true });
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Unavailable, c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    var expected: [96]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "the server at 127.0.0.1:{d} closed the connection", .{e2e.servers.auth_port}), d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.authenticate, d.phase.?);
    try expectOverloaded(&d);

    // Nothing was cleared: the connection of the call out stays, and
    // serves the next call.
    holding.await(io);
    try holder.result;
    var stats = c.stats();
    try testing.expectEqual(@as(u64, 0), stats.clears);
    try testing.expectEqual(@as(u64, 0), stats.generation);
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try run(io, c, ping);
    stats = c.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 0), stats.clears);
}

test "a new connection whose SCRAM conversation the server refuses is AuthenticationFailed and clears the pool; the call after it probes and gets in" {
    try e2e.onZio(scramRefused);
}

fn scramRefused(io: Io) !void {
    var watch: mongo.Client = undefined;
    var watch_uri: [160]u8 = undefined;
    try observer(io, &watch, &watch_uri);
    defer watch.deinit();
    defer failPointOff(io, &watch);
    var driver: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try clientOf(io, &driver, &buffer, "zefir-e2e-sasl-refused");
    defer driver.deinit();
    try connectOk(io, &driver);
    const c = &driver;
    var holder: Holder = .{ .c = c };
    var holding = try io.concurrent(Holder.hold, .{ &holder, io });
    defer holding.cancel(io);
    try awaitInUse(io, c, 1);

    // The next call opens a connection, whose proof of SCRAM the server
    // refuses as it refuses a wrong password.
    try failOnce(io, &watch, .{ .failCommands = .{"saslContinue"}, .appName = "zefir-e2e-sasl-refused", .errorCode = 18 });
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 18), d.server.?.code);
    try testing.expectEqual(mongo.Diagnostics.Phase.authenticate, d.phase.?);
    var stats = c.stats();
    try testing.expectEqual(@as(u64, 1), stats.clears);
    try testing.expectEqual(@as(u64, 1), stats.generation);

    // The call out ends well, and its connection, of the generation
    // before the clear, closes.
    holding.await(io);
    try holder.result;
    stats = c.stats();
    try testing.expectEqual(@as(usize, 0), stats.connections + stats.opening);
    // The pool is paused: the next call probes, and the server takes the
    // user again.
    try run(io, c, ping);
    stats = c.stats();
    try testing.expectEqual(@as(usize, 1), stats.connections);
    try testing.expectEqual(@as(u64, 1), stats.clears);
}
