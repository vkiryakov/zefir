//! Tests of the special BSON types: ObjectId and its generator, DateTime
//! and the text of Decimal128.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const vectors = @import("vectors.zig");
const ObjectId = bson.ObjectId;

test "an ObjectId prints as 24 hex digits and parses back" {
    const id: ObjectId = .{ .bytes = vectors.object_id };
    try testing.expectFmt("56e1fc72e0c917e9c4714161", "{f}", .{id});
    try testing.expectEqual(id, try ObjectId.parseHex("56e1fc72e0c917e9c4714161"));
    try testing.expectEqual(id, try ObjectId.parseHex("56E1FC72E0C917E9C4714161"));
}

test "parseHex refuses anything but 24 hex digits" {
    for ([_][]const u8{
        "",
        "56e1fc72e0c917e9c471416",
        "56e1fc72e0c917e9c47141610",
        "56e1fc72e0c917e9c471416g",
        "56e1fc72-0c917e9c4714161",
        " 56e1fc72e0c917e9c471416",
        "56e1fc72e0c917e9c4714161\x00",
    }) |text| {
        errdefer std.debug.print("text: \"{s}\"\n", .{text});
        try testing.expectError(error.InvalidObjectId, ObjectId.parseHex(text));
    }
}

test "the timestamp of an ObjectId is the seconds in its first 4 bytes" {
    const id: ObjectId = .{ .bytes = vectors.object_id };
    try testing.expectEqual(1457650802, id.timestamp());
}

test "a generated ObjectId holds the time, the generator's random bytes and a counter" {
    const io = testing.io;
    var ids: ObjectId.Generator = .init(io);
    const before = std.Io.Clock.real.now(io).toSeconds();
    const first = ids.next(io);
    const second = ids.next(io);
    const after = std.Io.Clock.real.now(io).toSeconds();
    try testing.expect(before <= first.timestamp() and second.timestamp() <= after);
    try testing.expectEqualSlices(u8, &ids.random, first.bytes[4..9]);
    try testing.expectEqualSlices(u8, &ids.random, second.bytes[4..9]);
    try testing.expectEqual(counterOf(first) +% 1, counterOf(second));
}

test "the counter goes from 0xFFFFFF to 0, also past the end of its u32" {
    const io = testing.io;
    var ids: ObjectId.Generator = .init(io);
    ids.counter = .init(0xFFFFFF);
    try testing.expectEqual(0xFFFFFF, counterOf(ids.next(io)));
    try testing.expectEqual(0, counterOf(ids.next(io)));
    ids.counter = .init(std.math.maxInt(u32));
    try testing.expectEqual(0xFFFFFF, counterOf(ids.next(io)));
    try testing.expectEqual(0, counterOf(ids.next(io)));
    try testing.expectEqual(1, counterOf(ids.next(io)));
}

test "two generators draw different random bytes" {
    const io = testing.io;
    const a: ObjectId.Generator = .init(io);
    const b: ObjectId.Generator = .init(io);
    try testing.expect(!std.mem.eql(u8, &a.random, &b.random));
}

test "64 tasks that share a generator get different ids" {
    const io = testing.io;
    var ids: ObjectId.Generator = .init(io);
    const per_task = 64;
    var made: [64][per_task]ObjectId = undefined;
    var group: std.Io.Group = .init;
    for (&made) |*batch| group.async(io, makeIds, .{ &ids, io, batch });
    try group.await(io);

    var all: [64 * per_task]ObjectId = undefined;
    for (made, 0..) |batch, i| @memcpy(all[i * per_task ..][0..per_task], &batch);
    std.mem.sort(ObjectId, &all, {}, lessThan);
    for (all[0 .. all.len - 1], all[1..]) |a, b| {
        try testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
    }
}

test "DateTime.now reads the real-time clock in milliseconds" {
    const io = testing.io;
    const before = std.Io.Clock.real.now(io).toMilliseconds();
    const now = bson.DateTime.now(io);
    const after = std.Io.Clock.real.now(io).toMilliseconds();
    try testing.expect(before <= now.milliseconds and now.milliseconds <= after);
}

test "a Decimal128 prints as the spec's scientific string" {
    for ([_][2][]const u8{
        .{ "00000000000000000000000000004030", "0" },
        .{ "000000000000000000000000000040b0", "-0" },
        .{ "01000000000000000000000000004030", "1" },
        .{ "0f000000000000000000000000003e30", "1.5" },
        .{ "0f000000000000000000000000003eb0", "-1.5" },
        .{ "7b000000000000000000000000003c30", "1.23" },
        .{ "d2040000000000000000000000003430", "0.001234" },
        .{ "01000000000000000000000000003430", "0.000001" },
        .{ "01000000000000000000000000003230", "1E-7" },
        .{ "d2040000000000000000000000002c30", "1.234E-7" },
        .{ "01000000000000000000000000004630", "1E+3" },
        .{ "00000000000000000000000000003a30", "0.000" },
        .{ "00000000000000000000000000004630", "0E+3" },
        .{ "874b6b5d54dc2b000000000000004030", "12345678901234567" },
        .{ "ffffffff638e8d37c087adbe09edff5f", "9.999999999999999999999999999999999E+6144" },
        .{ "0100000000000000000000000000fedf", "-1E+6111" },
        .{ "01000000000000000000000000000000", "1E-6176" },
        // A coefficient beyond 34 digits is not canonical: it reads as 0.
        .{ "00000000648e8d37c087adbe09ed4130", "0" },
        // So is every coefficient of the form whose top bits are 11.
        .{ "0500000000000000000000000000116c", "0E+2" },
        .{ "00000000000000000000000000000078", "Infinity" },
        .{ "000000000000000000000000000000f8", "-Infinity" },
        .{ "0000000000000000000000000000007c", "NaN" },
        .{ "0000000000000000000000000000007e", "NaN" },
        .{ "000000000000000000000000000000fc", "NaN" },
    }) |case| {
        var d: bson.Decimal128 = undefined;
        _ = try std.fmt.hexToBytes(&d.bytes, case[0]);
        try testing.expectFmt(case[1], "{f}", .{d});
    }
}

fn counterOf(id: ObjectId) u24 {
    return std.mem.readInt(u24, id.bytes[9..12], .big);
}

fn makeIds(ids: *ObjectId.Generator, io: std.Io, out: []ObjectId) void {
    for (out) |*id| id.* = ids.next(io);
}

fn lessThan(_: void, a: ObjectId, b: ObjectId) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}
