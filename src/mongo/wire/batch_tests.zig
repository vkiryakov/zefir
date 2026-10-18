//! Tests of `wire.batch`: the items of a write in batches, by count and by
//! the size of their messages.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const batch = @import("batch.zig");
const opmsg = @import("opmsg.zig");
const Hello = @import("Hello.zig");
const errors = @import("../contract/errors.zig");

fn insert(items: []const bson.RawDocument) opmsg.Request {
    return .{
        .request_id = 1,
        .body = bson.literal(.{ .insert = "users" }),
        .database = "app",
        .ordered = true,
        .max_time_ms = 1000,
        .sequence = .{ .identifier = "documents", .documents = items },
    };
}

test "10 items at a limit of 3 go as 3, 3, 3 and 1, each batch with the offset of its first item" {
    var items: [10]bson.RawDocument = @splat(bson.literal(.{ .n = 1 }));
    var batches = try batch.Batches.init(insert(&items), .{ .max_write_batch_size = 3 }, null);
    for ([_][2]usize{ .{ 0, 3 }, .{ 3, 3 }, .{ 6, 3 }, .{ 9, 1 } }) |expected| {
        const b = batches.next().?;
        try testing.expectEqual(expected[0], b.offset);
        try testing.expectEqual(expected[1], b.items.len);
        try testing.expectEqual(&items[expected[0]], &b.items[0]);
    }
    try testing.expect(batches.next() == null);
    try testing.expect(batches.next() == null);
}

test "a message of exactly maxMessageSizeBytes keeps the item; a byte more moves it to the next batch" {
    const a = bson.literal(.{ .name = "Ann" });
    const b = bson.literal(.{ .name = "Bob", .age = 30 });
    const items = [_]bson.RawDocument{ a, b, a };
    // The message of the first two items, as opmsg writes it.
    const two = insert(items[0..2]).length();
    var at_limit = try batch.Batches.init(insert(&items), .{ .max_message_size_bytes = @intCast(two) }, null);
    try testing.expectEqual(@as(usize, 2), at_limit.next().?.items.len);
    try testing.expectEqual(@as(usize, 1), at_limit.next().?.items.len);
    try testing.expect(at_limit.next() == null);

    var over = try batch.Batches.init(insert(&items), .{ .max_message_size_bytes = @intCast(two - 1) }, null);
    for ([_]usize{ 0, 1, 2 }) |offset| {
        const next = over.next().?;
        try testing.expectEqual(offset, next.offset);
        try testing.expectEqual(@as(usize, 1), next.items.len);
    }
    try testing.expect(over.next() == null);
}

test "an item that no message can hold is InvalidArgument before any batch, by its index" {
    const small = bson.literal(.{ .n = 1 });
    const large = bson.literal(.{ .name = "a name long enough to fill the message" });
    const items = [_]bson.RawDocument{ small, small, large };
    const limit = insert(&.{small}).length();
    var d: errors.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, batch.Batches.init(insert(&items), .{ .max_message_size_bytes = @intCast(limit) }, &d));
    try testing.expect(std.mem.find(u8, d.message(), "item 2") != null);
}

test "an item larger than maxBsonObjectSize but within a message goes out, for the server to refuse" {
    const items = [_]bson.RawDocument{bson.literal(.{ .name = "a document longer than the 64 bytes this server stores at most" })};
    const limits: batch.Limits = .of(.{ .max_bson_object_size = 64, .max_message_size_bytes = 1000, .max_write_batch_size = 7 });
    try testing.expectEqual(@as(u32, 7), limits.max_write_batch_size);
    try testing.expectEqual(@as(u32, 1000), limits.max_message_size_bytes);
    var batches = try batch.Batches.init(insert(&items), limits, null);
    try testing.expectEqual(@as(usize, 1), batches.next().?.items.len);
    try testing.expect(batches.next() == null);
}

test "a request without items has no batch" {
    var request = insert(&.{});
    var batches = try batch.Batches.init(request, .{}, null);
    try testing.expect(batches.next() == null);
    request.sequence = null;
    batches = try batch.Batches.init(request, .{}, null);
    try testing.expect(batches.next() == null);
}
