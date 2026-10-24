//! `wire.Hello`: what a server says about itself in its reply to hello
//! (legacy `isMaster` with `helloOk: true`, the first command of every
//! connection): its type by the rules of SDAM, its wire versions and the
//! limits that writes are split by. `wire.Hello{}` is a standalone mongod
//! of MongoDB 7.0 with the default limits, as the test server of
//! `mongo.testing` describes itself unless told otherwise.

const std = @import("std");
const bson = @import("mongo-bson");
const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const Hello = @This();

server_type: ServerType = .standalone,
/// The wire versions the server speaks: 21 is MongoDB 7.0, 25 is 8.0, 29
/// is 9.0.
min_wire_version: i32 = 0,
max_wire_version: i32 = 21,
/// The largest document the server stores.
max_bson_object_size: u32 = 16 * 1024 * 1024,
/// The longest message the server takes.
max_message_size_bytes: u32 = 48_000_000,
/// The most items one write command may carry.
max_write_batch_size: u32 = 100_000,
/// The server's id of the connection, for logs.
connection_id: ?i64 = null,
/// The name of the replica set, for a member of one; a slice into the
/// reply.
set_name: ?[]const u8 = null,
/// Present when the server takes sessions.
logical_session_timeout_minutes: ?i64 = null,

/// The type of a server, by SDAM's rules for a reply to hello.
pub const ServerType = enum {
    standalone,
    mongos,
    rs_primary,
    rs_secondary,
    rs_arbiter,
    /// A member that is none of the above, a hidden one among them.
    rs_other,
    /// A member of a replica set that is not initialized yet, or was
    /// removed.
    rs_ghost,
};

/// The hello of `reply`, a reply whose `ok` is 1. A field of another
/// type, or a limit below 1 or beyond u32, is `error.ProtocolViolation`
/// that names the field; a missing limit takes its default.
pub fn parse(reply: bson.RawDocument, diagnostics: ?*Diagnostics) error{ProtocolViolation}!Hello {
    var hello: Hello = .{ .max_wire_version = 0 };
    var flags: struct { writable: ?bool = null, master: bool = false, secondary: bool = false, arbiter: bool = false, hidden: bool = false, ghost: bool = false, mongos: bool = false } = .{};
    var it = reply.iterator();
    while (it.next() catch return violation(diagnostics, "the reply to hello is not valid BSON", .{})) |element| {
        const key = element.key;
        const value = element.value;
        if (eql(key, "maxWireVersion")) {
            hello.max_wire_version = try number(i32, key, value, diagnostics);
        } else if (eql(key, "minWireVersion")) {
            hello.min_wire_version = try number(i32, key, value, diagnostics);
        } else if (eql(key, "maxBsonObjectSize")) {
            hello.max_bson_object_size = try limit(key, value, diagnostics);
        } else if (eql(key, "maxMessageSizeBytes")) {
            hello.max_message_size_bytes = try limit(key, value, diagnostics);
        } else if (eql(key, "maxWriteBatchSize")) {
            hello.max_write_batch_size = try limit(key, value, diagnostics);
        } else if (eql(key, "connectionId")) {
            hello.connection_id = try number(i64, key, value, diagnostics);
        } else if (eql(key, "logicalSessionTimeoutMinutes")) {
            hello.logical_session_timeout_minutes = try number(i64, key, value, diagnostics);
        } else if (eql(key, "setName")) {
            hello.set_name = try string(key, value, diagnostics);
        } else if (eql(key, "msg")) {
            flags.mongos = std.mem.eql(u8, try string(key, value, diagnostics), "isdbgrid");
        } else if (eql(key, "isWritablePrimary")) {
            flags.writable = try boolean(key, value, diagnostics);
        } else if (eql(key, "ismaster")) {
            flags.master = try boolean(key, value, diagnostics);
        } else if (eql(key, "secondary")) {
            flags.secondary = try boolean(key, value, diagnostics);
        } else if (eql(key, "arbiterOnly")) {
            flags.arbiter = try boolean(key, value, diagnostics);
        } else if (eql(key, "hidden")) {
            flags.hidden = try boolean(key, value, diagnostics);
        } else if (eql(key, "isreplicaset")) {
            flags.ghost = try boolean(key, value, diagnostics);
        }
    }
    hello.server_type = if (flags.mongos)
        .mongos
    else if (flags.ghost)
        .rs_ghost
    else if (hello.set_name == null)
        .standalone
    else if (flags.hidden)
        .rs_other
    else if (flags.writable orelse flags.master)
        .rs_primary
    else if (flags.secondary)
        .rs_secondary
    else if (flags.arbiter)
        .rs_arbiter
    else
        .rs_other;
    return hello;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn number(comptime T: type, key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) error{ProtocolViolation}!T {
    const n = value.asI64() catch return violation(diagnostics, "{s} in the reply to hello is not an integer", .{key});
    return std.math.cast(T, n) orelse violation(diagnostics, "{s} in the reply to hello is {d}, beyond {s}", .{ key, n, @typeName(T) });
}

fn limit(key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) error{ProtocolViolation}!u32 {
    const n = try number(i64, key, value, diagnostics);
    if (n < 1 or n > std.math.maxInt(u32)) return violation(diagnostics, "{s} in the reply to hello is {d}; a limit is 1 to 4294967295", .{ key, n });
    return @intCast(n);
}

fn string(key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) error{ProtocolViolation}![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => violation(diagnostics, "{s} in the reply to hello is not a string", .{key}),
    };
}

fn boolean(key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) error{ProtocolViolation}!bool {
    return switch (value) {
        .boolean => |b| b,
        else => violation(diagnostics, "{s} in the reply to hello is not a boolean", .{key}),
    };
}

fn violation(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{ProtocolViolation} {
    if (diagnostics) |d| d.set(.handshake, null, fmt, args);
    return error.ProtocolViolation;
}
