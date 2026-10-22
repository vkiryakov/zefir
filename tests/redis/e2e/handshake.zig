//! The client's `connect` against real servers, on the image that
//! REDIS_IMAGE names: it shakes hands with redis-plain, with and without a
//! name, a database and a password, finds that a database of the URL is
//! not on the server, and refuses redis-cluster and redis-old with the
//! reason. The server sees what the handshake told it: the library and
//! its version in CLIENT INFO, the name of the client in CLIENT LIST, and
//! the database of the URL.

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

/// `connect` of a client of `options` under a deadline of 10 s, closed
/// once it returns: what it failed with, and why in `d`.
fn connectOnce(io: Io, options: redis.Client.Options, d: *redis.Diagnostics) redis.Error!void {
    var client = redis.Client.init(testing.allocator, io, options) catch |err| {
        std.debug.print("init: {t}\n", .{err});
        return error.InvalidArgument;
    };
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), d);
    // Once connected, connect does nothing.
    try client.connect(io, within(io, .fromSeconds(10)), d);
    client.close(io);
}

fn expectConnects(io: Io, options: redis.Client.Options) !void {
    var d: redis.Diagnostics = .{};
    connectOnce(io, options, &d) catch |err| {
        std.debug.print("{s}: {t}: {s}\n", .{ options.url, err, d.message() });
        return err;
    };
}

test "the client shakes hands with redis-plain: with a name, a database of the URL, and a password that the user default without one takes" {
    try e2e.onZio(plainServer);
}

fn plainServer(io: Io) !void {
    try expectConnects(io, .{ .url = "redis://127.0.0.1:16379" });
    try expectConnects(io, .{ .url = "redis://127.0.0.1:16379/3", .client_name = "zefir-e2e" });
    try expectConnects(io, .{ .url = "redis://:any-password@127.0.0.1:16379/15" });
}

test "a database of the URL that the server lacks is InvalidArgument, and the text names it" {
    try e2e.onZio(missingDatabase);
}

fn missingDatabase(io: Io) !void {
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, connectOnce(io, .{ .url = "redis://127.0.0.1:16379/20" }, &d));
    try testing.expectEqualStrings("database 20 of the URL is not on the server", d.message());
}

test "a cluster node is Unsupported, and the text says so" {
    try e2e.onZio(clusterNode);
}

fn clusterNode(io: Io) !void {
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.Unsupported, connectOnce(io, .{ .url = "redis://127.0.0.1:16383" }, &d));
    try expectText(&d, "is a cluster node; v0.1 talks to one standalone server");
}

test "Redis 6.2 is Unsupported, and the text names its version" {
    try e2e.onZio(oldServer);
}

fn oldServer(io: Io) !void {
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.Unsupported, connectOnce(io, .{ .url = "redis://127.0.0.1:16384" }, &d));
    try expectText(&d, "is Redis 6.2.24; v0.1 needs Redis 7.2 or later");
}

fn expectText(d: *const redis.Diagnostics, part: []const u8) !void {
    if (std.mem.find(u8, d.message(), part) == null) {
        std.debug.print("the text: {s}\n", .{d.message()});
        return error.TestUnexpectedText;
    }
    try testing.expectEqual(redis.Diagnostics.Phase.handshake, d.phase.?);
}

test "the server sees what the handshake told it: the library and its version, the name of the client and the database of the URL" {
    try e2e.onZio(seenByServer);
}

/// The value of `key` in a line of CLIENT INFO or CLIENT LIST, whose
/// fields are `key=value` between spaces.
fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \r\n");
    while (fields.next()) |pair| {
        if (pair.len > key.len and std.mem.startsWith(u8, pair, key) and pair[key.len] == '=') return pair[key.len + 1 ..];
    }
    return null;
}

fn expectField(line: []const u8, key: []const u8, expected: []const u8) !void {
    const value = field(line, key) orelse {
        std.debug.print("no {s} in: {s}\n", .{ key, line });
        return error.TestNoField;
    };
    try testing.expectEqualStrings(expected, value);
}

fn seenByServer(io: Io) !void {
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = "redis://127.0.0.1:16379/3", .client_name = "e2e-pool" });
    defer client.deinit();
    var d: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    const info = try client.run(io, op, cmd.raw([]const u8, .{ "CLIENT", "INFO" }), .{ .allocator = arena.allocator(), .diagnostics = &d });
    try expectField(info, "lib-name", "zefir-redis");
    const version = field(info, "lib-ver") orelse {
        std.debug.print("no lib-ver in: {s}\n", .{info});
        return error.TestNoField;
    };
    try testing.expect(version.len > 0);
    try expectField(info, "db", "3");
    const list = try client.run(io, op, cmd.raw([]const u8, .{ "CLIENT", "LIST" }), .{ .allocator = arena.allocator(), .diagnostics = &d });
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| {
        if (field(line, "name")) |name| if (std.mem.eql(u8, name, "e2e-pool")) return;
    }
    std.debug.print("no client named e2e-pool in CLIENT LIST: {s}\n", .{list});
    return error.TestNoField;
}
