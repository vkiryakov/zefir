//! The bytes of an SSE event (the event stream of the
//! HTML standard): the fields `event:`, `id:` and `retry:`, then a `data:`
//! line for each line of the data, then a blank line that ends the event.
//! A comment line, such as the heartbeat `: ping`, is ignored by clients.
const std = @import("std");

const Writer = std.Io.Writer;

/// The fields of one event.
pub const Fields = struct {
    /// The type of the event; null for `message`, as a client calls it.
    event: ?[]const u8 = null,
    /// The id a client sends back as `Last-Event-ID` when it reconnects.
    id: ?[]const u8 = null,
    /// How long a client waits before it reconnects, in milliseconds.
    retry: ?u64 = null,
    /// The data, split into lines on CR, LF and CRLF.
    data: []const u8,
};

/// The heartbeat: a comment, which holds the connection open through
/// proxies and makes a client that has gone show.
pub const heartbeat = ": ping\n\n";

/// Whether `value` can be the `event` or the `id` of an event: a CR or an
/// LF would end its line and start a field of the client's choosing, and a
/// client drops an `id` with NUL.
pub fn validField(value: []const u8) bool {
    return std.mem.findAny(u8, value, "\r\n\x00") == null;
}

/// Writes the event; its `event` and `id` are `validField`.
pub fn write(w: *Writer, fields: Fields) Writer.Error!void {
    if (fields.event) |name| try w.print("event: {s}\n", .{name});
    if (fields.id) |id| try w.print("id: {s}\n", .{id});
    if (fields.retry) |ms| try w.print("retry: {d}\n", .{ms});
    var rest = fields.data;
    while (true) {
        const end = std.mem.findAny(u8, rest, "\r\n") orelse rest.len;
        try w.print("data: {s}\n", .{rest[0..end]});
        if (end == rest.len) break;
        // CRLF is one line break.
        const skip: usize = if (rest[end] == '\r' and end + 1 < rest.len and rest[end + 1] == '\n') 2 else 1;
        rest = rest[end + skip ..];
    }
    try w.writeByte('\n');
}

/// The event in memory from `allocator`.
pub fn alloc(allocator: std.mem.Allocator, fields: Fields) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(&out.writer, fields) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

fn expectEvent(expected: []const u8, fields: Fields) !void {
    const bytes = try alloc(testing.allocator, fields);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

test "publish: event, id, retry and data lines; multi-line data" {
    try expectEvent("event: todo.created\nid: 42\nretry: 3000\ndata: {\"id\":1}\n\n", .{ .event = "todo.created", .id = "42", .retry = 3000, .data = "{\"id\":1}" });
    // Without the optional fields: a message with its data.
    try expectEvent("data: hello\n\n", .{ .data = "hello" });
    // Each line of the data a data line of its own, on LF, CRLF and CR.
    try expectEvent("data: a\ndata: b\ndata: c\ndata: d\n\n", .{ .data = "a\nb\r\nc\rd" });
    // An empty line stays a line; a break at the end leaves an empty last
    // line, so the client's data ends with the break.
    try expectEvent("data: a\ndata: \ndata: b\ndata: \n\n", .{ .data = "a\n\nb\n" });
    // Empty data is one empty data line: the client still gets the event.
    try expectEvent("data: \n\n", .{ .data = "" });
    // A leading space survives: the client strips only the one after the colon.
    try expectEvent("id: \ndata:  x\n\n", .{ .id = "", .data = " x" });
    try testing.expectEqualStrings(": ping\n\n", heartbeat);
}

test "validField refuses CR, LF and NUL, which would break the line of event or id" {
    try testing.expect(validField("todo.created"));
    try testing.expect(validField(""));
    try testing.expect(validField("тудушка: создана"));
    for ([_][]const u8{ "a\nb", "a\rb", "a\x00b", "\n", "todo\r\n" }) |bad| try testing.expect(!validField(bad));
}
