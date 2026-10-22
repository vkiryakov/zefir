//! Tests of the profiles of the shop without Redis. Each runs `Profiles`
//! on a real `redis.Client`, connected to `redis.testing.FakeServer`: a
//! server on loopback that plays a script, the commands it expects and
//! what it answers them, and keeps a journal of what came.

const std = @import("std");
const redis = @import("redis");
const Profiles = @import("Profiles.zig");
const testing = std.testing;
const FakeServer = redis.testing.FakeServer;

test "a profile is read from its hash" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The script: HGETALL user:42, answered with the fields of a hash.
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HGETALL", "user:42" }, .map(&.{ .{ "name", "Ann" }, .{ "age", "30" }, .{ "plan", "pro" } })),
    });
    defer server.stop(io);
    // A client of it, as of any Redis.
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const profiles: Profiles = .init(&client);
    const ann = (try profiles.byId(io, .of(.root), arena.allocator(), 42)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expectEqual(30, ann.age);
    try testing.expectEqual(.pro, ann.plan);
    // A field that the hash lacks takes its default.
    try testing.expectEqual(0, ann.visits);
    try server.finish(io); // the script ran to its end, and nothing else came
}

test "a customer without a profile has none: HGETALL of a key that is not there answers an empty map" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HGETALL", "user:7" }, .{ .pairs = &.{} }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const profiles: Profiles = .init(&client);
    try testing.expect(try profiles.byId(io, .of(.root), arena.allocator(), 7) == null);
    try server.finish(io);
}

test "a profile is saved as a field of the hash for each field of the struct, and a visit counts in its field" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The fields go in the order of the struct, the enum as its name; the
    // server answers HSET with how many fields were new.
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HSET", "user:42", "name", "Ann", "age", "30", "plan", "pro", "visits", "0" }, .{ .integer = 4 }),
        .expect(.{ "HINCRBY", "user:42", "visits", "1" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    const profiles: Profiles = .init(&client);
    try profiles.save(io, .of(.root), 42, .{ .name = "Ann", .age = 30, .plan = .pro });
    try testing.expectEqual(1, try profiles.visit(io, .of(.root), 42));
    // The journal: what came, in order, byte for byte.
    try testing.expectEqual(2, server.received(io));
    const visit = (try server.entry(io, 1)).args;
    try testing.expectEqual(4, visit.len);
    try testing.expectEqualStrings("HINCRBY", visit[0]);
    try server.finish(io);
}
