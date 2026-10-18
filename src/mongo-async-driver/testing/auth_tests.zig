//! Protocol tests of authentication: a new connection with a user against
//! mongod's side of SCRAM, played by `ScramServer` on
//! `mongo.testing.FakeServer.Peer` over loopback. Every test runs under a
//! time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const FakeServer = mongo.testing.FakeServer;
const Credentials = @import("../OwnedOptions.zig").Credentials;
const Client = @import("../Client.zig");
const connect = @import("../engine/connect.zig");
const handshake = @import("../engine/handshake.zig");
const KeyCache = @import("../engine/KeyCache.zig");
const scram = @import("../engine/scram.zig");
const time = @import("../engine/time.zig");
const ScramServer = @import("ScramServer.zig");
const Step = ScramServer.Step;
const Mechanism = scram.Mechanism;
const within5s = @import("connection_tests.zig").within5s;

fn credentials(mechanism: ?Mechanism) Credentials {
    return .{ .username = "app", .password = "secret", .source = "admin", .mechanism = mechanism };
}

/// Opens a connection as `user` to `server`, which plays mongod, and closes
/// it at once, so that the server ends.
fn openAs(io: Io, server: *ScramServer, user: Credentials, d: *Diagnostics) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var task = try io.concurrent(ScramServer.serve, .{ server, io, &listener, 1 });
    const meta = try handshake.metadata(testing.allocator, null, null);
    defer meta.deinit();
    var keys: KeyCache = .{};
    defer keys.deinit();
    const setup: handshake.Setup = .{ .metadata = meta.raw(), .auth = .{ .credentials = user, .keys = &keys } };
    var attempt: connect.Attempt = .{};
    const opened = connect.open(io, testing.allocator, .{ .host = "127.0.0.1", .port = FakeServer.port(&listener) }, &setup, .after(time.now(io), .fromSeconds(5)), &attempt, d);
    if (opened) |conn| conn.destroy() else |_| {}
    try task.await(io);
    _ = try opened;
}

fn expectSteps(expected: []const Step, server: *const ScramServer) !void {
    try testing.expectEqualSlices(Step, expected, server.seen.sequence());
}

test "the server takes the speculative conversation of hello, and one saslContinue ends it" {
    try within5s(testing.io, speculativeTaken, .{testing.io});
}

fn speculativeTaken(io: Io) !void {
    var server: ScramServer = .{};
    var d: Diagnostics = .{};
    try openAs(io, &server, credentials(null), &d);
    try expectSteps(&.{.sasl_continue}, &server);
    // hello asked for the user's mechanisms and tried SCRAM-SHA-256.
    try testing.expectEqualStrings("admin.app", server.seen.asked_for.slice().?);
    try testing.expectEqual(Mechanism.scram_sha_256, server.seen.speculative.?);
    try testing.expect(server.seen.speculative_shape);
    try testing.expectEqualStrings("admin", server.seen.database.slice().?);
}

test "a server that does not take the speculative attempt gets saslStart with the mechanism its list names" {
    try within5s(testing.io, speculativeLeft, .{testing.io});
}

fn speculativeLeft(io: Io) !void {
    {
        var server: ScramServer = .{ .speculative = false };
        var d: Diagnostics = .{};
        try openAs(io, &server, credentials(null), &d);
        try expectSteps(&.{ .sasl_start, .sasl_continue }, &server);
        try testing.expectEqual(Mechanism.scram_sha_256, server.seen.mechanism.?);
        try testing.expect(server.seen.skip_empty_asked);
    }
    {
        // A user with SCRAM-SHA-1 only: the server leaves the speculative
        // SCRAM-SHA-256 unanswered, and its list names SCRAM-SHA-1.
        var server: ScramServer = .{ .mechanisms = &.{.scram_sha_1} };
        var d: Diagnostics = .{};
        try openAs(io, &server, credentials(null), &d);
        try expectSteps(&.{ .sasl_start, .sasl_continue }, &server);
        try testing.expectEqual(Mechanism.scram_sha_256, server.seen.speculative.?);
        try testing.expectEqual(Mechanism.scram_sha_1, server.seen.mechanism.?);
    }
    {
        // No list, as for a user mongod does not know: SCRAM-SHA-1.
        var server: ScramServer = .{ .speculative = false, .list_mechanisms = false };
        var d: Diagnostics = .{};
        try openAs(io, &server, credentials(null), &d);
        try testing.expectEqual(Mechanism.scram_sha_1, server.seen.mechanism.?);
    }
}

test "authMechanism goes as it is: hello asks for no mechanisms and tries that one" {
    try within5s(testing.io, explicitMechanism, .{testing.io});
}

fn explicitMechanism(io: Io) !void {
    var server: ScramServer = .{};
    var d: Diagnostics = .{};
    try openAs(io, &server, credentials(.scram_sha_1), &d);
    try expectSteps(&.{.sasl_continue}, &server);
    try testing.expect(server.seen.asked_for.slice() == null);
    try testing.expectEqual(Mechanism.scram_sha_1, server.seen.speculative.?);

    var started: ScramServer = .{ .speculative = false };
    try openAs(io, &started, credentials(.scram_sha_256), &d);
    try testing.expectEqual(Mechanism.scram_sha_256, started.seen.mechanism.?);
}

test "a server that does not skip the empty exchange gets one more saslContinue, with an empty payload" {
    try within5s(testing.io, emptyExchange, .{testing.io});
}

fn emptyExchange(io: Io) !void {
    var speculative: ScramServer = .{ .skip_empty_exchange = false };
    var d: Diagnostics = .{};
    try openAs(io, &speculative, credentials(null), &d);
    try expectSteps(&.{ .sasl_continue, .sasl_continue_empty }, &speculative);
    var started: ScramServer = .{ .skip_empty_exchange = false, .speculative = false };
    try openAs(io, &started, credentials(null), &d);
    try expectSteps(&.{ .sasl_start, .sasl_continue, .sasl_continue_empty }, &started);
}

test "codes 18 and 334 of saslStart are AuthenticationFailed, with the server's error" {
    try within5s(testing.io, refusedByServer, .{testing.io});
}

fn refusedByServer(io: Io) !void {
    {
        var server: ScramServer = .{ .speculative = false, .refuse = 18 };
        var d: Diagnostics = .{};
        try testing.expectError(error.AuthenticationFailed, openAs(io, &server, credentials(null), &d));
        try expectSteps(&.{.sasl_start}, &server);
        try testing.expectEqual(@as(i32, 18), d.server.?.code);
        try testing.expectEqualStrings("Authentication failed.", d.message());
        try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
    }
    // A user without SCRAM-SHA-256 credentials, asked for them.
    var server: ScramServer = .{ .mechanisms = &.{.scram_sha_1} };
    var d: Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, openAs(io, &server, credentials(.scram_sha_256), &d));
    try expectSteps(&.{.sasl_start}, &server);
    try testing.expectEqual(@as(i32, 334), d.server.?.code);
    try testing.expectEqualStrings("MechanismUnavailable", d.server.?.code_name.slice());
}

test "a foreign nonce, fewer than 4096 iterations and a wrong signature of the server are AuthenticationFailed" {
    try within5s(testing.io, brokenServer, .{testing.io});
}

/// `server` breaks SCRAM; the client refuses with `message` after `steps`.
fn expectBroken(io: Io, server: ScramServer, steps: []const Step, message: []const u8) !void {
    var s = server;
    var d: Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, openAs(io, &s, credentials(null), &d));
    try expectSteps(steps, &s);
    try testing.expectEqualStrings(message, d.message());
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
}

fn brokenServer(io: Io) !void {
    const foreign = "the server's nonce does not extend the client's: the reply is not to this conversation";
    try expectBroken(io, .{ .tamper = .foreign_nonce, .speculative = false }, &.{.sasl_start}, foreign);
    // The speculative answer in hello is checked the same way.
    try expectBroken(io, .{ .tamper = .foreign_nonce }, &.{}, foreign);
    try expectBroken(io, .{ .iterations = 4095, .speculative = false }, &.{.sasl_start}, "the server asks for 4095 iterations of SCRAM, and 4096 is the least that is safe");
    const wrong = "the server's signature in SCRAM is wrong: the server does not hold the user's keys";
    try expectBroken(io, .{ .tamper = .wrong_signature, .speculative = false }, &.{ .sasl_start, .sasl_continue }, wrong);
    try expectBroken(io, .{ .tamper = .wrong_signature }, &.{.sasl_continue}, wrong);
    try expectBroken(io, .{ .tamper = .no_signature }, &.{.sasl_continue}, "the server's final message of SCRAM holds no signature (v=)");
}

test "a server that hangs up during SCRAM leaves the client Unavailable" {
    try within5s(testing.io, hangUp, .{testing.io});
}

fn hangUp(io: Io) !void {
    var server: ScramServer = .{ .tamper = .hang_up };
    var d: Diagnostics = .{};
    try testing.expectError(error.Unavailable, openAs(io, &server, credentials(null), &d));
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
    // A network error after hello: no labels of overload.
    try testing.expect(d.server == null);
}

test "a user with ',' and '=' goes escaped in SCRAM and as it is in saslSupportedMechs, and the user's database is where SASL goes" {
    try within5s(testing.io, escapedUser, .{testing.io});
}

fn escapedUser(io: Io) !void {
    var server: ScramServer = .{ .user = "a,b=c", .source = "app" };
    var d: Diagnostics = .{};
    try openAs(io, &server, .{ .username = "a,b=c", .password = "secret", .source = "app", .mechanism = null }, &d);
    try testing.expectEqualStrings("a=2Cb=3Dc", server.seen.sasl_name.slice().?);
    try testing.expectEqualStrings("app.a,b=c", server.seen.asked_for.slice().?);
    try testing.expect(server.seen.speculative_shape);
    try testing.expectEqualStrings("app", server.seen.database.slice().?);
}

test "SCRAM-SHA-256 with a password that is not printable ASCII is Unsupported before SCRAM starts, and not tried in hello; SCRAM-SHA-1 takes it" {
    try within5s(testing.io, nonAsciiPassword, .{testing.io});
}

fn nonAsciiPassword(io: Io) !void {
    {
        var server: ScramServer = .{ .password = "Ⅳ", .mechanisms = &.{.scram_sha_256} };
        var d: Diagnostics = .{};
        try testing.expectError(error.Unsupported, openAs(io, &server, .{ .username = "app", .password = "Ⅳ", .source = "admin", .mechanism = null }, &d));
        try expectSteps(&.{}, &server);
        try testing.expect(server.seen.speculative == null);
        try testing.expectEqualStrings("SCRAM-SHA-256 needs the password prepared by SASLprep, which v0.1 does for printable ASCII only: use a password of printable ASCII, or a user with SCRAM-SHA-1 credentials and authMechanism=SCRAM-SHA-1", d.message());
        try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
    }
    var server: ScramServer = .{ .password = "pässwörd", .mechanisms = &.{.scram_sha_1} };
    var d: Diagnostics = .{};
    try openAs(io, &server, .{ .username = "app", .password = "pässwörd", .source = "admin", .mechanism = null }, &d);
    try expectSteps(&.{ .sasl_start, .sasl_continue }, &server);
    try testing.expect(server.seen.speculative == null);
    try testing.expectEqual(Mechanism.scram_sha_1, server.seen.mechanism.?);
}

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

test "init takes a user, and refuses SCRAM-SHA-256 asked for with a password that is not printable ASCII" {
    var driver: Client = try .init(testing.allocator, testing.io, .{ .uri = "mongodb://app:secret@127.0.0.1:1/app" });
    driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.Unsupported, Client.init(testing.allocator, testing.io, .{ .uri = "mongodb://app:%E2%85%A3@127.0.0.1:1/?authMechanism=SCRAM-SHA-256", .diagnostics = &d }));
    try testing.expectEqualStrings("SCRAM-SHA-256 needs the password prepared by SASLprep, which v0.1 does for printable ASCII only: use a password of printable ASCII, or a user with SCRAM-SHA-1 credentials and authMechanism=SCRAM-SHA-1", d.message());
    try testing.expectError(error.Unsupported, Client.init(testing.allocator, testing.io, .{ .uri = "mongodb://app@127.0.0.1:1/?authMechanism=SCRAM-SHA-256", .password = "Ⅳ", .diagnostics = &d }));
    // SCRAM-SHA-1 takes it, and so does the server's choice, until the
    // server says which.
    var sha1: Client = try .init(testing.allocator, testing.io, .{ .uri = "mongodb://app:%E2%85%A3@127.0.0.1:1/?authMechanism=SCRAM-SHA-1" });
    sha1.deinit();
    var negotiated: Client = try .init(testing.allocator, testing.io, .{ .uri = "mongodb://app:%E2%85%A3@127.0.0.1:1/" });
    negotiated.deinit();
}

test "connect authenticates, and commands run on the authenticated connection; a wrong password is AuthenticationFailed" {
    try within5s(testing.io, connectWithUser, .{testing.io});
}

fn connectWithUser(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var buffer: [96]u8 = undefined;
    {
        var server: ScramServer = .{};
        var task = try io.concurrent(ScramServer.serve, .{ &server, io, &listener, 1 });
        var driver: Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://app:secret@127.0.0.1:{d}/", .{FakeServer.port(&listener)}) });
        var d: Diagnostics = .{};
        driver.connect(io, .root, &d) catch |err| {
            driver.deinit();
            task.cancel(io) catch {};
            return err;
        };
        const reply = driver.client().runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
        // The server ends when the client hangs up; what it saw is read
        // after it ended.
        driver.deinit();
        try task.await(io);
        (try reply).deinit();
        try expectSteps(&.{ .sasl_continue, .ping }, &server);
    }
    var server: ScramServer = .{};
    var task = try io.concurrent(ScramServer.serve, .{ &server, io, &listener, 1 });
    defer task.await(io) catch {};
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://app:wrong@127.0.0.1:{d}/", .{FakeServer.port(&listener)}) });
    defer driver.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, driver.connect(io, .root, &d));
    try testing.expectEqual(@as(i32, 18), d.server.?.code);
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
}

test "the second connection of a client authenticates with the keys of the first, without PBKDF2" {
    try within5s(testing.io, keysReused, .{testing.io});
}

fn keysReused(io: Io) !void {
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server: ScramServer = .{};
    var task = try io.concurrent(ScramServer.serve, .{ &server, io, &listener, 2 });
    var buffer: [96]u8 = undefined;
    var driver: Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://app:secret@127.0.0.1:{d}/", .{FakeServer.port(&listener)}) });
    const result = reconnect(io, &driver);
    driver.deinit();
    if (result) |_| try task.await(io) else |_| task.cancel(io) catch {};
    try result;
    try expectSteps(&.{ .sasl_continue, .other, .sasl_continue, .ping }, &server);
}

/// Connects, breaks the connection, and runs a command on the next one.
fn reconnect(io: Io, driver: *Client) !void {
    try driver.connect(io, .root, null);
    try testing.expectEqual(@as(u32, 1), driver.keys.derivations);
    const breakme: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .breakme = 1 }) };
    try testing.expectError(error.ConnectionLost, driver.client().runCommand(io, .of(.root), breakme, .{ .allocator = testing.allocator }));
    const reply = try driver.client().runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
    reply.deinit();
    try testing.expectEqual(@as(u32, 1), driver.keys.derivations);
}
