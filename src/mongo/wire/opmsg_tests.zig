//! Tests of `wire.opmsg`: requests and replies in both directions, and
//! every way a message can break OP_MSG.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const opmsg = @import("opmsg.zig");
const errors = @import("../contract/errors.zig");
const vectors = @import("../bson/vectors.zig");

const Crc = std.hash.crc.@"CRC-32/ISCSI";

const Raw = struct {
    request_id: i32 = 9,
    response_to: i32 = 7,
    op_code: i32 = opmsg.op_code,
    flags: u32 = 0,
    /// messageLength; by default the true one.
    length: ?i32 = null,
    /// A CRC-32C at the end, made by `checksum` or as given.
    checksum: enum { none, right, wrong } = .none,
};

/// A message of `sections` with the header and flagBits of `raw`.
fn frame(raw: Raw, sections: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const extra: usize = if (raw.checksum == .none) 0 else 4;
    const flags = raw.flags | @as(u32, if (raw.checksum == .none) 0 else opmsg.flag_checksum_present);
    try w.writeInt(i32, raw.length orelse @intCast(opmsg.header_len + 4 + sections.len + extra), .little);
    try w.writeInt(i32, raw.request_id, .little);
    try w.writeInt(i32, raw.response_to, .little);
    try w.writeInt(i32, raw.op_code, .little);
    try w.writeInt(u32, flags, .little);
    try w.writeAll(sections);
    switch (raw.checksum) {
        .none => {},
        .right => try w.writeInt(u32, Crc.hash(out.written()), .little),
        .wrong => try w.writeInt(u32, Crc.hash(out.written()) +% 1, .little),
    }
    return out.toOwnedSlice();
}

fn kind0(comptime doc: []const u8) []const u8 {
    return comptime "\x00" ++ doc;
}

fn kind1(comptime identifier: []const u8, comptime docs: []const u8) []const u8 {
    return comptime "\x01" ++ std.mem.toBytes(std.mem.nativeToLittle(i32, 4 + identifier.len + 1 + docs.len)) ++ identifier ++ "\x00" ++ docs;
}

const ok = bson.literal(.{ .ok = 1.0 }).bytes;
const ann = bson.literal(.{ .name = "Ann" }).bytes;
const bob = bson.literal(.{ .name = "Bob" }).bytes;

test "a request goes out as the caller's body, the driver's fields and the items" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const items = [_]bson.RawDocument{ .{ .bytes = ann }, .{ .bytes = bob } };
    const request: opmsg.Request = .{
        .request_id = 42,
        .body = bson.literal(.{ .insert = "users", .comment = "import" }),
        .database = "app",
        .ordered = false,
        .max_time_ms = 1500,
        .sequence = .{ .identifier = "documents", .documents = &items },
    };
    try opmsg.writeRequest(&out.writer, request);
    const bytes = out.written();
    try testing.expectEqual(request.length(), bytes.len);

    // The body with the fields, as a builder writes it.
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    try b.putString("insert", "users");
    try b.putString("comment", "import");
    try b.putBoolean("ordered", false);
    try b.putInt64("maxTimeMS", 1500);
    try b.putString("$db", "app");
    const body = try b.finish();
    defer body.deinit();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(bytes.len))));
    try expected.appendSlice(testing.allocator, &.{ 42, 0, 0, 0, 0, 0, 0, 0, 0xdd, 0x07, 0, 0, 0, 0, 0, 0, 0 });
    try expected.appendSlice(testing.allocator, body.bytes);
    try expected.appendSlice(testing.allocator, kind1("documents", ann ++ bob));
    try testing.expectEqualSlices(u8, expected.items, bytes);

    // The server side reads it back.
    var r: std.Io.Reader = .fixed(bytes);
    const incoming = try opmsg.readRequest(&r, testing.allocator, opmsg.default_max_message_size, null);
    defer incoming.deinit();
    try testing.expectEqual(@as(i32, 42), incoming.header.request_id);
    try testing.expectEqual(@as(u32, 0), incoming.flags);
    try testing.expectEqualSlices(u8, body.bytes, incoming.body.bytes);
    var sequences = incoming.sequences();
    const sequence = sequences.next().?;
    try testing.expectEqualStrings("documents", sequence.identifier);
    var docs = sequence.documents();
    try testing.expectEqualSlices(u8, ann, docs.next().?.bytes);
    try testing.expectEqualSlices(u8, bob, docs.next().?.bytes);
    try testing.expect(docs.next() == null);
    try testing.expect(sequences.next() == null);
}

test "a command without items has a section of kind 0 only, with $db last" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const request: opmsg.Request = .{ .request_id = 1, .body = bson.literal(.{ .ping = 1 }), .database = "admin" };
    try opmsg.writeRequest(&out.writer, request);
    const expected = comptime kind0(bson.literal(.{ .ping = 1, .@"$db" = "admin" }).bytes);
    try testing.expectEqualSlices(u8, expected, out.written()[20..]);
    try testing.expectEqual(@as(usize, 20 + expected.len), request.length());
}

test "a reply that the server side writes is what the driver side reads" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try opmsg.writeReply(&out.writer, 5, 42, .{ .bytes = vectors.reply });
    var r: std.Io.Reader = .fixed(out.written());
    const reply = try opmsg.readReply(&r, testing.allocator, .{ .request_id = 42 }, null);
    defer reply.deinit();
    try testing.expectEqualSlices(u8, vectors.reply, reply.bytes);
}

test "a reply with a checksum or an optional flag the client does not know is read" {
    for ([_]Raw{
        .{ .response_to = 7, .checksum = .right },
        .{ .response_to = 7, .flags = 1 << 17 },
    }) |raw| {
        const bytes = try frame(raw, kind0(ok));
        defer testing.allocator.free(bytes);
        var r: std.Io.Reader = .fixed(bytes);
        const reply = try opmsg.readReply(&r, testing.allocator, .{ .request_id = 7 }, null);
        defer reply.deinit();
        try testing.expectEqualSlices(u8, ok, reply.bytes);
    }
}

test "a reply that breaks OP_MSG is a protocol violation, and says how" {
    const cases = comptime [_]struct { []const u8, Raw, []const u8 }{
        .{ "answers request 8", .{ .response_to = 8 }, kind0(ok) },
        .{ "opCode 1", .{ .op_code = 1 }, kind0(ok) },
        .{ "25 bytes", .{ .length = 25 }, kind0(ok) },
        .{ "1001 bytes", .{ .length = 1001 }, kind0(ok) },
        .{ "flag bits", .{ .flags = 1 << 2 }, kind0(ok) },
        .{ "moreToCome", .{ .flags = opmsg.flag_more_to_come }, kind0(ok) },
        .{ "kind 1", .{}, kind1("documents", ann) ++ kind0(ok) },
        .{ "more than one section", .{}, kind0(ok) ++ kind1("documents", ann) },
        .{ "kind 2", .{}, "\x02" ++ ok },
        .{ "more than one section", .{}, kind0(ok) ++ kind0(ok) },
        .{ "bytes are left", .{}, "\x00\x40\x00\x00\x00\x00" },
        // A document of one element of the unknown type 0x20.
        .{ "not valid BSON", .{}, kind0("\x08\x00\x00\x00\x20a\x00\x00") },
        .{ "checksum", .{ .checksum = .wrong }, kind0(ok) },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case[0]});
        const bytes = try frame(case[1], case[2]);
        defer testing.allocator.free(bytes);
        var r: std.Io.Reader = .fixed(bytes);
        var d: errors.Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, opmsg.readReply(&r, testing.allocator, .{ .request_id = 7, .max_message_size = 1000 }, &d));
        try testing.expect(std.mem.find(u8, d.message(), case[0]) != null);
        try testing.expectEqual(errors.Diagnostics.Phase.receive, d.phase.?);
    }
}

test "a reply cut short ends the stream" {
    const bytes = try frame(.{}, kind0(ok));
    defer testing.allocator.free(bytes);
    for ([_]usize{ 0, 10, 16, 20, 21, bytes.len - 1 }) |len| {
        var r: std.Io.Reader = .fixed(bytes[0..len]);
        try testing.expectError(error.EndOfStream, opmsg.readReply(&r, testing.allocator, .{ .request_id = 7 }, null));
    }
}

test "a reply holds a stored document of 100 levels in reply.cursor.firstBatch, and no deeper one" {
    for ([_]struct { usize, bool }{ .{ 100, true }, .{ 101, false } }) |case| {
        const stored = try vectors.nested(testing.allocator, case[0]);
        defer testing.allocator.free(stored);
        // {cursor: {firstBatch: [stored]}}, written by hand: the builder
        // stops at 100 levels.
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(testing.allocator);
        const batch_len = 4 + 1 + 2 + stored.len + 1;
        const cursor_len = 4 + 1 + "firstBatch".len + 1 + batch_len + 1;
        const reply_len = 4 + 1 + "cursor".len + 1 + cursor_len + 1;
        try b.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(reply_len))));
        try b.appendSlice(testing.allocator, "\x03cursor\x00");
        try b.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(cursor_len))));
        try b.appendSlice(testing.allocator, "\x04firstBatch\x00");
        try b.appendSlice(testing.allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(batch_len))));
        try b.appendSlice(testing.allocator, "\x030\x00");
        try b.appendSlice(testing.allocator, stored);
        try b.appendSlice(testing.allocator, "\x00\x00\x00");
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try opmsg.writeReply(&out.writer, 1, 7, .{ .bytes = b.items });
        var r: std.Io.Reader = .fixed(out.written());
        if (case[1]) {
            const reply = try opmsg.readReply(&r, testing.allocator, .{ .request_id = 7 }, null);
            reply.deinit();
        } else {
            try testing.expectError(error.ProtocolViolation, opmsg.readReply(&r, testing.allocator, .{ .request_id = 7 }, null));
        }
    }
}

test "a request that breaks OP_MSG is a protocol violation for the server side" {
    const cases = comptime [_]struct { []const u8, Raw, []const u8 }{
        .{ "opCode 2004", .{ .op_code = 2004 }, kind0(ok) },
        .{ "no section of kind 0", .{}, kind1("documents", ann) },
        .{ "two sections of kind 0", .{}, kind0(ok) ++ kind0(ok) },
        .{ "kind 3", .{}, kind0(ok) ++ "\x03" ++ ok },
        .{ "identifier", .{}, kind0(ok) ++ "\x01\x09\x00\x00\x00docsX" },
        .{ "document 1 of section 'documents'", .{}, kind0(ok) ++ kind1("documents", ann ++ "\x05\x00\x00\x00\x01") },
        .{ "cut short", .{}, kind0(ok) ++ kind1("documents", ann ++ "\x10\x00\x00") },
        .{ "flag bits", .{ .flags = 1 << 3 }, kind0(ok) },
        .{ "checksum", .{ .checksum = .wrong }, kind0(ok) },
        .{ "26 to 1000", .{ .length = 2000 }, kind0(ok) },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case[0]});
        const bytes = try frame(case[1], case[2]);
        defer testing.allocator.free(bytes);
        var r: std.Io.Reader = .fixed(bytes);
        var d: errors.Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, opmsg.readRequest(&r, testing.allocator, 1000, &d));
        try testing.expect(std.mem.find(u8, d.message(), case[0]) != null);
    }
    // moreToCome and a right checksum are fine in a request.
    const bytes = try frame(.{ .flags = opmsg.flag_more_to_come, .checksum = .right }, comptime kind1("documents", ann ++ bob) ++ kind0(ok));
    defer testing.allocator.free(bytes);
    var r: std.Io.Reader = .fixed(bytes);
    const incoming = try opmsg.readRequest(&r, testing.allocator, 1000, null);
    defer incoming.deinit();
    try testing.expect(incoming.flags & opmsg.flag_more_to_come != 0);
    try testing.expectEqualSlices(u8, ok, incoming.body.bytes);
}

test "an identifier with NUL or a body that is not a document is refused before writing" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const items = [_]bson.RawDocument{.{ .bytes = ann }};
    try testing.expectError(error.InvalidArgument, opmsg.writeRequest(&out.writer, .{
        .request_id = 1,
        .body = bson.literal(.{ .insert = "users" }),
        .database = "app",
        .sequence = .{ .identifier = "docu\x00ments", .documents = &items },
    }));
    try testing.expectError(error.InvalidArgument, opmsg.writeRequest(&out.writer, .{ .request_id = 1, .body = .{ .bytes = "" }, .database = "app" }));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}
