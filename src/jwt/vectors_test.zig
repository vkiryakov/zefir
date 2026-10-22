//! The JWS layer against the vectors of RFC 7515, RFC 7520 and RFC 8037,
//! and against an ES384 token of OpenSSL, since the RFCs have none.
//! Their payloads are no claims of zefir and most of their headers have no
//! "typ", so the tests call `jws` and `crypto` directly. The RFCs give
//! their EC and Ed25519 keys as JWKs, which zefir-jwt does not read: the
//! tests build the DER of each key from the JWK's bytes.

const std = @import("std");
const base64url = @import("base64url.zig");
const compact = @import("compact.zig");
const crypto = @import("crypto.zig");
const errors = @import("errors.zig");
const jws = @import("jws.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Verifier = @import("Verifier.zig");
const rfc7515 = @import("testdata/rfc7515.zig");
const rfc7520 = @import("testdata/rfc7520.zig");
const rfc8037 = @import("testdata/rfc8037.zig");
const openssl = @import("testdata/openssl.zig");
const key_files = @import("testdata/keys.zig");
const hex = key_files.hex;
const FixedClock = @import("testing.zig").FixedClock;

const testing = std.testing;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
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
    try testing.expectEqualSlices(u8, &signature, try crypto.sign(&signing_key, testing.io, parts.signing_input, &out));

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

/// The SPKI of the P-256 key of RFC 7515 A.3.1: its "x" and "y" after the
/// AlgorithmIdentifier of P-256.
fn a3Spki() ![91]u8 {
    var spki: [91]u8 = undefined;
    @memcpy(spki[0..27], comptime hex("3059301306072a8648ce3d020106082a8648ce3d03010703420004"));
    try base64url.decode(spki[27..59], rfc7515.a3_x);
    try base64url.decode(spki[59..91], rfc7515.a3_y);
    return spki;
}

/// The SEC1 of the same key: its "d" and the curve in [0].
fn a3Sec1() ![51]u8 {
    var sec1: [51]u8 = undefined;
    @memcpy(sec1[0..7], comptime hex("30310201010420"));
    try base64url.decode(sec1[7..39], rfc7515.a3_d);
    @memcpy(sec1[39..51], comptime hex("a00a06082a8648ce3d030107"));
    return sec1;
}

/// Verifies `token` with `keys` through a `Verifier` and expects
/// `WrongType`: the headers of these vectors have no "typ".
fn expectWrongType(token: []const u8, keys: []const Key, issuer: []const u8) !void {
    const verifier: Verifier = try .init(.{ .keys = keys, .issuer = issuer, .audiences = &.{issuer} });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    try testing.expectError(error.WrongType, verifier.verify(void, testing.io, arena_state.allocator(), token, .{ .details = &details }));
    try testing.expectEqualStrings("typ", details.claim.?);
}

test "RFC 7515 A.3: the ES256 signature has a high s, its low twin verifies, and the Verifier says WrongType" {
    const spki = try a3Spki();
    var key: Key = try .fromDer(.ES256, &spki, .{});
    defer key.deinit();
    const parts = try compact.split(rfc7515.a3_token);
    var signature: [64]u8 = undefined;
    try base64url.decode(&signature, parts.signature);
    // The s of A.3 lies in the upper half of the group. ECDSA takes (r, s)
    // and (r, n − s) alike; zefir signs with the lower s alone and takes
    // only that one, so that a token has one string.
    try testing.expectError(error.BadSignature, crypto.verify(&key, parts.signing_input, &signature));
    var twin = signature;
    twin[32..].* = try EcdsaP256Sha256.Curve.scalar.neg(signature[32..].*, .big);
    try crypto.verify(&key, parts.signing_input, &twin);

    var sec1 = try a3Sec1();
    defer std.crypto.secureZero(u8, &sec1);
    var signing: SigningKey = try .fromDer(.ES256, &sec1, .{});
    defer signing.deinit();
    var own = [_]Key{signing.verificationKey()};
    defer own[0].deinit();
    try crypto.verify(&own[0], parts.signing_input, &twin);

    // The header has no "typ", which zefir requires of every token.
    try expectWrongType(rfc7515.a3_token, &own, "joe");
}

test "an ES384 token of OpenSSL verifies, through a Verifier too" {
    const parts = try compact.split(openssl.es384_token);
    var signature: [96]u8 = undefined;
    try base64url.decode(&signature, parts.signature);
    // The token holds r‖s of the DER that OpenSSL wrote.
    var der: [openssl.es384_der_hex.len / 2]u8 = undefined;
    const from_der = try EcdsaP384Sha384.Signature.fromDer(try std.fmt.hexToBytes(&der, openssl.es384_der_hex));
    try testing.expectEqualSlices(u8, &from_der.toBytes(), &signature);

    var keys = [_]Key{try .fromPem(.ES384, key_files.get("p384.pub.pem").bytes, .{})};
    defer keys[0].deinit();
    try crypto.verify(&keys[0], parts.signing_input, &signature);

    var clock: FixedClock = try .init(testing.io, 1_760_000_000);
    defer clock.deinit();
    const verifier: Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const verified = try verifier.verify(void, clock.io(), arena_state.allocator(), openssl.es384_token, .{});
    try testing.expectEqual(.ES384, verified.header.algorithm);
    try testing.expectEqualStrings("user-7", verified.registered.subject.?);
}

/// The PKCS#8 of the Ed25519 key of RFC 8037 A.1: its "d", the seed.
fn rfc8037Pkcs8() ![48]u8 {
    var pkcs8: [48]u8 = undefined;
    @memcpy(pkcs8[0..16], comptime hex("302e020100300506032b657004220420"));
    try base64url.decode(pkcs8[16..48], rfc8037.d);
    return pkcs8;
}

/// The SPKI of its public key, "x" of A.2.
fn rfc8037Spki() ![44]u8 {
    var spki: [44]u8 = undefined;
    @memcpy(spki[0..12], comptime hex("302a300506032b6570032100"));
    try base64url.decode(spki[12..44], rfc8037.x);
    return spki;
}

test "RFC 8037 A.1 and A.2: the public key comes from the seed" {
    var pkcs8 = try rfc8037Pkcs8();
    defer std.crypto.secureZero(u8, &pkcs8);
    var signing: SigningKey = try .fromDer(.EdDSA, &pkcs8, .{});
    defer signing.deinit();
    var from_seed = signing.verificationKey();
    defer from_seed.deinit();
    const spki = try rfc8037Spki();
    var key: Key = try .fromDer(.EdDSA, &spki, .{});
    defer key.deinit();

    // The seed and the public key are the hex dumps of A.1.
    var expected: [32]u8 = undefined;
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, rfc8037.d_hex), pkcs8[16..48]);
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, rfc8037.x_hex), &from_seed.material.ed25519.toBytes());
    try testing.expectEqualSlices(u8, &key.material.ed25519.toBytes(), &from_seed.material.ed25519.toBytes());

    var out: [crypto.max_signature_bytes]u8 = undefined;
    const signature = try crypto.sign(&signing, testing.io, "abc", &out);
    try crypto.verify(&from_seed, "abc", signature);
    try crypto.verify(&key, "abc", signature);
}

test "RFC 8037 A.4: signing gives the JWS byte for byte" {
    var pkcs8 = try rfc8037Pkcs8();
    defer std.crypto.secureZero(u8, &pkcs8);
    var signing: SigningKey = try .fromDer(.EdDSA, &pkcs8, .{});
    defer signing.deinit();
    const parts = try compact.split(rfc8037.token);

    var out: [crypto.max_signature_bytes]u8 = undefined;
    const signature = try crypto.sign(&signing, testing.io, parts.signing_input, &out);
    var expected: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, rfc8037.signature_hex), signature);
    var text: [86]u8 = undefined;
    const token = try std.fmt.allocPrint(testing.allocator, "{s}.{s}", .{ parts.signing_input, base64url.encode(&text, signature) });
    defer testing.allocator.free(token);
    try testing.expectEqualStrings(rfc8037.token, token);
}

test "RFC 8037 A.5: the JWS verifies" {
    const spki = try rfc8037Spki();
    var keys = [_]Key{try .fromDer(.EdDSA, &spki, .{})};
    defer keys[0].deinit();
    const parts = try compact.split(rfc8037.token);
    var signature: [64]u8 = undefined;
    try base64url.decode(&signature, parts.signature);
    try crypto.verify(&keys[0], parts.signing_input, &signature);
    var payload: [rfc8037.payload.len]u8 = undefined;
    try base64url.decode(&payload, parts.payload);
    try testing.expectEqualStrings(rfc8037.payload, &payload);

    // Through a Verifier the header comes first, and it has no "typ"; the
    // payload is text, not claims.
    try expectWrongType(rfc8037.token, &keys, "orders");

    // A.3, the thumbprint of a JWK, and A.6 and A.7, ECDH-ES with X25519
    // and X448, do not apply: zefir-jwt reads no JWK and agrees on no keys.
}
