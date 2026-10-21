//! Signing and verification by the algorithm of a key. HMAC (RFC 7518
//! §3.2) compares its MAC in constant time and wipes its context on the
//! stack after use.

const std = @import("std");
const algorithm = @import("algorithm.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const KeyError = @import("errors.zig").KeyError;

const Algorithm = algorithm.Algorithm;
const hmac = std.crypto.auth.hmac.sha2;
const sha2 = std.crypto.hash.sha2;

/// The longest signature of the six algorithms: r‖s of ES384.
pub const max_signature_bytes = 96;

/// The secret of an HMAC key as HMAC itself uses it: a secret longer than
/// the block of the hash (64 bytes for HS256, 128 for HS384 and HS512) is
/// kept as its hash (RFC 2104 §2), so a key holds at most 128 bytes of it,
/// whatever the length of the secret.
pub const HmacSecret = struct {
    bytes: [128]u8,
    len: u8,

    /// The secret of `alg`. `WeakKey`: shorter than the hash (RFC 7518
    /// §3.2). `KeyAlgorithmMismatch`: `alg` takes no secret.
    pub fn init(alg: Algorithm, secret: []const u8) KeyError!HmacSecret {
        if (secret.len < algorithm.minSecretBytes(alg)) return error.WeakKey;
        return switch (alg) {
            .HS256 => store(sha2.Sha256, secret),
            .HS384 => store(sha2.Sha384, secret),
            .HS512 => store(sha2.Sha512, secret),
            .ES256, .ES384, .EdDSA => error.KeyAlgorithmMismatch,
        };
    }

    pub fn slice(secret: *const HmacSecret) []const u8 {
        return secret.bytes[0..secret.len];
    }

    fn store(comptime Hash: type, secret: []const u8) HmacSecret {
        var stored: HmacSecret = .{ .bytes = @splat(0), .len = 0 };
        if (secret.len > Hash.block_length) {
            Hash.hash(secret, stored.bytes[0..Hash.digest_length], .{});
            stored.len = Hash.digest_length;
        } else {
            @memcpy(stored.bytes[0..secret.len], secret);
            stored.len = @intCast(secret.len);
        }
        return stored;
    }
};

/// Checks `signature` over `signing_input` by the algorithm of `key`.
/// `BadSignature`: the signature has the wrong length or does not verify.
pub fn verify(key: *const Key, signing_input: []const u8, signature: []const u8) error{BadSignature}!void {
    return switch (key.algorithm) {
        .HS256 => verifyMac(hmac.HmacSha256, key.material.hmac.slice(), signing_input, signature),
        .HS384 => verifyMac(hmac.HmacSha384, key.material.hmac.slice(), signing_input, signature),
        .HS512 => verifyMac(hmac.HmacSha512, key.material.hmac.slice(), signing_input, signature),
        // Key.hmac makes the only keys there are: HMAC ones.
        .ES256, .ES384, .EdDSA => error.BadSignature,
    };
}

/// Signs `signing_input` with `key` into `out` and returns the signature,
/// `signatureBytes(key.algorithm)` bytes of it. `io` is for the random
/// noise of ECDSA.
pub fn sign(key: *const SigningKey, io: std.Io, signing_input: []const u8, out: *[max_signature_bytes]u8) []const u8 {
    _ = io;
    return switch (key.algorithm) {
        .HS256 => mac(hmac.HmacSha256, key.material.hmac.slice(), signing_input, out),
        .HS384 => mac(hmac.HmacSha384, key.material.hmac.slice(), signing_input, out),
        .HS512 => mac(hmac.HmacSha512, key.material.hmac.slice(), signing_input, out),
        // SigningKey.hmac makes the only signing keys there are: HMAC ones.
        .ES256, .ES384, .EdDSA => unreachable,
    };
}

fn mac(comptime H: type, secret: []const u8, message: []const u8, out: *[max_signature_bytes]u8) []const u8 {
    // The context holds the secret padded with a constant.
    var ctx = H.init(secret);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&ctx));
    ctx.update(message);
    ctx.final(out[0..H.mac_length]);
    return out[0..H.mac_length];
}

fn verifyMac(comptime H: type, secret: []const u8, message: []const u8, signature: []const u8) error{BadSignature}!void {
    if (signature.len != H.mac_length) return error.BadSignature;
    // The right MAC of the message: what a forger looks for.
    var expected: [max_signature_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &expected);
    const computed = mac(H, secret, message, &expected);
    if (!std.crypto.timing_safe.eql([H.mac_length]u8, computed[0..H.mac_length].*, signature[0..H.mac_length].*))
        return error.BadSignature;
}

const testing = std.testing;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

fn expectStdMac(comptime H: type, alg: Algorithm, secret: []const u8) !void {
    var key: SigningKey = try .hmac(alg, secret, .{});
    defer key.deinit();
    var expected: [H.mac_length]u8 = undefined;
    H.create(&expected, "abc", secret);
    var out: [max_signature_bytes]u8 = undefined;
    try testing.expectEqualSlices(u8, &expected, sign(&key, testing.io, "abc", &out));
}

test "HMAC agrees with std for secrets of any length" {
    var secret: [200]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 7 + 1);
    for ([_]usize{ 32, 64, 65, 200 }) |len| try expectStdMac(HmacSha256, .HS256, secret[0..len]);
    try expectStdMac(HmacSha384, .HS384, secret[0..129]);
    try expectStdMac(HmacSha512, .HS512, secret[0..200]);

    // A secret longer than the block of the hash is kept as its hash, as
    // HMAC uses it: a key never holds more than 128 bytes of it.
    var key: Key = try .hmac(.HS256, secret[0..65], .{});
    defer key.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret[0..65], &digest, .{});
    try testing.expectEqualSlices(u8, &digest, key.material.hmac.slice());
    var block: Key = try .hmac(.HS256, secret[0..64], .{});
    defer block.deinit();
    try testing.expectEqualSlices(u8, secret[0..64], block.material.hmac.slice());
}

test "verify takes only the right MAC" {
    const secret = "0123456789abcdef0123456789abcdef";
    var key: Key = try .hmac(.HS256, secret, .{});
    defer key.deinit();
    var right: [32]u8 = undefined;
    HmacSha256.create(&right, "abc", secret);
    try verify(&key, "abc", &right);
    try testing.expectError(error.BadSignature, verify(&key, "abd", &right));

    var flipped = right;
    flipped[31] ^= 0x01;
    try testing.expectError(error.BadSignature, verify(&key, "abc", &flipped));
    try testing.expectError(error.BadSignature, verify(&key, "abc", right[0..31]));
    const longer = right ++ [_]u8{0};
    try testing.expectError(error.BadSignature, verify(&key, "abc", &longer));
    try testing.expectError(error.BadSignature, verify(&key, "abc", ""));
}

test "the verification key of an HMAC signing key verifies what it signs" {
    inline for (.{ .HS256, .HS384, .HS512 }) |alg| {
        var signing: SigningKey = try .hmac(alg, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .{ .id = "k1" });
        defer signing.deinit();
        var key = signing.verificationKey();
        defer key.deinit();
        try testing.expectEqualStrings(signing.id().?, key.id().?);
        var out: [max_signature_bytes]u8 = undefined;
        const signature = sign(&signing, testing.io, "header.payload", &out);
        try testing.expectEqual(algorithm.signatureBytes(alg), signature.len);
        try verify(&key, "header.payload", signature);
    }
}
