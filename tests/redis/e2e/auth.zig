//! The users of redis-auth, tests/redis/conf/users.acl, each with the
//! password `<name>-pass`, on the image that REDIS_IMAGE names: `app` and
//! `default` connect; a wrong password and the user `gone`, which is off,
//! are AuthenticationFailed, and so is no password, with the hint of
//! NOAUTH; `limited` reaches its keys `app:*` and no other.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// `connect` of a client of `url` under a deadline of 10 s: what it failed
/// with, and why in `d`.
fn connectOnce(io: Io, url: []const u8, d: *redis.Diagnostics) redis.Error!void {
    var client = redis.Client.init(testing.allocator, io, .{ .url = url }) catch |err| {
        std.debug.print("init: {t}\n", .{err});
        return error.InvalidArgument;
    };
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), d);
}

fn expectConnects(io: Io, url: []const u8) !void {
    var d: redis.Diagnostics = .{};
    connectOnce(io, url, &d) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ url, err, d.message() });
        return err;
    };
}

fn expectRefused(io: Io, url: []const u8) !redis.Diagnostics {
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, connectOnce(io, url, &d));
    try testing.expectEqual(redis.Diagnostics.Phase.handshake, d.phase.?);
    return d;
}

test "a user with its password connects, and so does default with :password@" {
    try e2e.onZio(rightPasswords);
}

fn rightPasswords(io: Io) !void {
    try expectConnects(io, "redis://app:app-pass@127.0.0.1:16380");
    try expectConnects(io, "redis://:default-pass@127.0.0.1:16380/1");
}

test "a wrong password and a user that is off are AuthenticationFailed, and no password is too, with the hint of NOAUTH" {
    try e2e.onZio(refusedUsers);
}

fn refusedUsers(io: Io) !void {
    var d = try expectRefused(io, "redis://app:not-the-pass@127.0.0.1:16380");
    try testing.expect(d.isCode("WRONGPASS"));
    d = try expectRefused(io, "redis://gone:gone-pass@127.0.0.1:16380");
    try testing.expect(d.isCode("WRONGPASS"));
    d = try expectRefused(io, "redis://127.0.0.1:16380");
    try testing.expectEqualStrings("the server wants a password: set it in the URL or in Options.password", d.message());
}

test "a user limited to the keys app:* sets one of them, and setting another is ServerError NOPERM" {
    try e2e.onZio(limitedKeys);
}

fn limitedKeys(io: Io) !void {
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = "redis://limited:limited-pass@127.0.0.1:16380" });
    defer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    client.run(io, op, cmd.raw(void, .{ "SET", "app:1", "x" }), .{ .diagnostics = &d }) catch |err| {
        std.debug.print("SET app:1: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    defer client.run(io, op, cmd.raw(void, .{ "DEL", "app:1" }), .{}) catch {};
    try testing.expectError(error.ServerError, client.run(io, op, cmd.raw(void, .{ "SET", "other:1", "x" }), .{ .diagnostics = &d }));
    try testing.expect(d.isCode("NOPERM"));
}
