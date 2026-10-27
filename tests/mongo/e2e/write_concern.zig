//! `write_concern` against mongo-plain: mongod acknowledges the writes of
//! the collection API with `journal`, with `.majority`, a standalone
//! server being a majority of one, and with both, and the writes are there
//! when read back. The test works in a collection of its own, which it
//! drops before and after.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const e2e = @import("root.zig");

test "journal and majority writes are acknowledged by mongod" {
    try e2e.onZio(acknowledged);
}

/// The collection of the test, in `e2e.database`.
const name = "write_concern";

fn acknowledged(io: Io) !void {
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port});
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = uri });
    defer client.deinit();
    // Under a deadline, so that every command takes maxTimeMS to mongod
    // and a server that stops answering fails the test.
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(30)));
    var d: mongo.Diagnostics = .{};
    client.connect(io, ctx, &d) catch |err| return report(err, &d, "connect");
    defer client.close(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const orders = mongo.Database.init(&client, e2e.database, &ids).collection(name);
    const op: mongo.OperationContext = .of(ctx);
    const gpa = testing.allocator;
    orders.drop(io, op, .{ .allocator = gpa, .diagnostics = &d }) catch |err| return report(err, &d, "drop");
    defer orders.drop(io, op, .{ .allocator = gpa }) catch {};

    const concerns = [_]mongo.WriteConcern{ .{ .journal = true }, .{ .w = .majority }, .{ .w = .majority, .journal = true } };
    for (concerns, 0..) |concern, i| {
        const id: i32 = @intCast(i);
        var inserted = orders.insertOne(io, op, .{ ._id = id, .n = 1 }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }) catch |err|
            return report(err, &d, "insertOne");
        inserted.deinit(gpa);

        var updated = orders.updateOne(io, op, .{ ._id = id }, .{ .@"$inc" = .{ .n = 1 } }, .{ .allocator = gpa, .write_concern = concern, .diagnostics = &d }) catch |err|
            return report(err, &d, "updateOne");
        defer updated.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), updated.matched);
        try testing.expectEqual(@as(u64, 1), updated.modified);

        const raised = orders.findOneAndUpdate(io, op, .{ ._id = id }, .{ .@"$inc" = .{ .n = 1 } }, .{
            .allocator = gpa,
            .return_document = .after,
            .write_concern = concern,
            .diagnostics = &d,
        }) catch |err| return report(err, &d, "findOneAndUpdate");
        const doc = raised orelse return error.TestNoDocument;
        defer doc.deinit();
        const n = (try doc.raw().get("n")) orelse return error.TestNoField;
        try testing.expectEqual(@as(i64, 3), try n.asI64());
    }
    // Read back: every write is there.
    try testing.expectEqual(@as(u64, concerns.len), try orders.countDocuments(io, op, .{ .n = 3 }, .{ .allocator = gpa }));

    // A delete takes it too.
    var deleted = orders.deleteMany(io, op, .{}, .{ .allocator = gpa, .write_concern = .{ .w = .majority, .journal = true }, .diagnostics = &d }) catch |err|
        return report(err, &d, "deleteMany");
    defer deleted.deinit(gpa);
    try testing.expectEqual(@as(u64, concerns.len), deleted.deleted);
}

/// Prints the diagnostics of `err`, and returns it.
fn report(err: anyerror, d: *const mongo.Diagnostics, comptime what: []const u8) anyerror {
    std.debug.print(what ++ ": {t}: {s}\n", .{ err, d.message() });
    return err;
}
