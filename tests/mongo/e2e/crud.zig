//! The collection API against mongo-plain: on a client of mongo-plain, and
//! on a client of a FakeServer with a `maxWriteBatchSize` of 3 whose
//! script relays every command to mongo-plain, so that writes go out in
//! several batches, each answered by mongod. The scenarios are those of
//! crud_scenarios.zig.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;
const e2e = @import("root.zig");
const Relay = @import("Relay.zig");
const crud_scenarios = @import("crud_scenarios.zig");

/// A client of `uri`, connected.
fn connected(io: Io, client: *mongo.Client, uri: []const u8) !void {
    client.* = try .init(testing.allocator, io, .{ .uri = uri });
    errdefer client.deinit();
    var d: mongo.Diagnostics = .{};
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(10)));
    client.connect(io, ctx, &d) catch |err| {
        std.debug.print("connect to {s}: {t}: {s}\n", .{ uri, err, d.message() });
        return err;
    };
}

test "the collection API on a client of mongo-plain" {
    try e2e.onZio(direct);
}

fn direct(io: Io) !void {
    var buffer: [64]u8 = undefined;
    var client: mongo.Client = undefined;
    try connected(io, &client, try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port}));
    defer client.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    try crud_scenarios.runAll(io, .init(&client, e2e.database, &ids), .{});
}

test "the collection API on a client of a FakeServer that relays to mongo-plain, at a maxWriteBatchSize of 3" {
    try e2e.onZio(relayed);
}

fn relayed(io: Io) !void {
    var mongod_uri: [64]u8 = undefined;
    var mongod: mongo.Client = undefined;
    try connected(io, &mongod, try std.fmt.bufPrint(&mongod_uri, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port}));
    defer mongod.deinit();
    var relay: Relay = .{ .mongod = &mongod };
    var script: Script = .init(testing.allocator, relay.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = undefined;
    try connected(io, &client, try FakeServer.uri(&listener, &uri));
    defer client.deinit();
    var ids: bson.ObjectId.Generator = .init(io);
    try crud_scenarios.runAll(io, .init(&client, e2e.database, &ids), .{ .max_write_batch_size = 3 });

    // The writes went out in batches of 3 items at most, and some in
    // batches of exactly 3.
    var full: usize = 0;
    for (0..script.received(io)) |i| {
        const entry = try script.entry(io, i);
        const sequence = entry.sequence orelse continue;
        var docs = sequence.documents();
        var n: usize = 0;
        while (docs.next()) |_| n += 1;
        try testing.expect(n <= 3);
        if (n == 3) full += 1;
    }
    try testing.expect(full >= 3);

    // The find of 250 documents at a batch size of 7: a first batch and 35
    // getMores of 7.
    var sevens: usize = 0;
    for (0..script.received(io)) |i| {
        const entry = try script.entry(io, i);
        if (!std.mem.eql(u8, entry.name, "getMore")) continue;
        const size = (try entry.body.get("batchSize")) orelse continue;
        if (try size.asI64() == 7) sevens += 1;
    }
    try testing.expectEqual(@as(usize, 35), sevens);
}
