const std = @import("std");
const v = @import("validator");

const Status = enum { label_created, in_transit, delivered };

/// An event from a courier's webhook, whose JSON names fields in camelCase.
const ParcelEvent = struct {
    tracking_number: []const u8,
    status: Status,
    eta_days: ?u8 = null,

    pub const field_rules = .{
        .tracking_number = .{ v.rename("trackingNumber"), v.trim, v.toUpper, v.alphanumeric },
        .eta_days = .{ v.rename("etaDays"), v.max(30) },
    };
};

/// Reads a JSON object into a `T` by the outside names of its fields: each
/// key goes under the Zig name of its field, and std.json fills the struct.
/// One level deep: the fields of nested structs keep their Zig names.
fn decode(comptime T: type, arena: std.mem.Allocator, text: []const u8) !T {
    const outside = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (outside != .object) return error.UnexpectedToken;
    var inside: std.json.ObjectMap = .empty;
    for (outside.object.keys(), outside.object.values()) |key, value| {
        const field = v.fieldNamed(T, key) orelse return error.UnknownField;
        try inside.put(arena, @tagName(field), value);
    }
    return std.json.parseFromValueLeaky(T, arena, .{ .object = inside }, .{});
}

/// Writes a `T` as a JSON object, with the outside names as keys.
fn encode(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    inline for (comptime std.meta.tags(std.meta.FieldEnum(T))) |field| {
        try json.objectField(v.nameOf(T, field));
        try json.write(@field(value, @tagName(field)));
    }
    try json.endObject();
}

test "the codec reads and writes the fields by their outside names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const body =
        \\{"trackingNumber": " 1z999aa10123456784 ", "status": "in_transit", "etaDays": 2}
    ;
    var event = try decode(ParcelEvent, arena.allocator(), body);
    try v.transform(arena.allocator(), &event);
    var path_buf: [256]u8 = undefined;
    try std.testing.expectEqual(null, v.check(&event, &path_buf));

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try encode(&out.writer, event);
    try std.testing.expectEqualStrings(
        \\{"trackingNumber":"1Z999AA10123456784","status":"in_transit","etaDays":2}
    , out.written());
}

test "a renamed field is found by its outside name only" {
    try std.testing.expectEqualStrings("trackingNumber", v.nameOf(ParcelEvent, .tracking_number));
    try std.testing.expectEqualStrings("status", v.nameOf(ParcelEvent, .status));
    try std.testing.expect(v.fieldNamed(ParcelEvent, "trackingNumber") == .tracking_number);
    try std.testing.expect(v.fieldNamed(ParcelEvent, "tracking_number") == null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const zig_names =
        \\{"tracking_number": "1Z999AA10123456784", "status": "delivered"}
    ;
    try std.testing.expectError(error.UnknownField, decode(ParcelEvent, arena.allocator(), zig_names));
}
