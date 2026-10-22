//! Fuzzing of the RESP3 reader. `zig build test` runs each corpus entry
//! once, as a regression test; with `--fuzz` the fuzzer runs on it. The
//! property: any bytes give a `Value`, a ProtocolViolation, ReplyTooLarge
//! or the end of the stream, and nothing panics. Whatever comes, every way
//! of going through the first reply ends at the same byte, or fails the
//! same way: reading it into a `Value`, skipping it, and walking it as a
//! decoder does, with only the start of each string kept; read from the
//! bytes at once, or through a buffer that gets a few bytes at a time.
//! Each input runs under a budget larger than itself and under one of
//! half its size, so that the limits are reached too.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const frames = @import("frames.zig");
const value = @import("value.zig");

const Reader = resp.Reader;

/// The longest input the target takes.
const max_input = 4096;
/// A budget larger than any input: only the count of an aggregate can go
/// over it.
const roomy = 64 * 1024;

fn fuzzReader(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    try check(input, roomy);
    try check(input, input.len / 2);
}

fn check(input: []const u8, budget: usize) !void {
    const expected = try go(.read, input, budget, null);
    try testing.expectEqualDeep(expected, try go(.skip, input, budget, null));
    try testing.expectEqualDeep(expected, try go(.walk, input, budget, null));
    try testing.expectEqualDeep(expected, try go(.read, input, budget, 1));
    try testing.expectEqualDeep(expected, try go(.skip, input, budget, 3));
    try testing.expectEqualDeep(expected, try go(.walk, input, budget, 7));
}

/// How going through the first reply ended.
const Outcome = union(enum) {
    /// The reply was whole after this many bytes.
    end: usize,
    failed: enum { protocol_violation, reply_too_large, end_of_stream },
};

const Way = enum { read, skip, walk };

/// Goes through the first reply of `input` in the way `way`: from the
/// bytes at once when `piece` is null, otherwise through a buffer that
/// gets `piece` bytes at a time.
fn go(way: Way, input: []const u8, budget: usize, piece: ?usize) !Outcome {
    var pieces: Pieces = .{};
    var fixed: std.Io.Reader = .fixed(input);
    const in = if (piece) |n| pieces.init(input, n) else &fixed;
    var reader: Reader = .init(in, budget);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result: value.ReadError!void = switch (way) {
        .read => if (resp.readValue(&reader, arena.allocator())) |_| {} else |err| err,
        .skip => reader.skipReply(),
        .walk => walk(&reader),
    };
    if (result) |_| {
        try testing.expect(reader.done());
        const consumed = if (piece != null) pieces.consumed() else fixed.seek;
        return .{ .end = consumed };
    } else |err| return .{
        .failed = switch (err) {
            error.ProtocolViolation => .protocol_violation,
            error.ReplyTooLarge => .reply_too_large,
            error.EndOfStream => .end_of_stream,
            // Memory, or a read of bytes in memory, failing: the property is
            // broken.
            error.OutOfMemory, error.ReadFailed => return err,
        },
    };
}

/// Goes through a reply as a decoder does: every element, keeping only the
/// first bytes of each string.
fn walk(r: *Reader) Reader.Error!void {
    var buffer: [4]u8 = undefined;
    while (true) {
        _ = try r.next();
        _ = try r.payloadPrefix(&buffer);
        if (r.done()) return;
    }
}

/// `input` through a reader whose buffer gets a few bytes at a time. It
/// must stay where it is while the reader is in use.
const Pieces = struct {
    buffer: [max_input]u8 = undefined,
    calls: [1]testing.Reader.Call = undefined,
    source: testing.Reader = undefined,

    fn init(p: *Pieces, input: []const u8, piece: usize) *std.Io.Reader {
        p.calls = .{.{ .buffer = input }};
        p.source = .init(&p.buffer, &p.calls);
        p.source.artificial_limit = .limited(piece);
        return &p.source.interface;
    }

    /// How many bytes of the input the reader on top has taken.
    fn consumed(p: *const Pieces) usize {
        const delivered = if (p.source.next_call_index == p.calls.len) p.calls[0].buffer.len else p.source.next_offset;
        return delivered - p.source.interface.bufferedLen();
    }
};

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first.
fn sample(comptime raw: []const u8) []const u8 {
    return comptime std.mem.toBytes(std.mem.nativeToLittle(u32, raw.len)) ++ raw;
}

/// `levels` arrays of one element nested in each other around `:1`.
fn nested(comptime levels: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10 * levels + 1000);
        var bytes: [levels * 4 + 4]u8 = undefined;
        for (0..levels) |i| bytes[i * 4 ..][0..4].* = "*1\r\n".*;
        bytes[levels * 4 ..][0..4].* = ":1\r\n".*;
        const final = bytes;
        return &final;
    }
}

/// Inputs that the frames cut short do not reach: replies one after the
/// other, nesting at and past the limit, long and odd doubles, and
/// strings of every kind inside aggregates.
const extra = [_][]const u8{
    "+OK\r\n:1\r\n",
    "*2\r\n$1\r\na\r\n$1\r\nb\r\n*1\r\n:1\r\n",
    nested(Reader.max_depth),
    nested(Reader.max_depth + 1),
    nested(1000),
    ",1e99999999999999999999\r\n",
    ",-0.000000000000000000000000000000000000000000000000000000000000000000000000001e-300\r\n",
    ",12345678901234567890123456789012345678901234567890.5\r\n",
    ",+inf\r\n",
    ",-nan\r\n",
    "%2\r\n=7\r\nmkd:abc\r\n!3\r\nERR\r\n(-1\r\n-E\r\n",
    "~3\r\n+\r\n$0\r\n\r\n-\r\n",
    ">2\r\n$9\r\nsubscribe\r\n:1\r\n",
    "*3\r\n|1\r\n%1\r\n+a\r\n+b\r\n*1\r\n:1\r\n:2\r\n:3\r\n:4\r\n",
    "*1000000\r\n",
    "$4294967296\r\n",
    "*18446744073709551615\r\n",
    "$18446744073709551616\r\n",
};

const corpus = make: {
    @setEvalBranchQuota(1_000_000);
    var count = extra.len;
    for (frames.valid) |frame| count += frame[0].len + 1;
    for (frames.broken) |bytes| count += bytes.len + 1;
    var entries: [count][]const u8 = undefined;
    var i = 0;
    // Each frame whole and cut at every length.
    for (frames.valid) |frame| {
        for (0..frame[0].len + 1) |len| {
            entries[i] = sample(frame[0][0..len]);
            i += 1;
        }
    }
    for (frames.broken) |bytes| {
        for (0..bytes.len + 1) |len| {
            entries[i] = sample(bytes[0..len]);
            i += 1;
        }
    }
    for (extra) |bytes| {
        entries[i] = sample(bytes);
        i += 1;
    }
    const final = entries;
    break :make &final;
};

test "fuzz the reader" {
    try testing.fuzz({}, fuzzReader, .{ .corpus = corpus });
}
