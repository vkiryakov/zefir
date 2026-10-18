//! The client against mongo-auth, a mongod with --auth and the
//! users of init/users.js: each user gets in by the mechanism it has,
//! speculatively in hello where the server takes it, in the database the
//! connection string names; a wrong password, a user mongod does not know
//! and a mechanism the user lacks are AuthenticationFailed; a password
//! that SCRAM-SHA-256 would need SASLprep for is Unsupported before any of
//! SCRAM goes out. The counters of serverStatus show what mongod saw.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// "mongodb://<userinfo>@127.0.0.1:27118/<rest>".
fn uriOf(buffer: []u8, userinfo: []const u8, rest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "mongodb://{s}@127.0.0.1:{d}/{s}", .{ userinfo, e2e.servers.auth_port, rest });
}

/// A client of `uri`, connected; `name` says which in a failure.
fn connected(io: Io, driver: *mongo.Client, uri: []const u8, name: []const u8) !void {
    driver.* = try .init(testing.allocator, io, .{ .uri = uri });
    errdefer driver.deinit();
    var d: mongo.Diagnostics = .{};
    driver.connect(io, within(io, .fromSeconds(30)), &d) catch |err| {
        std.debug.print("{s}: connect: {t}: {s}\n", .{ name, err, d.message() });
        return err;
    };
}

/// The observer: the user `both`, root, which reads serverStatus.
fn observer(io: Io, driver: *mongo.Client, buffer: []u8) !void {
    try connected(io, driver, try uriOf(buffer, "both:both-pass", "?appName=zefir-e2e-observer"), "observer");
}

fn run(io: Io, c: *mongo.Client, body: bson.RawDocument) !bson.OwnedDocument {
    return c.runCommand(io, .of(within(io, .fromSeconds(10))), .{ .database = "admin", .body = body }, .{ .allocator = testing.allocator });
}

fn documentOf(value: ?bson.Value) !bson.RawDocument {
    const v = value orelse return error.TestUnexpectedResult;
    return switch (v) {
        .document, .array => |doc| doc,
        else => error.TestUnexpectedResult,
    };
}

fn stringOf(value: ?bson.Value) ![]const u8 {
    const v = value orelse return error.TestUnexpectedResult;
    return if (v == .string) v.string else error.TestUnexpectedResult;
}

/// The user that the connection of `c` authenticated as, by
/// connectionStatus.
fn expectUser(io: Io, c: *mongo.Client, user: []const u8, db: []const u8) !void {
    const reply = try run(io, c, bson.literal(.{ .connectionStatus = 1 }));
    defer reply.deinit();
    const authenticated = try documentOf(try reply.raw().getPath("authInfo.authenticatedUsers"));
    const first = (try authenticated.first()) orelse return error.TestUnexpectedResult;
    const entry = try documentOf(first.value);
    try testing.expectEqualStrings(user, try stringOf(try entry.get("user")));
    try testing.expectEqualStrings(db, try stringOf(try entry.get("db")));
}

/// What mongod counted of the authentications by one mechanism: tried and
/// successful, speculative in hello and in all.
const Counts = struct {
    speculative_tried: i64,
    speculative: i64,
    tried: i64,
    successful: i64,

    fn since(after: Counts, before: Counts) Counts {
        return .{
            .speculative_tried = after.speculative_tried - before.speculative_tried,
            .speculative = after.speculative - before.speculative,
            .tried = after.tried - before.tried,
            .successful = after.successful - before.successful,
        };
    }
};

/// The counters of `mechanism` in serverStatus: 9.0 keeps them under
/// `ingress`, and calls what 7.0 and 8.0 call `received` `total`.
fn counts(io: Io, c: *mongo.Client, mechanism: []const u8) !Counts {
    const reply = try run(io, c, bson.literal(.{ .serverStatus = 1 }));
    defer reply.deinit();
    const mechanisms = try documentOf(try reply.raw().getPath("security.authentication.mechanisms"));
    var of = try documentOf(try mechanisms.get(mechanism));
    if (try of.get("ingress")) |ingress| of = try documentOf(ingress);
    const speculative = try documentOf(try of.get("speculativeAuthenticate"));
    const all = try documentOf(try of.get("authenticate"));
    return .{
        .speculative_tried = try tried(speculative),
        .speculative = try number(speculative, "successful"),
        .tried = try tried(all),
        .successful = try number(all, "successful"),
    };
}

fn tried(counters: bson.RawDocument) !i64 {
    return number(counters, "received") catch number(counters, "total");
}

fn number(doc: bson.RawDocument, key: []const u8) !i64 {
    const value = (try doc.get(key)) orelse return error.TestUnexpectedResult;
    return value.asI64();
}

const Both = struct { sha1: Counts, sha256: Counts };

fn countsOfBoth(io: Io, c: *mongo.Client) !Both {
    return .{ .sha1 = try counts(io, c, "SCRAM-SHA-1"), .sha256 = try counts(io, c, "SCRAM-SHA-256") };
}

const Mechanism = enum { sha1, sha256 };

const User = struct {
    name: []const u8,
    /// Percent-encoded, as the connection string holds it.
    userinfo: []const u8,
    /// The path and the options of the connection string.
    rest: []const u8 = "",
    /// Who connectionStatus says the connection is.
    user: []const u8,
    db: []const u8 = "admin",
    /// The mechanism that authenticated it, and whether the speculative
    /// conversation of hello did.
    mechanism: Mechanism,
    speculative: bool,
};

const users = [_]User{
    // The speculative SCRAM-SHA-256 fails for a user without its
    // credentials, and the server's list of the user's mechanisms picks
    // SCRAM-SHA-1.
    .{ .name = "sha1", .userinfo = "sha1:sha1-pass", .user = "sha1", .mechanism = .sha1, .speculative = false },
    .{ .name = "sha1, authMechanism=SCRAM-SHA-1", .userinfo = "sha1:sha1-pass", .rest = "?authMechanism=SCRAM-SHA-1", .user = "sha1", .mechanism = .sha1, .speculative = true },
    .{ .name = "sha256", .userinfo = "sha256:sha256-pass", .user = "sha256", .mechanism = .sha256, .speculative = true },
    .{ .name = "both", .userinfo = "both:both-pass", .user = "both", .mechanism = .sha256, .speculative = true },
    .{ .name = "both, authMechanism=SCRAM-SHA-1", .userinfo = "both:both-pass", .rest = "?authMechanism=SCRAM-SHA-1", .user = "both", .mechanism = .sha1, .speculative = true },
    .{ .name = "IX with IX", .userinfo = "IX:IX", .user = "IX", .mechanism = .sha256, .speculative = true },
    // IV is what SASLprep makes of Ⅳ, and the user goes as it is.
    .{ .name = "Ⅸ with IV", .userinfo = "%E2%85%A8:IV", .user = "Ⅸ", .mechanism = .sha256, .speculative = true },
    .{ .name = "app, its database in the path", .userinfo = "app:app-pass", .rest = "app", .user = "app", .db = "app", .mechanism = .sha256, .speculative = true },
    .{ .name = "app, authSource=app", .userinfo = "app:app-pass", .rest = "?authSource=app", .user = "app", .db = "app", .mechanism = .sha256, .speculative = true },
};

test "every user of users.js gets in, by the mechanism it has, speculatively in hello where it can" {
    try e2e.onZio(everyUser);
}

fn everyUser(io: Io) !void {
    var watch: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try observer(io, &watch, &buffer);
    defer watch.deinit();
    for (users) |u| {
        const before = try countsOfBoth(io, &watch);
        var driver: mongo.Client = undefined;
        try connected(io, &driver, try uriOf(&buffer, u.userinfo, u.rest), u.name);
        defer driver.deinit();
        expectUser(io, &driver, u.user, u.db) catch |err| {
            std.debug.print("{s}: {t}\n", .{ u.name, err });
            return err;
        };
        const after = try countsOfBoth(io, &watch);
        const sha1 = after.sha1.since(before.sha1);
        const sha256 = after.sha256.since(before.sha256);
        const used, const other = switch (u.mechanism) {
            .sha1 => .{ sha1, sha256 },
            .sha256 => .{ sha256, sha1 },
        };
        testing.expectEqual(@as(i64, 1), used.successful) catch |err| {
            std.debug.print("{s}: {d} successful by its mechanism\n", .{ u.name, used.successful });
            return err;
        };
        try testing.expectEqual(@as(i64, @intFromBool(u.speculative)), used.speculative);
        try testing.expectEqual(@as(i64, 0), other.successful);
    }
}

test "without a user mongo-auth refuses commands, so the users above authenticated" {
    try e2e.onZio(withoutUser);
}

fn withoutUser(io: Io) !void {
    var buffer: [96]u8 = undefined;
    var driver: mongo.Client = try .init(testing.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.auth_port}) });
    defer driver.deinit();
    try driver.connect(io, within(io, .fromSeconds(10)), null);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.CommandFailed, driver.runCommand(io, .of(.root), .{ .database = "admin", .body = bson.literal(.{ .listDatabases = 1 }) }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 13), d.server.?.code);
}

test "a wrong password, a user mongod does not know and a mechanism the user lacks are AuthenticationFailed, with the server's code" {
    try e2e.onZio(refusedUsers);
}

fn refusedUsers(io: Io) !void {
    const cases = [_]struct { []const u8, []const u8, []const u8, i32 }{
        .{ "sha256 with a wrong password", "sha256:wrong", "", 18 },
        .{ "sha1 with a wrong password", "sha1:wrong", "", 18 },
        .{ "a user mongod does not know", "nobody:secret", "", 18 },
        .{ "app, looked for in admin", "app:app-pass", "", 18 },
        .{ "sha1 asking for SCRAM-SHA-256", "sha1:sha1-pass", "?authMechanism=SCRAM-SHA-256", 334 },
    };
    var buffer: [160]u8 = undefined;
    for (cases) |case| {
        const name, const userinfo, const rest, const code = case;
        var driver: mongo.Client = try .init(testing.allocator, io, .{ .uri = try uriOf(&buffer, userinfo, rest) });
        defer driver.deinit();
        var d: mongo.Diagnostics = .{};
        driver.connect(io, within(io, .fromSeconds(30)), &d) catch |err| {
            testing.expectEqual(error.AuthenticationFailed, err) catch |e| {
                std.debug.print("{s}: {t}: {s}\n", .{ name, err, d.message() });
                return e;
            };
            try testing.expectEqual(code, d.server.?.code);
            try testing.expectEqual(mongo.Diagnostics.Phase.authenticate, d.phase.?);
            try testing.expectEqual(@as(usize, 0), driver.stats().connections);
            continue;
        };
        std.debug.print("{s}: connected\n", .{name});
        return error.TestUnexpectedResult;
    }
}

test "a password that SCRAM-SHA-256 would need SASLprep for is Unsupported, and none of SCRAM reaches mongod" {
    try e2e.onZio(saslPrep);
}

fn saslPrep(io: Io) !void {
    var watch: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try observer(io, &watch, &buffer);
    defer watch.deinit();
    const hint = "SCRAM-SHA-256 needs the password prepared by SASLprep, which v0.1 does for printable ASCII only: use a password of printable ASCII, or a user with SCRAM-SHA-1 credentials and authMechanism=SCRAM-SHA-1";
    // Ⅸ with Ⅳ, and IX with I, a soft hyphen and X, which SASLprep makes IX.
    for ([_][]const u8{ "%E2%85%A8:%E2%85%A3", "IX:I%C2%ADX" }) |userinfo| {
        const before = try counts(io, &watch, "SCRAM-SHA-256");
        var driver: mongo.Client = try .init(testing.allocator, io, .{ .uri = try uriOf(&buffer, userinfo, "") });
        defer driver.deinit();
        var d: mongo.Diagnostics = .{};
        try testing.expectError(error.Unsupported, driver.connect(io, within(io, .fromSeconds(30)), &d));
        try testing.expectEqualStrings(hint, d.message());
        const seen = (try counts(io, &watch, "SCRAM-SHA-256")).since(before);
        try testing.expectEqual(@as(i64, 0), seen.speculative_tried);
        try testing.expectEqual(@as(i64, 0), seen.tried);
    }
    // Asked for by authMechanism, it is refused at init.
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Unsupported, mongo.Client.init(testing.allocator, io, .{ .uri = try uriOf(&buffer, "%E2%85%A8:%E2%85%A3", "?authMechanism=SCRAM-SHA-256"), .diagnostics = &d }));
    try testing.expectEqualStrings(hint, d.message());
}

test "a connection after the first authenticates with the keys of the first: PBKDF2 runs once" {
    try e2e.onZio(cachedKeys);
}

fn cachedKeys(io: Io) !void {
    var watch: mongo.Client = undefined;
    var buffer: [160]u8 = undefined;
    try observer(io, &watch, &buffer);
    defer watch.deinit();
    const iterations = iterations: {
        const reply = try run(io, &watch, bson.literal(.{ .getParameter = 1, .scramSHA256IterationCount = 1 }));
        defer reply.deinit();
        break :iterations try number(reply.raw(), "scramSHA256IterationCount");
    };

    var driver: mongo.Client = try .init(testing.allocator, io, .{ .uri = try uriOf(&buffer, "sha256:sha256-pass", "?appName=zefir-e2e-keys") });
    defer driver.deinit();
    const clock: Io.Clock = .awake;
    const start = clock.now(io);
    try driver.connect(io, within(io, .fromSeconds(30)), null);
    const first = start.durationTo(clock.now(io));
    try testing.expectEqual(@as(u32, 1), driver.keys.derivations);

    // mongod closes the connection on the next ping of this client.
    const fail_point = bson.literal(.{
        .configureFailPoint = "failCommand",
        .mode = .{ .times = 1 },
        .data = .{ .failCommands = .{"ping"}, .closeConnection = true, .appName = "zefir-e2e-keys" },
    });
    const set = try run(io, &watch, fail_point);
    set.deinit();
    defer if (run(io, &watch, bson.literal(.{ .configureFailPoint = "failCommand", .mode = "off" }))) |off| off.deinit() else |_| {};
    const ping = bson.literal(.{ .ping = 1 });
    try testing.expectError(error.ConnectionLost, run(io, &driver, ping));
    const again = clock.now(io);
    const reply = try run(io, &driver, ping);
    reply.deinit();
    const second = again.durationTo(clock.now(io));
    try testing.expectEqual(@as(u32, 1), driver.keys.derivations);
    try expectUser(io, &driver, "sha256", "admin");
    std.debug.print("     SCRAM-SHA-256, {d} iterations: the first connection {d} ms, the next with the cached keys {d} ms\n", .{ iterations, first.toMilliseconds(), second.toMilliseconds() });
}
