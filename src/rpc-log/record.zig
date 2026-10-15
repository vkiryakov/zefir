//! What `AccessLog` and `ClientAccessLog` share: the fields a record may
//! hold, the form of a record, and its level chosen at run time. Internal
//! to the module.

const std = @import("std");
const rpc = @import("rpc");
const log = @import("log");

/// Everything a record may say of its call, in the order records write it
/// under the key `rpc`. A record holds the fields its `Shape` keeps, so
/// that a field it has no value for is left out rather than written as
/// null.
pub const Fields = struct {
    service: []const u8,
    version: u16,
    method: []const u8,
    /// The request id: 32 lowercase hex digits.
    request_id: []const u8,
    /// "ok", or the name of the failure's code.
    code: []const u8,
    app_code: []const u8 = "",
    /// The client's error, when the call ended without a response.
    @"error": []const u8 = "",
    duration_ms: f64,
    transport: []const u8,
    peer: Peer = .{ .peer = .none },
    /// Null for an anonymous call.
    subject: ?[]const u8 = null,
    metadata: []const rpc.Metadata.Entry = &.{},
};

/// The fields of `Fields` that a record may leave out, and whether this
/// one keeps them.
pub const Shape = struct {
    app_code: bool = false,
    @"error": bool = false,
    peer: bool = false,
    subject: bool = false,
    metadata: bool = false,
};

/// The type of the `rpc` object of a record of `shape`: the fields of
/// `Fields` that it keeps, in their order.
pub fn Record(comptime shape: Shape) type {
    const all = @typeInfo(Fields).@"struct";
    var names: [all.field_names.len][]const u8 = undefined;
    var types: [all.field_names.len]type = undefined;
    var n: usize = 0;
    for (all.field_names, all.field_types) |name, T| {
        if (@hasField(Shape, name) and !@field(shape, name)) continue;
        names[n] = name;
        types[n] = T;
        n += 1;
    }
    const kept_names = names[0..n].*;
    const kept_types = types[0..n].*;
    return @Struct(.auto, null, &kept_names, &kept_types, &@splat(.{}));
}

/// Writes one record at `level`: `fields` as the object `rpc`, in the form
/// of `shape`. The level is known only at run time, the form at compile
/// time.
pub fn emit(logger: log.Logger, level: log.Level, comptime message: []const u8, comptime shape: Shape, fields: Fields) void {
    var value: Record(shape) = undefined;
    inline for (@typeInfo(Record(shape)).@"struct".field_names) |name| @field(value, name) = @field(fields, name);
    switch (level) {
        inline else => |l| @field(log.Logger, @tagName(l))(logger, message, .{ .rpc = value }),
    }
}

/// The peer of a call as text: its address or its name.
pub const Peer = struct {
    peer: rpc.transport.Peer,

    pub fn format(p: Peer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p.peer) {
            .none => {},
            .ip => |address| try address.format(w),
            .name => |name| try w.writeAll(name),
        }
    }
};

/// `duration` in milliseconds, with the fraction.
pub fn milliseconds(duration: std.Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / std.time.ns_per_ms;
}

const testing = std.testing;

test "a record keeps only the fields of its shape, in their order" {
    const base = @typeInfo(Record(.{})).@"struct".field_names;
    const expected_base = [_][]const u8{ "service", "version", "method", "request_id", "code", "duration_ms", "transport" };
    try testing.expectEqual(expected_base.len, base.len);
    for (expected_base, base) |want, got| try testing.expectEqualStrings(want, got);

    const full = @typeInfo(Record(.{ .app_code = true, .peer = true, .subject = true, .metadata = true })).@"struct".field_names;
    const expected_full = [_][]const u8{ "service", "version", "method", "request_id", "code", "app_code", "duration_ms", "transport", "peer", "subject", "metadata" };
    try testing.expectEqual(expected_full.len, full.len);
    for (expected_full, full) |want, got| try testing.expectEqualStrings(want, got);
}

test "the peer is its address or its name" {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const peers = [_]struct { rpc.transport.Peer, []const u8 }{
        .{ .{ .ip = try .parse("10.0.0.7", 4222) }, "10.0.0.7:4222" },
        .{ .{ .name = "orders-1" }, "orders-1" },
        .{ .none, "" },
    };
    for (peers) |entry| {
        w.end = 0;
        try (Peer{ .peer = entry[0] }).format(&w);
        try testing.expectEqualStrings(entry[1], w.buffered());
    }
}

test "milliseconds keep the fraction" {
    try testing.expectEqual(@as(f64, 1.5), milliseconds(.fromMicroseconds(1500)));
    try testing.expectEqual(@as(f64, 0), milliseconds(.zero));
}
