//! The JWS layer against the vectors of RFC 7515 and RFC 7520. Their
//! payloads are no claims of zefir and most of their headers have no
//! "typ", so the tests call `jws` and `crypto` directly.

const std = @import("std");
const base64url = @import("base64url.zig");
const compact = @import("compact.zig");
const crypto = @import("crypto.zig");
const errors = @import("errors.zig");
const jws = @import("jws.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const rfc7515 = @import("testdata/rfc7515.zig");
const rfc7520 = @import("testdata/rfc7520.zig");

const testing = std.testing;
const Details = errors.Details;
const VerifyError = errors.VerifyError;
const jwt_types: []const []const u8 = &.{"JWT"};

/// An HS256 key from "k" of a JWK, base64url as the RFCs give it.
fn hmacKey(comptime K: type, k: []const u8, id: ?[]const u8) !K {
    const secret = try base64url.decodeAlloc(testing.allocator, k);
    defer testing.allocator.free(secret);
    return K.hmac(.HS256, secret, .{ .id = id });
}

/// Opens `token` with `keys` and expects `expected`, with `claim` in `Details`.
fn expectRefused(token: []const u8, keys: []const Key, expected: VerifyError, claim: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (jws.open(arena_state.allocator(), token, keys, jwt_types, &details)) |_| {
        std.debug.print("opened: {s}\n", .{token});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(expected, err);
    if (claim) |name| {
        try testing.expectEqualStrings(name, details.claim orelse "(none)");
    } else {
        try testing.expectEqual(null, details.claim);
    }
}

test "RFC 7515 A.1: the HS256 token opens" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var keys = [_]Key{try hmacKey(Key, rfc7515.a1_key, null)};
    defer keys[0].deinit();

    var details: Details = .{};
    const opened = try jws.open(arena_state.allocator(), rfc7515.a1_token, &keys, jwt_types, &details);
    try testing.expectEqualStrings(rfc7515.a1_payload, opened.payload);
    try testing.expectEqual(.HS256, opened.header.algorithm);
    try testing.expectEqualStrings("JWT", opened.header.token_type);
    try testing.expectEqual(null, opened.header.key_id);

    // Another secret: the signature no longer verifies.
    var other = [_]Key{try hmacKey(Key, rfc7520.key_3_5, null)};
    defer other[0].deinit();
    try expectRefused(rfc7515.a1_token, &other, error.BadSignature, null);
}

test "RFC 7515 A.2, A.4, A.5 and Appendix E: RS256, ES512 and none are UnsupportedAlgorithm" {
    var keys = [_]Key{try hmacKey(Key, rfc7515.a1_key, null)};
    defer keys[0].deinit();
    for ([_][]const u8{ rfc7515.a2_token, rfc7515.a4_token, rfc7515.a5_token, rfc7515.e_token }) |token| {
        try expectRefused(token, &keys, error.UnsupportedAlgorithm, "alg");
    }
}

test "RFC 7520 §4.1–4.3: RS256, PS384 and ES512 are UnsupportedAlgorithm" {
    var keys = [_]Key{try hmacKey(Key, rfc7520.key_3_5, rfc7520.kid_3_5)};
    defer keys[0].deinit();
    for ([_][]const u8{ rfc7520.token_4_1, rfc7520.token_4_2, rfc7520.token_4_3 }) |token| {
        try expectRefused(token, &keys, error.UnsupportedAlgorithm, "alg");
    }
}

test "RFC 7520 §4.4: the HS256 signature verifies, and signing its input gives it byte for byte" {
    var key = try hmacKey(Key, rfc7520.key_3_5, rfc7520.kid_3_5);
    defer key.deinit();
    var signing_key = try hmacKey(SigningKey, rfc7520.key_3_5, rfc7520.kid_3_5);
    defer signing_key.deinit();

    const parts = try compact.split(rfc7520.token_4_4);
    var signature: [32]u8 = undefined;
    try base64url.decode(&signature, parts.signature);
    try crypto.verify(&key, parts.signing_input, &signature);
    var out: [crypto.max_signature_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, &signature, crypto.sign(&signing_key, testing.io, parts.signing_input, &out));

    // The header has no "typ", which zefir requires of every token.
    var keys = [_]Key{signing_key.verificationKey()};
    defer keys[0].deinit();
    try expectRefused(rfc7520.token_4_4, &keys, error.WrongType, "typ");
}

test "RFC 7520 §4.5: detached content is Malformed" {
    var keys = [_]Key{try hmacKey(Key, rfc7520.key_3_5, rfc7520.kid_3_5)};
    defer keys[0].deinit();
    try expectRefused(rfc7520.token_4_5, &keys, error.Malformed, null);
}

test "the JSON serialization is Malformed" {
    // RFC 7515 A.6 and A.7 and RFC 7520 §4.6–4.8 show only the JWS JSON
    // Serialization, which zefir-jwt does not read: a token is the compact
    // form alone.
    var keys = [_]Key{try hmacKey(Key, rfc7515.a1_key, null)};
    defer keys[0].deinit();
    try expectRefused(rfc7515.a6_json, &keys, error.Malformed, null);
    try expectRefused(rfc7515.a7_json, &keys, error.Malformed, null);
}
