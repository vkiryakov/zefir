//! Tests of `resp.Writer`: commands byte for byte, binary arguments, and an
//! argument larger than the buffer, which must reach the sink without a
//! copy.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");

const Writer = resp.Writer;

/// A sink that keeps every byte written to it and, for every slice that
/// `drain` was given past the buffer, where that slice was and where its
/// copy starts in `bytes`: the slice itself may be gone by the time a test
/// looks, as a header on the writer's stack is.
const Recorder = struct {
    writer: std.Io.Writer,
    bytes: std.ArrayList(u8) = .empty,
    pieces: std.ArrayList(Piece) = .empty,

    const Piece = struct { ptr: [*]const u8, len: usize, at: usize };

    fn init(buffer: []u8) Recorder {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn deinit(r: *Recorder) void {
        r.bytes.deinit(testing.allocator);
        r.pieces.deinit(testing.allocator);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const r: *Recorder = @alignCast(@fieldParentPtr("writer", w));
        r.bytes.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        for (data[0 .. data.len - 1]) |slice| try r.keep(slice);
        for (0..splat) |_| try r.keep(data[data.len - 1]);
        return std.Io.Writer.countSplat(data, splat);
    }

    fn keep(r: *Recorder, slice: []const u8) std.Io.Writer.Error!void {
        const piece: Piece = .{ .ptr = slice.ptr, .len = slice.len, .at = r.bytes.items.len };
        r.pieces.append(testing.allocator, piece) catch return error.WriteFailed;
        r.bytes.appendSlice(testing.allocator, slice) catch return error.WriteFailed;
    }
};

test "a command is an array of bulk strings, sent on flush" {
    var buffer: [16 * 1024]u8 = undefined;
    var recorder: Recorder = .init(&buffer);
    defer recorder.deinit();
    const w: Writer = .init(&recorder.writer);
    try w.command(&.{ "GET", "session:42" });
    try testing.expectEqual(0, recorder.bytes.items.len);
    try recorder.writer.flush();
    try testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$10\r\nsession:42\r\n", recorder.bytes.items);
}

test "an empty argument is a bulk string of 0 bytes" {
    var buffer: [16 * 1024]u8 = undefined;
    var recorder: Recorder = .init(&buffer);
    defer recorder.deinit();
    const w: Writer = .init(&recorder.writer);
    try w.command(&.{ "SET", "k", "" });
    try recorder.writer.flush();
    try testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n", recorder.bytes.items);
}

test "CRLF and a zero byte inside an argument go out as they are" {
    var buffer: [16 * 1024]u8 = undefined;
    var recorder: Recorder = .init(&buffer);
    defer recorder.deinit();
    const w: Writer = .init(&recorder.writer);
    try w.arrayHeader(1);
    try w.bulk("a\r\nb\x00c");
    try recorder.writer.flush();
    try testing.expectEqualStrings("*1\r\n$6\r\na\r\nb\x00c\r\n", recorder.bytes.items);
}

test "an argument larger than the buffer reaches the sink as the caller's own slice" {
    var buffer: [16 * 1024]u8 = undefined;
    var recorder: Recorder = .init(&buffer);
    defer recorder.deinit();
    const value = try testing.allocator.alloc(u8, 20_000);
    defer testing.allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @truncate(i);

    const w: Writer = .init(&recorder.writer);
    try w.command(&.{ "SET", "k", value });
    try recorder.writer.flush();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$20000\r\n");
    try expected.appendSlice(testing.allocator, value);
    try expected.appendSlice(testing.allocator, "\r\n");
    try testing.expectEqualSlices(u8, expected.items, recorder.bytes.items);

    // The value went to the sink as its own slice, right after its header,
    // which came as the slice before it.
    const pieces = recorder.pieces.items;
    const index = for (pieces, 0..) |piece, i| {
        if (piece.ptr == value.ptr) break i;
    } else return error.TestExpectedEqual;
    try testing.expectEqual(value.len, pieces[index].len);
    try testing.expect(index > 0);
    const header = pieces[index - 1];
    try testing.expectEqualStrings("$20000\r\n", recorder.bytes.items[header.at..][0..header.len]);
    try testing.expectEqual(header.at + header.len, pieces[index].at);
}
