//! The checks S and L of zefir-mongo's client, from the file of the zefir
//! package that `zig build test-mongo` runs layer S of
//! (src/mongo/tests/checks.zig): layer S against the scripted server of
//! each check, layer L against mongo-plain, with fail points.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const checks = @import("checks");
const e2e = @import("root.zig");

test "the checks S and L of the client: S against the scripted server of each check, L with fail points against mongo-plain" {
    try e2e.onZio(everyCheck);
}

fn everyCheck(io: Io) !void {
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port});
    try failPointOff(io, uri);
    for (std.enums.values(checks.Check)) |check| {
        try checks.run(io, testing.allocator, check, .{ .live = .{ .uri = uri, .fail_points = true } });
    }
}

/// Turns the fail point `failCommand` of `uri` off: a run that died in
/// the middle of L7–L10 leaves it on, for the next command of its kind.
fn failPointOff(io: Io, uri: []const u8) !void {
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(10)));
    try client.connect(io, ctx, null);
    defer client.close(io);
    const off = bson.literal(.{ .configureFailPoint = "failCommand", .mode = "off" });
    const reply = try client.runCommand(io, .of(ctx), .{ .database = "admin", .body = off }, .{ .allocator = testing.allocator });
    reply.deinit();
}
