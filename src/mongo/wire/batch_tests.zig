//! Tests of `wire.batch`: the items of a write in batches, by count and by
//! the size of their messages, and the replies of the batches merged into
//! one result.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const batch = @import("batch.zig");
const opmsg = @import("opmsg.zig");
const Hello = @import("Hello.zig");
const errors = @import("../contract/errors.zig");
const results = @import("../contract/results.zig");

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

/// The batches of 10 items at a limit of 3: offsets 0, 3, 6 and 9.
fn tenAtThree(items: *[10]bson.RawDocument) !batch.Batches {
    items.* = @splat(bson.literal(.{ .n = 1 }));
    return batch.Batches.init(insert(items), .{ .max_write_batch_size = 3 }, null);
}

test "10 items at a limit of 3: n and nModified are summed, writeErrors and upserted shifted by their batch" {
    var items: [10]bson.RawDocument = undefined;
    var batches = try tenAtThree(&items);
    const replies = [_]bson.RawDocument{
        bson.literal(.{ .n = 3, .nModified = 1, .upserted = .{.{ .index = 2, ._id = 70 }}, .ok = 1.0 }),
        bson.literal(.{ .n = 2, .nModified = 2, .writeErrors = .{.{ .index = 1, .code = 11000, .errmsg = "E11000 duplicate key error" }}, .ok = 1.0 }),
        bson.literal(.{ .n = 3, .nModified = 0, .upserted = .{ .{ .index = 0, ._id = "six" }, .{ .index = 2, ._id = 8 } }, .ok = 1.0 }),
        bson.literal(.{ .n = 0, .writeErrors = .{.{ .index = 0, .code = 121, .errmsg = "Document failed validation", .errInfo = .{ .failingDocumentId = 9 } }}, .ok = 1.0 }),
    };
    var merge: batch.Merge = .{};
    defer merge.deinit(testing.allocator);
    for (replies) |reply| {
        try testing.expectEqual(batch.Merge.Next.more, try merge.add(testing.allocator, batches.next().?, reply, false, null));
    }
    try testing.expect(batches.next() == null);
    var result = try merge.result(testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 8), result.n);
    try testing.expectEqual(@as(u64, 3), result.modified);
    try testing.expectEqual(@as(usize, 10), result.answered);
    try testing.expectEqual(@as(usize, 3), result.upserted.len);
    try testing.expectEqual(@as(usize, 2), result.upserted[0].index);
    try testing.expectEqual(@as(i32, 70), result.upserted[0].id.int32);
    try testing.expectEqual(@as(usize, 6), result.upserted[1].index);
    try testing.expectEqualStrings("six", result.upserted[1].id.string);
    try testing.expectEqual(@as(usize, 8), result.upserted[2].index);
    try testing.expectEqual(@as(usize, 2), result.write_errors.len);
    try testing.expectEqual(@as(usize, 4), result.write_errors[0].index);
    try testing.expectEqual(@as(i32, 11000), result.write_errors[0].code);
    try testing.expectEqualStrings("E11000 duplicate key error", result.write_errors[0].message);
    try testing.expect(result.write_errors[0].details == null);
    try testing.expectEqual(@as(usize, 9), result.write_errors[1].index);
    try testing.expectEqual(@as(i32, 121), result.write_errors[1].code);
    try testing.expectEqualSlices(u8, bson.literal(.{ .failingDocumentId = 9 }).bytes, result.write_errors[1].details.?.bytes);
    try testing.expectEqual(@as(usize, 0), result.write_concern_errors.len);

    // The merge handed its result over; another result is empty.
    var again = try merge.result(testing.allocator);
    defer again.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), again.n);
    try testing.expectEqual(@as(usize, 0), again.write_errors.len);
}

test "an ordered write stops after the batch whose items the server refused; an unordered one goes on" {
    var items: [10]bson.RawDocument = undefined;
    var batches = try tenAtThree(&items);
    const refused = bson.literal(.{ .n = 1, .writeErrors = .{.{ .index = 1, .code = 11000, .errmsg = "E11000 duplicate key error" }}, .ok = 1.0 });
    var merge: batch.Merge = .{};
    defer merge.deinit(testing.allocator);
    try testing.expectEqual(batch.Merge.Next.more, try merge.add(testing.allocator, batches.next().?, bson.literal(.{ .n = 3, .ok = 1.0 }), true, null));
    const second = batches.next().?;
    try testing.expectEqual(batch.Merge.Next.done, try merge.add(testing.allocator, second, refused, true, null));
    var result = try merge.result(testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 4), result.n);
    try testing.expectEqual(@as(usize, 6), result.answered);
    try testing.expectEqual(@as(usize, 4), result.write_errors[0].index);

    var unordered: batch.Merge = .{};
    defer unordered.deinit(testing.allocator);
    try testing.expectEqual(batch.Merge.Next.more, try unordered.add(testing.allocator, second, refused, false, null));
}

test "a writeConcernError of each batch is kept, and the write goes on" {
    var items: [10]bson.RawDocument = undefined;
    var batches = try tenAtThree(&items);
    const concern = bson.literal(.{ .n = 3, .writeConcernError = .{ .code = 64, .codeName = "WriteConcernTimeout", .errmsg = "waiting for replication timed out", .errInfo = .{ .wtimeout = true } }, .ok = 1.0 });
    var merge: batch.Merge = .{};
    defer merge.deinit(testing.allocator);
    try testing.expectEqual(batch.Merge.Next.more, try merge.add(testing.allocator, batches.next().?, concern, true, null));
    try testing.expectEqual(batch.Merge.Next.more, try merge.add(testing.allocator, batches.next().?, bson.literal(.{ .n = 3, .ok = 1.0 }), true, null));
    try testing.expectEqual(batch.Merge.Next.more, try merge.add(testing.allocator, batches.next().?, concern, true, null));
    var result = try merge.result(testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 9), result.n);
    try testing.expectEqual(@as(usize, 2), result.write_concern_errors.len);
    for (result.write_concern_errors) |e| {
        try testing.expectEqual(@as(i32, 64), e.code);
        try testing.expectEqualStrings("waiting for replication timed out", e.message);
        try testing.expectEqualSlices(u8, bson.literal(.{ .wtimeout = true }).bytes, e.details.?.bytes);
    }
}

test "MaxTimeMSExpired (50) on an item or on the write concern ends the write with a timeout, its batch merged" {
    var items: [10]bson.RawDocument = undefined;
    const expired = [_]bson.RawDocument{
        bson.literal(.{ .n = 1, .writeErrors = .{.{ .index = 1, .code = 50, .errmsg = "operation exceeded time limit" }}, .ok = 1.0 }),
        bson.literal(.{ .n = 3, .writeConcernError = .{ .code = 50, .codeName = "MaxTimeMSExpired", .errmsg = "operation exceeded time limit" }, .ok = 1.0 }),
    };
    for (expired) |reply| {
        var batches = try tenAtThree(&items);
        var merge: batch.Merge = .{};
        defer merge.deinit(testing.allocator);
        var d: errors.Diagnostics = .{};
        try testing.expectEqual(batch.Merge.Next.timeout, try merge.add(testing.allocator, batches.next().?, reply, false, &d));
        try testing.expectEqual(@as(i32, 50), d.server.?.code);
        try testing.expectEqualStrings("MaxTimeMSExpired", d.server.?.code_name.slice());
        try testing.expectEqualStrings("operation exceeded time limit", d.message());
        try testing.expectEqual(@as(usize, 3), merge.answered);
    }
}

test "a write that fails at its first batch fails with the error itself, its merge in partial" {
    var items: [10]bson.RawDocument = undefined;
    var batches = try tenAtThree(&items);
    const first = batches.next().?;
    var merge: batch.Merge = .{};
    defer merge.deinit(testing.allocator);
    var partial: results.WriteResult = .{ .n = 99 };
    var d: errors.Diagnostics = .{};
    try testing.expectEqual(error.ConnectionLost, merge.fail(testing.allocator, error.ConnectionLost, first, .{ .allocator = testing.allocator, .diagnostics = &d, .partial = &partial }));
    defer partial.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), partial.n);
    try testing.expectEqual(@as(usize, 0), partial.answered);
    try testing.expectEqual(@as(?usize, 0), d.batch_offset);
    try testing.expect(d.reason == null);
}

test "a write that fails at batch k > 1 is IncompleteWrite, with the reason, the batch's offset and the batches before it" {
    var items: [10]bson.RawDocument = undefined;
    for ([_]bool{ true, false }) |with_partial| {
        var batches = try tenAtThree(&items);
        var merge: batch.Merge = .{};
        defer merge.deinit(testing.allocator);
        _ = try merge.add(testing.allocator, batches.next().?, bson.literal(.{ .n = 3, .ok = 1.0 }), true, null);
        _ = try merge.add(testing.allocator, batches.next().?, bson.literal(.{ .n = 2, .writeErrors = .{.{ .index = 0, .code = 11000, .errmsg = "dup" }}, .ok = 1.0 }), false, null);
        const third = batches.next().?;
        var partial: results.WriteResult = .{};
        defer partial.deinit(testing.allocator);
        var d: errors.Diagnostics = .{};
        try testing.expectEqual(error.IncompleteWrite, merge.fail(testing.allocator, error.ConnectionLost, third, .{
            .allocator = testing.allocator,
            .diagnostics = &d,
            .partial = if (with_partial) &partial else null,
        }));
        try testing.expectEqual(@as(?errors.Error, error.ConnectionLost), d.reason);
        try testing.expectEqual(@as(?usize, 6), d.batch_offset);
        if (with_partial) {
            try testing.expectEqual(@as(u64, 5), partial.n);
            try testing.expectEqual(@as(usize, 6), partial.answered);
            try testing.expectEqual(@as(usize, 3), partial.write_errors[0].index);
        }
    }
}

test "a reply that names an item outside its batch, or counts below zero, is a protocol violation, and the merge stays as it was" {
    var items: [10]bson.RawDocument = undefined;
    var batches = try tenAtThree(&items);
    var merge: batch.Merge = .{};
    defer merge.deinit(testing.allocator);
    const first = batches.next().?;
    _ = try merge.add(testing.allocator, first, bson.literal(.{ .n = 2, .upserted = .{.{ .index = 0, ._id = "kept" }}, .writeErrors = .{.{ .index = 2, .code = 11000, .errmsg = "dup" }}, .ok = 1.0 }), false, null);
    const second = batches.next().?;
    const broken = [_]bson.RawDocument{
        bson.literal(.{ .n = 1, .upserted = .{.{ .index = 0, ._id = "dropped" }}, .writeErrors = .{.{ .index = 3, .code = 11000, .errmsg = "dup" }}, .ok = 1.0 }),
        bson.literal(.{ .n = -1, .ok = 1.0 }),
        bson.literal(.{ .n = 1, .writeErrors = "none", .ok = 1.0 }),
        bson.literal(.{ .n = 1, .upserted = .{.{ .index = 1 }}, .ok = 1.0 }),
        bson.literal(.{ .n = 1, .writeErrors = .{.{ .index = 0, .errmsg = "no code" }}, .ok = 1.0 }),
        bson.literal(.{ .n = 1, .writeConcernError = .{ .errmsg = "no code" }, .ok = 1.0 }),
        bson.literal(.{ .n = 2.5, .ok = 1.0 }),
    };
    for (broken) |reply| {
        var d: errors.Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, merge.add(testing.allocator, second, reply, false, &d));
        try testing.expect(d.message().len > 0);
    }
    var result = try merge.result(testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), result.n);
    try testing.expectEqual(@as(usize, 3), result.answered);
    try testing.expectEqual(@as(usize, 1), result.upserted.len);
    try testing.expectEqualStrings("kept", result.upserted[0].id.string);
    try testing.expectEqual(@as(usize, 1), result.write_errors.len);
}
