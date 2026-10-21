//! Strict base64url without padding (RFC 7515 §2, RFC 4648 §5): the
//! alphabet `A–Z a–z 0–9 - _` and nothing else, no '=', no white space,
//! no length of 1 mod 4 and no bits set past the last byte. Every text
//! decodes to one sequence of bytes, and every sequence encodes to one
//! text.

const std = @import("std");

const codec = std.base64.url_safe_no_pad;

/// Whether `c` belongs to the base64url alphabet.
pub fn isAlphabet(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
        else => false,
    };
}

/// The length of the bytes that `text` decodes to. `Malformed` for a
/// length of 1 mod 4, which no bytes encode to; the characters themselves
/// are checked by `decode`.
pub fn decodedLen(text: []const u8) error{Malformed}!usize {
    return codec.Decoder.calcSizeForSlice(text) catch error.Malformed;
}

/// Decodes `text` into `out`, which must be exactly `decodedLen(text)`
/// long: std writes past the end of a shorter buffer.
pub fn decode(out: []u8, text: []const u8) error{Malformed}!void {
    for (text) |c| {
        if (!isAlphabet(c)) return error.Malformed;
    }
    if (out.len != try decodedLen(text)) return error.Malformed;
    codec.Decoder.decode(out, text) catch return error.Malformed;
}

/// `text` decoded into memory of `arena`.
pub fn decodeAlloc(arena: std.mem.Allocator, text: []const u8) error{ Malformed, OutOfMemory }![]u8 {
    for (text) |c| {
        if (!isAlphabet(c)) return error.Malformed;
    }
    const out = try arena.alloc(u8, try decodedLen(text));
    errdefer arena.free(out);
    try decode(out, text);
    return out;
}

/// The length of the text that `len` bytes encode to.
pub fn encodedLen(len: usize) usize {
    return codec.Encoder.calcSize(len);
}

/// Encodes `bytes` into the start of `out`, which is at least
/// `encodedLen(bytes.len)` long, and returns that part.
pub fn encode(out: []u8, bytes: []const u8) []const u8 {
    return codec.Encoder.encode(out, bytes);
}

const testing = std.testing;

fn expectDecodes(text: []const u8, expected: []const u8) !void {
    const got = try decodeAlloc(testing.allocator, text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "base64url decodes the RFC 4648 vectors without padding" {
    try expectDecodes("", "");
    try expectDecodes("Zg", "f");
    try expectDecodes("Zm8", "fo");
    try expectDecodes("Zm9v", "foo");
    try expectDecodes("Zm9vYg", "foob");
    try expectDecodes("Zm9vYmE", "fooba");
    try expectDecodes("Zm9vYmFy", "foobar");
}

test "base64url refuses padding, the standard alphabet, white space and a length of 1 mod 4" {
    for ([_][]const u8{ "Zg==", "Zm+v", "Zm/v", "Zm9 v", "Zm9\nv", "Zm9vY" }) |text| {
        try testing.expectError(error.Malformed, decodeAlloc(testing.allocator, text));
    }
    try testing.expectError(error.Malformed, decodedLen("Zm9vY"));
}

test "base64url refuses non-zero trailing bits" {
    try testing.expectError(error.Malformed, decodeAlloc(testing.allocator, "Zh"));
    try testing.expectError(error.Malformed, decodeAlloc(testing.allocator, "Zm9"));
    try expectDecodes("Zg", "f");
    try expectDecodes("Zm8", "fo");
}

test "decode takes a buffer of exactly the decoded length" {
    var buf: [4]u8 = undefined;
    try testing.expectEqual(2, try decodedLen("Zm8"));
    try decode(buf[0..2], "Zm8");
    try testing.expectEqualStrings("fo", buf[0..2]);
    try testing.expectError(error.Malformed, decode(buf[0..1], "Zm8"));
    try testing.expectError(error.Malformed, decode(buf[0..3], "Zm8"));
}

test "encode then decode gives the bytes back" {
    var bytes: [64]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i * 37 % 256);
    var text_buf: [88]u8 = undefined;
    var back: [64]u8 = undefined;
    for (0..bytes.len + 1) |len| {
        const text = encode(&text_buf, bytes[0..len]);
        try testing.expectEqual(encodedLen(len), text.len);
        try testing.expectEqual(len, try decodedLen(text));
        try decode(back[0..len], text);
        try testing.expectEqualSlices(u8, bytes[0..len], back[0..len]);
    }
}
