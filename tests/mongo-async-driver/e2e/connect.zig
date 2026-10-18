//! The native driver against mongod: it connects to mongo-plain and runs
//! commands there, and refuses mongo-ghost, a member of a replica set that
//! is not initialized yet.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const native = @import("mongo-async-driver");
const bson = mongo.bson;
const e2e = @import("root.zig");

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

fn within(io: Io, duration: Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration));
}

/// A client of `port`, connected.
fn connected(io: Io, driver: *native.Client, uri_buffer: []u8, port: u16) !void {
    const uri = try std.fmt.bufPrint(uri_buffer, "mongodb://127.0.0.1:{d}/?appName=zefir-e2e", .{port});
    driver.* = try .init(testing.allocator, io, .{ .uri = uri });
    errdefer driver.deinit();
    var d: mongo.Diagnostics = .{};
    driver.connect(io, within(io, .fromSeconds(10)), &d) catch |err| {
        std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
        return err;
    };
}

test "the native driver connects to mongo-plain, pings it and runs commands from many tasks" {
    try e2e.onZio(connectAndPing);
}

fn pingOnce(io: Io, c: mongo.Client) !void {
    const reply = try c.runCommand(io, .of(within(io, .fromSeconds(10))), ping, .{ .allocator = testing.allocator });
    reply.deinit();
}

fn connectAndPing(io: Io) !void {
    var driver: native.Client = undefined;
    var buffer: [128]u8 = undefined;
    try connected(io, &driver, &buffer, e2e.servers.plain_port);
    defer driver.deinit();
    const c = driver.client();
    const reply = try c.runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator });
    defer reply.deinit();
    try testing.expectEqual(@as(f64, 1), try (try reply.raw().get("ok")).?.asF64());
    const server = c.capabilities().server.?;
    try testing.expect(server.max_wire_version >= 21);
    try testing.expectEqual(@as(u32, 48_000_000), server.max_message_size_bytes);

    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.CommandFailed, c.runCommand(io, .of(.root), .{ .database = "admin", .body = bson.literal(.{ .zefirNoSuchCommand = 1 }) }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqual(@as(i32, 59), d.server.?.code);

    // Tasks take turns on the one connection.
    var group: Io.Group = .init;
    var failures: std.atomic.Value(u32) = .init(0);
    for (0..16) |_| group.concurrent(io, pingCounted, .{ io, c, &failures }) catch try pingOnce(io, c);
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
}

fn pingCounted(io: Io, c: mongo.Client, failures: *std.atomic.Value(u32)) void {
    pingOnce(io, c) catch {
        _ = failures.fetchAdd(1, .acq_rel);
    };
}

test "a deadline that passes while mongod works is Timeout, and the next call opens a new connection" {
    try e2e.onZio(deadlineInFlight);
}

fn deadlineInFlight(io: Io) !void {
    var driver: native.Client = undefined;
    var buffer: [128]u8 = undefined;
    try connected(io, &driver, &buffer, e2e.servers.plain_port);
    defer driver.deinit();
    const c = driver.client();
    // sleep is a test command of mongo-plain; no maxTimeMS stops it.
    const sleep: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .sleep = 1, .millis = 500 }) };
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Timeout, c.runCommand(io, .of(within(io, .fromMilliseconds(100))), sleep, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    try testing.expectEqual(@as(usize, 0), driver.stats().connections);
    try pingOnce(io, c);
    try testing.expectEqual(@as(usize, 1), driver.stats().connections);
}

test "mongo-ghost, a member of a replica set not initialized yet, is Unsupported with RSGhost in the text" {
    try e2e.onZio(ghost);
}

fn ghost(io: Io) !void {
    var buffer: [128]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.ghost_port});
    var driver: native.Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer driver.deinit();
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.Unsupported, driver.connect(io, within(io, .fromSeconds(10)), &d));
    var expected: [160]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "the server at 127.0.0.1:{d} is a replica set member not initialized yet (RSGhost); v0.1 supports standalone mongod only", .{e2e.servers.ghost_port}), d.message());
    try testing.expectEqual(mongo.Diagnostics.Phase.handshake, d.phase.?);
    try testing.expectError(error.Unavailable, driver.client().runCommand(io, .of(.root), ping, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("connect() has not succeeded", d.message());
}
