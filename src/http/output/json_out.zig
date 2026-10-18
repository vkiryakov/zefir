//! Values out as JSON: the body of `http.Json(T)` and
//! of `ctx.response.json`, keys by the outside names of the validator
//! (`v.nameOf`). A field with `v.rename("userName")` is written as
//! `userName`; a DTO without `field_rules` keeps its Zig names. `encode`
//! runs the transforms of `field_rules` first (`v.transform`), as every
//! JSON of a response does.
//!
//! | Value                        | JSON                                       |
//! |------------------------------|--------------------------------------------|
//! | a struct                     | an object, fields in declaration order     |
//! | `?T`                         | `null`, or the value                       |
//! | `[]const u8`, `[N]u8`        | a string; bytes that are not UTF-8 are U+FFFD |
//! | a slice, an array, a tuple   | an array                                   |
//! | a tagged union               | an object with one key, the active tag     |
//! | a float                      | a number; NaN and the infinities `null`    |
//! | integers, bool, enums        | as `std.json.Stringify` writes them        |
//!
//! A type with a `jsonStringify` of its own, such as `std.json.Value`,
//! writes itself through `std.json.Stringify`.
const std = @import("std");
const v = @import("validator");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

pub const Options = struct {
    /// Leaves out the field of a struct whose optional value is null,
    /// instead of writing it as `null`.
    omit_null_fields: bool = false,
};

/// The transformed copy of `value` as JSON, in `arena`: `v.transform`
/// first, then `write`. An error of a transform of its own comes back as it
/// is, as `v.TransformError(@TypeOf(value))` says.
pub fn encode(arena: Allocator, value: anytype, options: Options) v.TransformError(@TypeOf(value))![]u8 {
    const T = @TypeOf(value);
    if (comptime comptimeOnly(T)) return alloc(arena, value, options);
    var copy: T = value;
    try v.transform(arena, &copy);
    return alloc(arena, copy, options);
}

/// `value` as JSON in memory from `allocator`, as it is.
pub fn alloc(allocator: Allocator, value: anytype, options: Options) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(&out.writer, value, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Writes `value` as JSON, keys by outside names; call it after
/// `v.transform`.
pub fn write(w: *Writer, value: anytype, options: Options) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime std.meta.hasFn(T, "jsonStringify")) return Stringify.value(value, .{}, w);
            if (s.is_tuple) {
                try w.writeByte('[');
                inline for (0..s.field_names.len) |i| {
                    if (i > 0) try w.writeByte(',');
                    try write(w, value[i], options);
                }
                return w.writeByte(']');
            }
            try w.writeByte('{');
            var first = true;
            inline for (s.field_names, s.field_types) |name, F| {
                if (comptime F != void) {
                    const field = @field(value, name);
                    if (!omitted(field, options)) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try Stringify.encodeJsonString(comptime v.nameOf(T, @field(std.meta.FieldEnum(T), name)), .{}, w);
                        try w.writeByte(':');
                        try write(w, field, options);
                    }
                }
            }
            return w.writeByte('}');
        },
        .optional => return if (value) |payload| write(w, payload, options) else w.writeAll("null"),
        .pointer => |p| switch (p.size) {
            .one => return write(w, value.*, options),
            .slice => {
                if (p.child == u8) return writeString(w, value);
                return writeItems(w, value, options);
            },
            .many => if (comptime p.sentinel() != null) return write(w, std.mem.span(value), options),
            .c => {},
        },
        .array => |a| {
            if (a.child == u8) return writeString(w, &value);
            return writeItems(w, &value, options);
        },
        .float => if (!std.math.isFinite(value)) return w.writeAll("null"),
        .@"union" => |u| {
            if (comptime std.meta.hasFn(T, "jsonStringify") or u.tag_type == null) return Stringify.value(value, .{}, w);
            try w.writeByte('{');
            switch (value) {
                inline else => |payload, tag| {
                    try Stringify.encodeJsonString(@tagName(tag), .{}, w);
                    try w.writeByte(':');
                    if (@TypeOf(payload) == void) try w.writeAll("{}") else try write(w, payload, options);
                },
            }
            return w.writeByte('}');
        },
        else => {},
    }
    // The leaves: integers, finite floats, bool, enums, errors, null.
    return Stringify.value(value, .{}, w);
}

fn writeItems(w: *Writer, items: anytype, options: Options) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try write(w, item, options);
    }
    try w.writeByte(']');
}

fn omitted(field: anytype, options: Options) bool {
    if (@typeInfo(@TypeOf(field)) != .optional) return false;
    return options.omit_null_fields and field == null;
}

/// A JSON string of `bytes`; a byte that does not begin a valid UTF-8
/// sequence is U+FFFD, so that the string stays a string.
fn writeString(w: *Writer, bytes: []const u8) Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(bytes)) return Stringify.encodeJsonString(bytes, .{}, w);
    try w.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                i += len;
                continue;
            } else |_| {}
        }
        try Stringify.encodeJsonStringChars(bytes[start..i], .{}, w);
        try w.writeAll("\\ufffd");
        i += 1;
        start = i;
    }
    try Stringify.encodeJsonStringChars(bytes[start..], .{}, w);
    try w.writeByte('"');
}

/// A type whose values exist only at compile time, such as the integer of
/// `ctx.response.json(42)`: nothing to transform.
fn comptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .enum_literal, .null => true,
        else => false,
    };
}

const testing = std.testing;

const Priority = enum { low, normal, high };

const Line = struct {
    display_name: []const u8,
    done: bool = false,
    pub const field_rules = .{ .display_name = .{ v.rename("displayName"), v.trim } };
};

const TodoResponse = struct {
    id: u64,
    user_name: []const u8,
    priority: Priority,
    note: ?[]const u8,
    ratio: f64,
    lines: []const Line,
    tags: [2][]const u8,
    owner: ?Line,

    pub const field_rules = .{
        .user_name = .{ v.rename("userName"), v.trim },
        .note = v.trim,
    };
};

fn expectJson(expected: []const u8, value: anytype, options: Options) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try encode(arena_state.allocator(), value, options));
}

test "json out: outside names and transforms" {
    const value: TodoResponse = .{
        .id = 7,
        .user_name = "  Ann ",
        .priority = .high,
        .note = " call back ",
        .ratio = 2.5,
        .lines = &.{ .{ .display_name = " milk " }, .{ .display_name = "bread", .done = true } },
        .tags = .{ "home", "shop" },
        .owner = null,
    };
    try expectJson(
        \\{"id":7,"userName":"Ann","priority":"high","note":"call back","ratio":2.5,"lines":[{"displayName":"milk","done":false},{"displayName":"bread","done":true}],"tags":["home","shop"],"owner":null}
    , value, .{});
    // The transforms worked on a copy: the value is as it was.
    try testing.expectEqualStrings("  Ann ", value.user_name);
    // A root list, and null fields left out.
    try expectJson("[{\"displayName\":\"a\",\"done\":false}]", @as([]const Line, &.{.{ .display_name = " a" }}), .{});
    try expectJson("{\"displayName\":\"x\"}", struct {
        display_name: []const u8,
        missing: ?u8 = null,
        pub const field_rules = .{ .display_name = v.rename("displayName") };
    }{ .display_name = "x" }, .{ .omit_null_fields = true });
}

test "json out: a DTO without field_rules keeps its Zig names" {
    const Plain = struct { user_name: []const u8, @"content-type": []const u8 = "text/plain", count: u32 = 2 };
    try expectJson("{\"user_name\":\"  Ann \",\"content-type\":\"text/plain\",\"count\":2}", Plain{ .user_name = "  Ann " }, .{});
    // A literal of the handler, its fields known at compile time.
    try expectJson("{\"id\":7,\"title\":\"Buy milk\",\"ok\":true}", .{ .id = 7, .title = "Buy milk", .ok = true }, .{});
    try expectJson("42", 42, .{});
}

test "json out: strings, numbers, unions and types that write themselves" {
    // Bytes that are not UTF-8 become U+FFFD; escapes as JSON wants them.
    try expectJson("\"a\\ufffdb\\ufffd\\ufffdc\\\"\\n\\u0001é\"", @as([]const u8, "a\xffb\xed\xa0c\"\n\x01é"), .{});
    try expectJson("[null,null,null,1.5,-3]", .{ std.math.nan(f64), std.math.inf(f32), -std.math.inf(f64), @as(f32, 1.5), @as(i8, -3) }, .{});
    const Shape = union(enum) {
        circle: struct {
            radius_mm: u32,
            pub const field_rules = .{ .radius_mm = v.rename("radiusMm") };
        },
        none,
    };
    try expectJson("[{\"circle\":{\"radiusMm\":3}},{\"none\":{}}]", [_]Shape{ .{ .circle = .{ .radius_mm = 3 } }, .none }, .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"a\":[1,true,null]}", .{});
    defer parsed.deinit();
    try expectJson("{\"a\":[1,true,null]}", parsed.value, .{});
    try expectJson("\"ab\"", @as([2]u8, .{ 'a', 'b' }), .{});
}

test "json out: a transform of its own fails the encoding with its error" {
    const Tagged = struct {
        tags: []const []const u8,
        pub const field_rules = .{ .tags = v.transformWith(refuseEmpty) };
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.NoTags, encode(arena_state.allocator(), Tagged{ .tags = &.{} }, .{}));
    try testing.expectEqualStrings("{\"tags\":[\"a\"]}", try encode(arena_state.allocator(), Tagged{ .tags = &.{"a"} }, .{}));
}

fn refuseEmpty(_: Allocator, tags: []const []const u8) error{NoTags}![]const []const u8 {
    if (tags.len == 0) return error.NoTags;
    return tags;
}
