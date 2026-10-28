//! An import of ten customers, cut in the middle: what insertMany says
//! when a write of several batches stops after the server has answered
//! some of them. The server is a script on `mongo.testing.FakeServer`,
//! as in users_test.zig, that goes away at the third batch.

const std = @import("std");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const testing = std.testing;
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;

/// Answers the batches of a write as mongod does, and closes the
/// connection when the third comes: a server that goes away mid-write.
const CutAtThirdBatch = struct {
    write: Script.Write = .{},
    batches: std.atomic.Value(u32) = .init(0),

    pub fn answer(h: *CutAtThirdBatch, io: std.Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (h.batches.fetchAdd(1, .monotonic) == 2) return .close_connection;
        return h.write.answer(io, arena, request);
    }
};

const Customer = struct {
    _id: ?bson.ObjectId = null,
    number: i32,
};

test "an import cut at its third batch is IncompleteWrite, and partial says how far it came" {
    const io = testing.io;
    var cut: CutAtThirdBatch = .{};
    var script: Script = .init(testing.allocator, .init(&cut));
    defer script.deinit();
    // The server takes 3 documents a batch: 10 go in 4 batches.
    script.hello.max_write_batch_size = 3;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};
    var uri: [64]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer client.deinit();
    try client.connect(io, .root, null);
    var ids: bson.ObjectId.Generator = .init(io);
    const customers = mongo.Database.init(&client, "shop", &ids).collection("customers");

    var list: [10]Customer = undefined;
    for (&list, 1..) |*customer, number| customer.* = .{ .number = @intCast(number) };
    var partial: mongo.Collection.InsertManyResult = .{};
    defer partial.deinit(testing.allocator);
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.IncompleteWrite, customers.insertMany(io, .of(.root), &list, .{
        .allocator = testing.allocator,
        .partial = &partial,
        .diagnostics = &d,
    }));
    // The server answered two batches: 6 customers are in.
    try testing.expectEqual(@as(usize, 6), partial.answered);
    try testing.expectEqual(@as(u64, 6), partial.inserted);
    // The write stopped at the batch that begins with the seventh
    // customer, index 6, as its connection was lost: that batch went out
    // and may be in. The last one never went.
    try testing.expectEqual(@as(?usize, 6), d.batch_offset);
    const reason = d.reason orelse return error.TestUnexpectedResult;
    try testing.expectEqual(error.ConnectionLost, reason);
    try testing.expectEqual(mongo.Outcome.may_have_executed, mongo.outcome(reason));
    try testing.expectEqual(@as(usize, 3), script.count(io, "insert"));
    // The _ids of all ten were made before the first batch: the customers
    // after `answered` can be looked up by them before they are sent again.
    try testing.expectEqual(@as(usize, 10), partial.inserted_ids.len);
    for (partial.inserted_ids) |id| try testing.expect(id == .object_id);
}
