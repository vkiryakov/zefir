//! The chunked transfer coding of a request body (RFC 9112 §7.1), decoded
//! strictly. Pure: bytes in, data out; no I/O, no allocation.
//!
//! The connection feeds the decoder the bytes it holds after the head.
//! `feed` consumes a prefix of them and returns the data among them as a
//! slice of its input, one run at a time; the decoder keeps its place in
//! between, so the body may arrive in pieces of any size. Call `feed`
//! again with `input[consumed..]`, then with more bytes, until `done`; a
//! step that consumes nothing needs more input. The bytes after the body
//! belong to the next request.
//!
//! What it takes: a size of 1 to 16 hex digits right before CRLF or `;`;
//! extensions `;name`, `;name=token` or `;name="quoted"` without
//! whitespace; CRLF after the data; trailer fields after the last chunk,
//! read and dropped. Extensions and trailers together may take
//! `max_meta_bytes`. An error leaves the stream out of step: answer 400
//! and close the connection.

const std = @import("std");
const head = @import("head.zig");

const isToken = head.isToken;
const isValueChar = head.isValueChar;

pub const Decoder = struct {
    state: State = .size_start,
    /// The size read so far, then the data left in the chunk.
    size: u64 = 0,
    digits: u8 = 0,
    /// Bytes of extensions and trailers so far.
    meta: u32 = 0,
    max_meta_bytes: u32,
    /// The first error; every `feed` after it returns it again.
    failed: ?Error = null,

    pub const Error = error{
        /// The body breaks the chunked syntax.
        BadChunk,
        /// Chunk extensions and trailer fields over `max_meta_bytes`.
        MetaTooLarge,
    };

    pub const Step = struct {
        /// Bytes of the input the step used, its data included.
        consumed: usize,
        /// Data of the body: a slice of the input, maybe empty.
        data: []const u8,
        /// The body has ended, trailers and all.
        done: bool,
    };

    const State = enum {
        size_start,
        size,
        ext_name_start,
        ext_name,
        ext_value_start,
        ext_token,
        ext_quoted,
        ext_quoted_pair,
        ext_quoted_end,
        size_lf,
        data,
        data_cr,
        data_lf,
        trailer_start,
        trailer_name,
        trailer_value,
        trailer_lf,
        end_lf,
        done,
    };

    /// A decoder for one body. `max_meta_bytes` counts the extensions
    /// (from `;` to the end of their line) and the trailer lines with their
    /// CRLF, over the whole body; the sizes and CRLFs of the chunks don't
    /// count.
    pub fn init(max_meta_bytes: u32) Decoder {
        return .{ .max_meta_bytes = max_meta_bytes };
    }

    pub fn feed(d: *Decoder, input: []const u8) Error!Step {
        if (d.failed) |err| return err;
        var i: usize = 0;
        while (i < input.len and d.state != .done) {
            if (d.state == .data) {
                const n: usize = @intCast(@min(d.size, input.len - i));
                d.size -= n;
                if (d.size == 0) d.state = .data_cr;
                return .{ .consumed = i + n, .data = input[i..][0..n], .done = false };
            }
            d.step(input[i]) catch |err| {
                d.failed = err;
                return err;
            };
            i += 1;
        }
        return .{ .consumed = i, .data = input[i..i], .done = d.state == .done };
    }

    fn step(d: *Decoder, c: u8) Error!void {
        // Whether `c` is a byte of an extension or a trailer line.
        var meta = true;
        switch (d.state) {
            .size_start => {
                meta = false;
                d.size = hexValue(c) orelse return error.BadChunk;
                d.digits = 1;
                d.state = .size;
            },
            .size => if (hexValue(c)) |value| {
                meta = false;
                if (d.digits == 16) return error.BadChunk;
                d.size = d.size << 4 | value;
                d.digits += 1;
            } else switch (c) {
                ';' => d.state = .ext_name_start,
                '\r' => {
                    meta = false;
                    d.state = .size_lf;
                },
                else => return error.BadChunk,
            },
            .ext_name_start => {
                if (!isToken(c)) return error.BadChunk;
                d.state = .ext_name;
            },
            .ext_name => switch (c) {
                ';' => d.state = .ext_name_start,
                '=' => d.state = .ext_value_start,
                '\r' => {
                    meta = false;
                    d.state = .size_lf;
                },
                else => if (!isToken(c)) return error.BadChunk,
            },
            .ext_value_start => {
                if (c == '"') {
                    d.state = .ext_quoted;
                } else if (isToken(c)) {
                    d.state = .ext_token;
                } else return error.BadChunk;
            },
            .ext_token => switch (c) {
                ';' => d.state = .ext_name_start,
                '\r' => {
                    meta = false;
                    d.state = .size_lf;
                },
                else => if (!isToken(c)) return error.BadChunk,
            },
            .ext_quoted => switch (c) {
                '"' => d.state = .ext_quoted_end,
                '\\' => d.state = .ext_quoted_pair,
                // qdtext: HTAB, SP, VCHAR but '"' and '\', obs-text.
                else => if (!isValueChar(c)) return error.BadChunk,
            },
            .ext_quoted_pair => {
                if (!isValueChar(c)) return error.BadChunk;
                d.state = .ext_quoted;
            },
            .ext_quoted_end => switch (c) {
                ';' => d.state = .ext_name_start,
                '\r' => {
                    meta = false;
                    d.state = .size_lf;
                },
                else => return error.BadChunk,
            },
            .size_lf => {
                meta = false;
                if (c != '\n') return error.BadChunk;
                d.state = if (d.size == 0) .trailer_start else .data;
            },
            .data_cr => {
                meta = false;
                if (c != '\r') return error.BadChunk;
                d.state = .data_lf;
            },
            .data_lf => {
                meta = false;
                if (c != '\n') return error.BadChunk;
                d.state = .size_start;
            },
            .trailer_start => if (c == '\r') {
                meta = false;
                d.state = .end_lf;
            } else if (isToken(c)) {
                d.state = .trailer_name;
            } else return error.BadChunk,
            .trailer_name => if (c == ':') {
                d.state = .trailer_value;
            } else if (!isToken(c)) return error.BadChunk,
            .trailer_value => if (c == '\r') {
                d.state = .trailer_lf;
            } else if (!isValueChar(c)) return error.BadChunk,
            .trailer_lf => {
                if (c != '\n') return error.BadChunk;
                d.state = .trailer_start;
            },
            .end_lf => {
                meta = false;
                if (c != '\n') return error.BadChunk;
                d.state = .done;
            },
            .data, .done => unreachable,
        }
        if (meta) {
            d.meta += 1;
            if (d.meta > d.max_meta_bytes) return error.MetaTooLarge;
        }
    }
};

fn hexValue(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

const testing = std.testing;
const cases = @import("testdata/cases.zig");

const End = union(enum) { done, incomplete, failed: Decoder.Error };

const Decoded = struct {
    data: []const u8,
    /// Bytes the decoder consumed.
    len: usize,
    end: End,
};

/// Decodes `raw` fed in pieces: cut at `cuts` (increasing offsets), then
/// one byte at a time from `bytewise_from` on.
fn decode(out: []u8, raw: []const u8, max_meta: u32, cuts: []const usize, bytewise_from: usize) Decoded {
    var decoder: Decoder = .init(max_meta);
    var data_len: usize = 0;
    var len: usize = 0;
    var start: usize = 0;
    var next_cut: usize = 0;
    while (start < raw.len) {
        var end = raw.len;
        if (next_cut < cuts.len) {
            end = cuts[next_cut];
            next_cut += 1;
        }
        if (start >= bytewise_from) end = start + 1;
        var rest = raw[start..end];
        start = end;
        while (rest.len > 0) {
            const step = decoder.feed(rest) catch |err| return .{ .data = out[0..data_len], .len = len, .end = .{ .failed = err } };
            @memcpy(out[data_len..][0..step.data.len], step.data);
            data_len += step.data.len;
            len += step.consumed;
            rest = rest[step.consumed..];
            if (step.done) return .{ .data = out[0..data_len], .len = len, .end = .done };
        }
    }
    return .{ .data = out[0..data_len], .len = len, .end = .incomplete };
}

fn expectDecoded(case: cases.BodyCase, got: Decoded) !void {
    switch (case.expect) {
        .done => |want| {
            try testing.expectEqual(.done, std.meta.activeTag(got.end));
            try testing.expectEqualStrings(want.data, got.data);
            try testing.expectEqual(want.len orelse case.raw.len, got.len);
        },
        .incomplete => |data| {
            try testing.expectEqual(.incomplete, std.meta.activeTag(got.end));
            try testing.expectEqualStrings(data, got.data);
            try testing.expectEqual(case.raw.len, got.len);
        },
        .err => |err| try testing.expectEqual(End{ .failed = err }, got.end),
    }
}

test "chunked: sizes, extensions and trailers" {
    var out: [256]u8 = undefined;
    for (cases.chunked_rules) |case| {
        expectDecoded(case, decode(&out, case.raw, 4 << 10, &.{}, std.math.maxInt(usize))) catch |err| {
            std.debug.print("case \"{s}\": {f}\n", .{ case.name, std.zig.fmtString(case.raw) });
            return err;
        };
    }
    // A step that ends in the data returns it at once; the next one goes on
    // from there.
    var decoder: Decoder = .init(4 << 10);
    const first = try decoder.feed("5;a=1\r\nhel");
    try testing.expectEqualStrings("hel", first.data);
    try testing.expectEqual(10, first.consumed);
    const second = try decoder.feed("lo\r\n0\r\n\r\nNEXT");
    try testing.expectEqualStrings("lo", second.data);
    try testing.expectEqual(2, second.consumed);
    const last = try decoder.feed("\r\n0\r\n\r\nNEXT");
    try testing.expect(last.done);
    try testing.expectEqual(7, last.consumed);
    try testing.expectEqual(0, last.data.len);
    // After the end, nothing more is consumed; after an error, it stays.
    try testing.expectEqual(0, (try decoder.feed("NEXT")).consumed);
    var broken: Decoder = .init(4 << 10);
    try testing.expectError(error.BadChunk, broken.feed("x"));
    try testing.expectError(error.BadChunk, broken.feed("1\r\nx\r\n0\r\n\r\n"));
}

test "chunked: the meta limit is exact" {
    var out: [64]u8 = undefined;
    const Row = struct { []const u8, ?Decoder.Error };
    // A limit of 8: ";a=12345" is 8 bytes, a trailer line "X: 1234\r\n" is 9.
    const rows = [_]Row{
        .{ "1;a=12345\r\nx\r\n0\r\n\r\n", null },
        .{ "1;a=123456\r\nx\r\n0\r\n\r\n", error.MetaTooLarge },
        // Across chunks, the last one too.
        .{ "1;a\r\nx\r\n1;b\r\ny\r\n0;cde\r\n\r\n", null },
        .{ "1;a\r\nx\r\n1;b\r\ny\r\n0;cdef\r\n\r\n", error.MetaTooLarge },
        // Trailers count with their CRLF; the last empty line does not.
        .{ "0\r\nX: 1234\r\n\r\n", error.MetaTooLarge },
        .{ "0\r\nX: 123\r\n\r\n", null },
        .{ "1;a\r\nx\r\n0\r\nX:1\r\n\r\n", null },
        .{ "1;abc\r\nx\r\n0\r\nX:1\r\n\r\n", error.MetaTooLarge },
        // Sizes and CRLFs don't count, however many chunks.
        .{ "0000000000000001\r\nx\r\n0000000000000001\r\ny\r\n0000000000000000\r\n\r\n", null },
    };
    for (rows) |row| {
        const got = decode(&out, row[0], 8, &.{}, std.math.maxInt(usize));
        if (row[1]) |err| {
            testing.expectEqual(End{ .failed = err }, got.end) catch |e| {
                std.debug.print("{f}\n", .{std.zig.fmtString(row[0])});
                return e;
            };
        } else {
            testing.expectEqual(.done, std.meta.activeTag(got.end)) catch |e| {
                std.debug.print("{f}\n", .{std.zig.fmtString(row[0])});
                return e;
            };
        }
    }
    // Twelve chunks with an extension of 2 bytes each: 24 bytes for the
    // whole body.
    const many = comptime body: {
        var raw: []const u8 = "";
        for (0..12) |_| raw = raw ++ "1;e\r\nx\r\n";
        break :body raw ++ "0\r\n\r\n";
    };
    try testing.expectEqual(.done, std.meta.activeTag(decode(&out, many, 24, &.{}, std.math.maxInt(usize)).end));
    try testing.expectEqual(End{ .failed = error.MetaTooLarge }, decode(&out, many, 23, &.{}, std.math.maxInt(usize)).end);
}

test "chunked: the same data for every split of the input" {
    var whole_out: [256]u8 = undefined;
    var split_out: [256]u8 = undefined;
    for (cases.chunked_rules) |case| {
        const whole = decode(&whole_out, case.raw, 4 << 10, &.{}, std.math.maxInt(usize));
        for (0..case.raw.len + 1) |cut| {
            // Two pieces, cut anywhere; then one byte at a time from there.
            for ([_]usize{ std.math.maxInt(usize), cut }) |bytewise_from| {
                const split = decode(&split_out, case.raw, 4 << 10, &.{cut}, bytewise_from);
                testing.expectEqualStrings(whole.data, split.data) catch |err| {
                    std.debug.print("case \"{s}\" cut at {d}\n", .{ case.name, cut });
                    return err;
                };
                try testing.expectEqual(whole.end, split.end);
                // A step that fails consumes nothing, so the bytes of the
                // steps before an error depend on the cut.
                if (whole.end != .failed) try testing.expectEqual(whole.len, split.len);
            }
        }
    }
}
