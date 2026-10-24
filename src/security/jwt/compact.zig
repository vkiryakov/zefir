//! The compact form of a JWS (RFC 7515 §7.1): three base64url parts
//! joined by '.', the header, the payload and the signature.

const std = @import("std");
const root = @import("root.zig");
const base64url = @import("base64url.zig");

/// The parts of a token, still in base64url; they point into the token.
pub const Parts = struct {
    header: []const u8,
    payload: []const u8,
    /// Empty in an unsecured JWS ("alg": "none"): its algorithm decides.
    signature: []const u8,
    /// What the signature covers: the header and the payload with the '.'
    /// between them, as they are in the token.
    signing_input: []const u8,
};

/// Splits `token` into its parts. A token over `max_token_bytes` is
/// `TokenTooLarge` before anything else is looked at. `Malformed`: not
/// exactly two '.', an empty header or payload (the detached content of
/// RFC 7515 Appendix F), or a byte outside the base64url alphabet, which
/// also refuses the JSON serialization.
pub fn split(token: []const u8) error{ TokenTooLarge, Malformed }!Parts {
    if (token.len > root.max_token_bytes) return error.TokenTooLarge;
    const first = std.mem.findScalar(u8, token, '.') orelse return error.Malformed;
    const second = std.mem.findScalarPos(u8, token, first + 1, '.') orelse return error.Malformed;
    if (std.mem.findScalarPos(u8, token, second + 1, '.') != null) return error.Malformed;
    const parts: Parts = .{
        .header = token[0..first],
        .payload = token[first + 1 .. second],
        .signature = token[second + 1 ..],
        .signing_input = token[0..second],
    };
    if (parts.header.len == 0 or parts.payload.len == 0) return error.Malformed;
    for (token) |c| {
        if (c != '.' and !base64url.isAlphabet(c)) return error.Malformed;
    }
    return parts;
}

const testing = std.testing;

test "a token over 8 KiB is TokenTooLarge before anything else" {
    const dots: [8193]u8 = @splat('.');
    try testing.expectError(error.TokenTooLarge, split(&dots));
    // 4000 + 1 + 4000 + 1 + 190 bytes.
    var token: [8192]u8 = undefined;
    @memset(token[0..4000], 'a');
    token[4000] = '.';
    @memset(token[4001..8001], 'b');
    token[8001] = '.';
    @memset(token[8002..], 'c');
    const parts = try split(&token);
    try testing.expectEqual(4000, parts.header.len);
    try testing.expectEqual(4000, parts.payload.len);
    try testing.expectEqual(190, parts.signature.len);
}

test "a compact token has exactly three parts" {
    for ([_][]const u8{ "abc", "a.b", "a.b.c.d", "a.b.c.d.e" }) |token| {
        try testing.expectError(error.Malformed, split(token));
    }
}

test "the header and the payload are never empty, the signature may be" {
    for ([_][]const u8{ ".b.c", "a..c", "..", "." }) |token| {
        try testing.expectError(error.Malformed, split(token));
    }
    const parts = try split("a.b.");
    try testing.expectEqualStrings("a", parts.header);
    try testing.expectEqualStrings("b", parts.payload);
    try testing.expectEqualStrings("", parts.signature);
}

test "8000 dots are Malformed" {
    const dots: [8000]u8 = @splat('.');
    try testing.expectError(error.Malformed, split(&dots));
}

test "a part holds only A-Z a-z 0-9 - _" {
    for ([_][]const u8{ "a=.b.c", "a.b+.c", "a.b./c", "a b.c.d", "a.b\n.c", "{\"payload\":\"eyJ\"}" }) |token| {
        try testing.expectError(error.Malformed, split(token));
    }
    const parts = try split("AZaz09-_.AZaz09-_.AZaz09-_");
    try testing.expectEqualStrings("AZaz09-_", parts.signature);
}

test "the signing input is the first two parts as they are" {
    const parts = try split("aa.bb.cc");
    try testing.expectEqualStrings("aa", parts.header);
    try testing.expectEqualStrings("bb", parts.payload);
    try testing.expectEqualStrings("cc", parts.signature);
    try testing.expectEqualStrings("aa.bb", parts.signing_input);
}
