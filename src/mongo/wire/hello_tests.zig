//! Tests of `wire.Hello`: the type of server by each row of the table of
//! SDAM that the client follows (design §6.1), the limits and
//! their defaults, and replies that break the types of their fields.

const std = @import("std");
const testing = std.testing;
const bson = @import("../bson.zig");
const Hello = @import("Hello.zig");
const errors = @import("../errors.zig");

test "a standalone mongod: no setName, no msg isdbgrid, no isreplicaset" {
    // What mongod 9.0 answers, its topologyVersion and localTime left out.
    const hello = try Hello.parse(bson.literal(.{
        .helloOk = true,
        .ismaster = true,
        .maxBsonObjectSize = 16777216,
        .maxMessageSizeBytes = 48000000,
        .maxWriteBatchSize = 100000,
        .logicalSessionTimeoutMinutes = 30,
        .connectionId = 12,
        .minWireVersion = 0,
        .maxWireVersion = 29,
        .readOnly = false,
        .ok = 1.0,
    }), null);
    try testing.expectEqual(Hello.ServerType.standalone, hello.server_type);
    try testing.expectEqual(@as(i32, 29), hello.max_wire_version);
    try testing.expectEqual(@as(i32, 0), hello.min_wire_version);
    try testing.expectEqual(@as(u32, 16 * 1024 * 1024), hello.max_bson_object_size);
    try testing.expectEqual(@as(u32, 48_000_000), hello.max_message_size_bytes);
    try testing.expectEqual(@as(u32, 100_000), hello.max_write_batch_size);
    try testing.expectEqual(@as(?i64, 12), hello.connection_id);
    try testing.expectEqual(@as(?i64, 30), hello.logical_session_timeout_minutes);
    try testing.expectEqual(@as(?[]const u8, null), hello.set_name);
}

test "each row of the table of server types" {
    const rows = [_]struct { Hello.ServerType, bson.RawDocument }{
        .{ .rs_primary, bson.literal(.{ .ismaster = true, .setName = "rs0", .ok = 1 }) },
        .{ .rs_primary, bson.literal(.{ .isWritablePrimary = true, .setName = "rs0", .ok = 1 }) },
        .{ .rs_secondary, bson.literal(.{ .ismaster = false, .secondary = true, .setName = "rs0", .ok = 1 }) },
        .{ .rs_arbiter, bson.literal(.{ .ismaster = false, .arbiterOnly = true, .setName = "rs0", .ok = 1 }) },
        // A hidden member is a secondary, but RSOther by SDAM.
        .{ .rs_other, bson.literal(.{ .ismaster = false, .secondary = true, .hidden = true, .setName = "rs0", .ok = 1 }) },
        .{ .rs_other, bson.literal(.{ .ismaster = false, .setName = "rs0", .ok = 1 }) },
        .{ .rs_ghost, bson.literal(.{ .ismaster = false, .isreplicaset = true, .ok = 1 }) },
        .{ .mongos, bson.literal(.{ .ismaster = true, .msg = "isdbgrid", .ok = 1 }) },
        .{ .standalone, bson.literal(.{ .ismaster = true, .ok = 1 }) },
    };
    for (rows) |row| {
        errdefer std.debug.print("{f}\n", .{row[1]});
        const hello = try Hello.parse(row[1], null);
        try testing.expectEqual(row[0], hello.server_type);
        if (row[0] != .standalone and row[0] != .mongos and row[0] != .rs_ghost) {
            try testing.expectEqualStrings("rs0", hello.set_name.?);
        }
    }
}

test "a wire version below 21 is what the server says: the driver refuses it" {
    const hello = try Hello.parse(bson.literal(.{ .ismaster = true, .maxWireVersion = 20, .ok = 1 }), null);
    try testing.expectEqual(@as(i32, 20), hello.max_wire_version);
}

test "missing limits take their defaults, and Hello{} is a standalone of MongoDB 7.0" {
    const hello = try Hello.parse(bson.literal(.{ .ismaster = true, .ok = 1 }), null);
    const default: Hello = .{};
    inline for (.{ "max_bson_object_size", "max_message_size_bytes", "max_write_batch_size" }) |name| {
        try testing.expectEqual(@field(default, name), @field(hello, name));
    }
    try testing.expectEqual(@as(u32, 16 * 1024 * 1024), default.max_bson_object_size);
    try testing.expectEqual(@as(u32, 48_000_000), default.max_message_size_bytes);
    try testing.expectEqual(@as(u32, 100_000), default.max_write_batch_size);
    try testing.expectEqual(Hello.ServerType.standalone, default.server_type);
    try testing.expectEqual(@as(i32, 21), default.max_wire_version);
    try testing.expectEqual(@as(?i64, null), default.logical_session_timeout_minutes);
    // Without maxWireVersion the server reports wire version 0.
    try testing.expectEqual(@as(i32, 0), hello.max_wire_version);
}

test "a field of another type, or a limit out of range, is a protocol violation that names the field" {
    const cases = [_]struct { []const u8, bson.RawDocument }{
        .{ "maxWriteBatchSize", bson.literal(.{ .maxWriteBatchSize = "many", .ok = 1 }) },
        .{ "maxBsonObjectSize", bson.literal(.{ .maxBsonObjectSize = 0, .ok = 1 }) },
        .{ "maxMessageSizeBytes", bson.literal(.{ .maxMessageSizeBytes = -1, .ok = 1 }) },
        .{ "maxMessageSizeBytes", bson.literal(.{ .maxMessageSizeBytes = 5_000_000_000, .ok = 1 }) },
        .{ "maxWireVersion", bson.literal(.{ .maxWireVersion = 3_000_000_000, .ok = 1 }) },
        .{ "maxWireVersion", bson.literal(.{ .maxWireVersion = 21.5, .ok = 1 }) },
        .{ "connectionId", bson.literal(.{ .connectionId = "12", .ok = 1 }) },
        .{ "setName", bson.literal(.{ .setName = 1, .ok = 1 }) },
        .{ "isreplicaset", bson.literal(.{ .isreplicaset = 1, .ok = 1 }) },
        .{ "msg", bson.literal(.{ .msg = true, .ok = 1 }) },
    };
    for (cases) |case| {
        errdefer std.debug.print("{f}\n", .{case[1]});
        var d: errors.Diagnostics = .{};
        try testing.expectError(error.ProtocolViolation, Hello.parse(case[1], &d));
        try testing.expect(std.mem.find(u8, d.message(), case[0]) != null);
    }
}
