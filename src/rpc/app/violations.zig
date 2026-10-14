//! The body of a failure with validation violations: the framework's own
//! JSON, which `rpc.Server` writes and `rpc.Client` reads. At most 100
//! violations; `"truncated":true` says that there were more:
//!
//! ```json
//! {"violations":[{"field":"name","code":"validation.not_empty","message":"must not be empty"}],"truncated":true}
//! ```
//!
//! `"field"` is the path of the value, such as "items[2].name", or null for
//! the request as a whole. Internal to the module.

const std = @import("std");
const v = @import("validator");
const model = @import("../model.zig");
const rules = @import("../rules.zig");

const Writer = std.Io.Writer;

/// The most violations a body carries, as zefir-validator keeps them.
pub const max_violations = v.max_report_violations;

/// `path` as a failure carries it: null for a path longer than 256 bytes,
/// with a control character, or not UTF-8, since transports carry the
/// field of a failure in headers too.
pub fn fieldOf(path: ?[]const u8) ?[]const u8 {
    const field = path orelse return null;
    if (field.len > rules.max_field_bytes) return null;
    for (field) |c| {
        if (c < 0x20 or c == 0x7f) return null;
    }
    if (!std.unicode.utf8ValidateSlice(field)) return null;
    return field;
}

/// The violations of a report of zefir-validator, as failures carry them,
/// in `arena`.
pub fn fromReport(arena: std.mem.Allocator, report: v.Report) error{OutOfMemory}![]model.Violation {
    const list = try arena.alloc(model.Violation, report.violations.len);
    for (report.violations, list) |found, *violation| {
        violation.* = .{ .field = fieldOf(found.field), .code = found.code, .message = found.message };
    }
    return list;
}

/// The body for `violations`, at most `max_violations` of them, in
/// `arena`; `truncated` adds `"truncated":true`. Its size is counted
/// first, so the bytes are allocated once.
pub fn encode(arena: std.mem.Allocator, violations: []const model.Violation, truncated: bool) error{OutOfMemory}![]const u8 {
    std.debug.assert(violations.len <= max_violations);
    var buffer: [256]u8 = undefined;
    var counter: Writer.Discarding = .init(&buffer);
    write(&counter.writer, violations, truncated) catch unreachable; // A discarding writer never fails.
    const bytes = try arena.alloc(u8, @intCast(counter.fullCount()));
    var out: Writer = .fixed(bytes);
    write(&out, violations, truncated) catch unreachable; // The same bytes fit exactly.
    return bytes;
}

fn write(w: *Writer, violations: []const model.Violation, truncated: bool) Writer.Error!void {
    try w.writeAll("{\"violations\":[");
    for (violations, 0..) |violation, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"field\":");
        if (violation.field) |field| try writeString(field, w) else try w.writeAll("null");
        try w.writeAll(",\"code\":");
        try writeString(violation.code, w);
        try w.writeAll(",\"message\":");
        try writeString(violation.message, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    if (truncated) try w.writeAll(",\"truncated\":true");
    try w.writeByte('}');
}

fn writeString(text: []const u8, w: *Writer) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

const testing = std.testing;

test "a body lists the violations in order, with null for the request as a whole" {
    const body = try encode(testing.allocator, &.{
        .{ .field = "name", .code = "validation.not_empty", .message = "must not be empty" },
        .{ .field = "items[2].tags[0]", .code = "validation.max_length", .message = "must be at most 8 characters" },
        .{ .field = null, .code = "orders.end_before_start", .message = "end must not be before \"start\"" },
    }, false);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"violations\":[" ++
            "{\"field\":\"name\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}," ++
            "{\"field\":\"items[2].tags[0]\",\"code\":\"validation.max_length\",\"message\":\"must be at most 8 characters\"}," ++
            "{\"field\":null,\"code\":\"orders.end_before_start\",\"message\":\"end must not be before \\\"start\\\"\"}" ++
            "]}",
        body,
    );
}

test "a truncated list says so" {
    const body = try encode(testing.allocator, &.{.{ .field = "a", .code = "c", .message = "m" }}, true);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"violations\":[{\"field\":\"a\",\"code\":\"c\",\"message\":\"m\"}],\"truncated\":true}", body);
    const empty = try encode(testing.allocator, &.{}, false);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("{\"violations\":[]}", empty);
}

test "a body of the most violations is allocated once, exactly" {
    var list: [max_violations]model.Violation = undefined;
    for (&list) |*violation| violation.* = .{ .field = "items[99999].name", .code = "validation.not_empty", .message = "must not be empty" };
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const body = try encode(failing.allocator(), &list, true);
    defer failing.allocator().free(body);
    try testing.expectEqual(@as(usize, 1), failing.allocations);
    try testing.expect(std.mem.endsWith(u8, body, "}],\"truncated\":true}"));
}

test "a path longer than 256 bytes, with a control character or not UTF-8 is left out" {
    const longest: [256]u8 = @splat('a');
    const long: [257]u8 = @splat('a');
    try testing.expectEqualStrings(&longest, fieldOf(&longest).?);
    try testing.expectEqual(@as(?[]const u8, null), fieldOf(&long));
    try testing.expectEqual(@as(?[]const u8, null), fieldOf("a\nb"));
    try testing.expectEqual(@as(?[]const u8, null), fieldOf("a\x7fb"));
    try testing.expectEqual(@as(?[]const u8, null), fieldOf("a\xffb"));
    try testing.expectEqual(@as(?[]const u8, null), fieldOf(null));
    try testing.expectEqualStrings("имя[0]", fieldOf("имя[0]").?);
}

const Order = struct {
    name: []const u8,
    items: []const []const u8,

    pub const field_rules = .{
        .name = v.notEmpty,
        .items = v.each(v.notEmpty),
    };
};

test "the violations of a report keep their order, codes and messages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const order: Order = .{ .name = "", .items = &.{ "a", "", "" } };
    const report = try v.checkAll(arena.allocator(), &order);
    const list = try fromReport(arena.allocator(), report);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("name", list[0].field.?);
    try testing.expectEqualStrings("validation.not_empty", list[0].code);
    try testing.expectEqualStrings("items[1]", list[1].field.?);
    try testing.expectEqualStrings("items[2]", list[2].field.?);
    try testing.expect(!report.truncated);
}
