//! The body of a failure with validation violations: the framework's own
//! JSON, which `rpc.Server` writes and `rpc.Client` reads. At most 100
//! violations, and no more than the server's `max_response_bytes` holds;
//! `"truncated":true` says that there were more:
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

/// The first `max_violations` of `given`, violations that a method set with
/// `ctx.fail`, as a body carries them, in `arena`: paths as `fieldOf`
/// keeps them. `error.InvalidUtf8` for a code or a message that is not
/// UTF-8, which JSON cannot carry.
pub fn fromFailure(arena: std.mem.Allocator, given: []const model.Violation) error{ OutOfMemory, InvalidUtf8 }![]model.Violation {
    const kept = given[0..@min(given.len, max_violations)];
    for (kept) |violation| {
        if (!std.unicode.utf8ValidateSlice(violation.code) or !std.unicode.utf8ValidateSlice(violation.message)) return error.InvalidUtf8;
    }
    const list = try arena.alloc(model.Violation, kept.len);
    for (kept, list) |found, *violation| {
        violation.* = .{ .field = fieldOf(found.field), .code = found.code, .message = found.message };
    }
    return list;
}

/// What a body keeps of a list of violations: the first `count`, and
/// whether it says `"truncated":true`.
pub const Fit = struct { count: usize, truncated: bool };

/// The smallest body: no violation fits, and it says so.
pub const smallest = "{\"violations\":[],\"truncated\":true}";

const frame = "{\"violations\":[]}";
const truncated_mark = ",\"truncated\":true";

/// How many of `violations`, from the first, a body of at most `max_bytes`
/// holds: no more than `max_violations`. The body says `"truncated":true`
/// when `truncated` does or when it leaves some out. `max_bytes` is at
/// least the size of `smallest`, which always fits.
pub fn fit(violations: []const model.Violation, truncated: bool, max_bytes: usize) Fit {
    std.debug.assert(max_bytes >= smallest.len);
    const list = violations[0..@min(violations.len, max_violations)];
    const more = truncated or violations.len > list.len;
    var size: usize = frame.len;
    var count: usize = 0;
    for (list) |violation| {
        const next = size + itemSize(violation) + @intFromBool(count > 0);
        // A body that leaves some out needs room for the mark.
        const left_out = more or count + 1 < list.len;
        if (next + (if (left_out) truncated_mark.len else 0) > max_bytes) break;
        size = next;
        count += 1;
    }
    return .{ .count = count, .truncated = more or count < list.len };
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
        try writeItem(w, violation);
    }
    try w.writeByte(']');
    if (truncated) try w.writeAll(truncated_mark);
    try w.writeByte('}');
}

fn writeItem(w: *Writer, violation: model.Violation) Writer.Error!void {
    try w.writeAll("{\"field\":");
    if (violation.field) |field| try writeString(field, w) else try w.writeAll("null");
    try w.writeAll(",\"code\":");
    try writeString(violation.code, w);
    try w.writeAll(",\"message\":");
    try writeString(violation.message, w);
    try w.writeByte('}');
}

/// The size of one violation in a body, without the comma before it.
fn itemSize(violation: model.Violation) usize {
    var buffer: [256]u8 = undefined;
    var counter: Writer.Discarding = .init(&buffer);
    writeItem(&counter.writer, violation) catch unreachable; // A discarding writer never fails.
    return @intCast(counter.fullCount());
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

test "a body keeps the first violations that fit its budget, and says that it left some out" {
    const list = [_]model.Violation{
        .{ .field = "tags[0]", .code = "validation.not_empty", .message = "must not be empty" },
        .{ .field = "tags[1]", .code = "validation.not_empty", .message = "must not be empty" },
        .{ .field = null, .code = "c", .message = "m" },
    };
    const whole = try encode(testing.allocator, &list, false);
    defer testing.allocator.free(whole);
    try testing.expectEqual(Fit{ .count = 3, .truncated = false }, fit(&list, false, whole.len));
    // For every budget: the body fits it, and one more violation would not.
    for (smallest.len..whole.len + 1) |max_bytes| {
        const kept = fit(&list, false, max_bytes);
        const body = try encode(testing.allocator, list[0..kept.count], kept.truncated);
        defer testing.allocator.free(body);
        try testing.expect(body.len <= max_bytes);
        try testing.expectEqual(kept.count < list.len, kept.truncated);
        if (kept.count < list.len) {
            const more = try encode(testing.allocator, list[0 .. kept.count + 1], kept.count + 1 < list.len);
            defer testing.allocator.free(more);
            try testing.expect(more.len > max_bytes);
        }
    }
    // The smallest budget holds the smallest body.
    try testing.expectEqual(Fit{ .count = 0, .truncated = true }, fit(&list, false, smallest.len));
    const empty = try encode(testing.allocator, &.{}, true);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(smallest, empty);
    // A list that was cut before stays truncated.
    try testing.expectEqual(Fit{ .count = 3, .truncated = true }, fit(&list, true, 1024));
}

test "a body keeps at most 100 violations" {
    var list: [150]model.Violation = undefined;
    for (&list) |*violation| violation.* = .{ .field = "a", .code = "c", .message = "m" };
    try testing.expectEqual(Fit{ .count = 100, .truncated = true }, fit(&list, false, 1 << 20));
    try testing.expectEqual(Fit{ .count = 100, .truncated = false }, fit(list[0..100], false, 1 << 20));
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
