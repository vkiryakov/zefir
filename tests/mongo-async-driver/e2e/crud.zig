//! The collection API against mongod, on `FakeDriver` through `Proxy`
//! against mongo-plain, with a `maxWriteBatchSize` of 3, so that writes go
//! out in several batches. The scenarios are those of crud_scenarios.zig,
//! which every driver runs.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;
const e2e = @import("root.zig");
const Proxy = @import("Proxy.zig");
const crud_scenarios = @import("crud_scenarios.zig");

test "the collection API on FakeDriver through the proxy against mongo-plain, at a maxWriteBatchSize of 3" {
    try e2e.onZio(onFakeDriver);
}

fn onFakeDriver(io: Io) !void {
    var proxy: Proxy = .init(testing.allocator, e2e.servers.plain_port);
    defer proxy.deinit(io);
    var script: Script = .init(testing.allocator, proxy.handler());
    defer script.deinit();
    script.hello.max_write_batch_size = 3;
    var fake: FakeDriver = .init(testing.allocator, &script);
    defer fake.deinit();
    defer fake.close(io);
    var ids: bson.ObjectId.Generator = .init(io);
    try crud_scenarios.runAll(io, .init(fake.client(), e2e.database, &ids));

    // The writes went out in batches of 3 items at most, and some in
    // batches of exactly 3.
    var full: usize = 0;
    for (0..script.received(io)) |i| {
        const entry = script.entry(io, i);
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
        const entry = script.entry(io, i);
        if (!std.mem.eql(u8, entry.name, "getMore")) continue;
        const size = (try entry.body.get("batchSize")) orelse continue;
        if (try size.asI64() == 7) sevens += 1;
    }
    try testing.expectEqual(@as(usize, 35), sevens);
}
