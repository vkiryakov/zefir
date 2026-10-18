//! Tests of the types of the client's calls: their defaults, and what a
//! `WriteResult` owns.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const bson = @import("bson.zig");
const requests = @import("requests.zig");
const results = @import("results.zig");

test "an operation context of a core context adds no tracing" {
    const ctx = core.Context.root.withDeadline(.after(.zero, .fromSeconds(1)));
    const op: requests.OperationContext = .of(ctx);
    try testing.expectEqual(ctx.deadline.?.expires, op.ctx.deadline.?.expires);
    try testing.expectEqual(@as(?[]const u8, null), op.tracing.operation);
}

test "options default to nothing to fill in, and a write to ordered" {
    const command: requests.CommandOptions = .{ .allocator = testing.allocator };
    try testing.expect(command.diagnostics == null and command.failure_reply == null);
    const write: requests.WriteOptions = .{ .allocator = testing.allocator };
    try testing.expect(write.diagnostics == null and write.failure_reply == null and write.partial == null);
    const cursor: requests.CursorOptions = .{};
    try testing.expect(cursor.batch_size == null and cursor.comment == null and cursor.diagnostics == null and cursor.failure_reply == null);
    const request: requests.WriteRequest = .{ .database = "app", .kind = .insert, .body = bson.literal(.{ .insert = "users" }), .items = &.{} };
    try testing.expect(request.ordered);
}

test "a kind of write names its command and the section of its items" {
    const table = [_]struct { requests.WriteKind, []const u8, []const u8 }{
        .{ .insert, "insert", "documents" },
        .{ .update, "update", "updates" },
        .{ .delete, "delete", "deletes" },
    };
    for (table) |row| {
        try testing.expectEqualStrings(row[1], row[0].command());
        try testing.expectEqualStrings(row[2], row[0].items());
    }
}

test "an empty write result is all zero" {
    const result: results.WriteResult = .{};
    try testing.expectEqual(@as(u64, 0), result.n + result.modified);
    try testing.expectEqual(@as(usize, 0), result.upserted.len + result.write_errors.len + result.write_concern_errors.len + result.answered);
    // Freeing an empty result frees nothing.
    var empty = result;
    empty.deinit(testing.allocator);
}

test "deinit frees everything a write result holds" {
    const gpa = testing.allocator;
    const id_doc = bson.literal(.{ .tenant = "acme", .n = 7 });
    const upserted = try gpa.alloc(results.Upserted, 3);
    upserted[0] = .{ .index = 0, .id = try results.dupeValue(gpa, .{ .string = "ann" }) };
    upserted[1] = .{ .index = 4, .id = try results.dupeValue(gpa, .{ .document = id_doc }) };
    upserted[2] = .{ .index = 5, .id = try results.dupeValue(gpa, .{ .regex = .{ .pattern = "^a", .options = "i" } }) };
    const write_errors = try gpa.alloc(results.WriteError, 1);
    write_errors[0] = .{ .index = 2, .code = 11000, .message = try gpa.dupe(u8, "E11000 duplicate key"), .details = .{ .bytes = try gpa.dupe(u8, id_doc.bytes) } };
    const concern = try gpa.alloc(results.WriteConcernError, 1);
    concern[0] = .{ .code = 64, .message = try gpa.dupe(u8, "waiting for replication timed out") };
    var result: results.WriteResult = .{ .n = 3, .upserted = upserted, .write_errors = write_errors, .write_concern_errors = concern, .answered = 6 };
    try testing.expectEqualStrings("ann", result.upserted[0].id.string);
    try testing.expectEqualSlices(u8, id_doc.bytes, result.upserted[1].id.document.bytes);
    // testing.allocator reports whatever deinit leaves.
    result.deinit(gpa);
}

test "a copied value no longer points into the document it came from" {
    const literal = comptime bson.literal(.{ .name = "Ann" });
    var bytes = literal.bytes[0..literal.bytes.len].*;
    const original = (try (try bson.RawDocument.init(&bytes)).get("name")).?;
    const copy = try results.dupeValue(testing.allocator, original);
    defer results.freeValue(testing.allocator, copy);
    @memset(&bytes, 0);
    try testing.expectEqualStrings("Ann", copy.string);
}
