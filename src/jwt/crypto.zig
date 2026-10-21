//! Signing and verification by the algorithm of a key. HMAC (RFC 7518
//! §3.2) compares its MAC in constant time and wipes its context on the
//! stack after use. ECDSA (RFC 7518 §3.4) signs with noise from the `Io`
//! and writes r‖s; Ed25519 (RFC 8037) signs deterministically and verifies
//! without the cofactor.

const std = @import("std");
const algorithm = @import("algorithm.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const KeyError = @import("errors.zig").KeyError;

const Algorithm = algorithm.Algorithm;
const hmac = std.crypto.auth.hmac.sha2;
const sha2 = std.crypto.hash.sha2;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const Ed25519 = std.crypto.sign.Ed25519;

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
        .ES256 => verifyEcdsa(EcdsaP256Sha256, &key.material.p256, signing_input, signature),
        .ES384 => verifyEcdsa(EcdsaP384Sha384, &key.material.p384, signing_input, signature),
        .EdDSA => verifyEd25519(&key.material.ed25519, signing_input, signature),
    };
}

/// Signs `signing_input` with `key` into `out` and returns the signature,
/// `signatureBytes(key.algorithm)` bytes of it. `io` gives the random
/// noise of ECDSA.
pub fn sign(key: *const SigningKey, io: std.Io, signing_input: []const u8, out: *[max_signature_bytes]u8) []const u8 {
    return switch (key.algorithm) {
        .HS256 => mac(hmac.HmacSha256, key.material.hmac.slice(), signing_input, out),
        .HS384 => mac(hmac.HmacSha384, key.material.hmac.slice(), signing_input, out),
        .HS512 => mac(hmac.HmacSha512, key.material.hmac.slice(), signing_input, out),
        .ES256 => signEcdsa(EcdsaP256Sha256, &key.material.p256, io, signing_input, out),
        .ES384 => signEcdsa(EcdsaP384Sha384, &key.material.p384, io, signing_input, out),
        .EdDSA => signEd25519(&key.material.ed25519, io, signing_input, out),
    };
}

/// r‖s, each of the curve's size (RFC 7518 §3.4), never DER. std refuses
/// an r or an s that is 0 or not below the order of the curve, which
/// stops the signature of CVE-2022-21449 (r = s = 0).
fn verifyEcdsa(comptime Scheme: type, public_key: *const Scheme.PublicKey, message: []const u8, signature: []const u8) error{BadSignature}!void {
    const length = Scheme.Signature.encoded_length;
    if (signature.len != length) return error.BadSignature;
    Scheme.Signature.fromBytes(signature[0..length].*).verify(message, public_key.*) catch return error.BadSignature;
}

/// `verifyStrict`: without the cofactor (RFC 8032 §5.1.7), and with s
/// below the order of the group; it never refuses an honest signature.
fn verifyEd25519(public_key: *const Ed25519.PublicKey, message: []const u8, signature: []const u8) error{BadSignature}!void {
    const length = Ed25519.Signature.encoded_length;
    if (signature.len != length) return error.BadSignature;
    Ed25519.Signature.fromBytes(signature[0..length].*).verifyStrict(message, public_key.*) catch return error.BadSignature;
}

/// Signs with fresh noise from `io`, as std advises against fault attacks;
/// std fails only for an r or an s of 0, and then fresh noise signs again.
fn signEcdsa(comptime Scheme: type, pair: *const Scheme.KeyPair, io: std.Io, message: []const u8, out: *[max_signature_bytes]u8) []const u8 {
    const length = Scheme.Signature.encoded_length;
    var noise: [Scheme.noise_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &noise);
    while (true) {
        io.random(&noise);
        const signature = pair.sign(message, noise) catch continue;
        out[0..length].* = signature.toBytes();
        return out[0..length];
    }
}

/// Signs deterministically, as RFC 8032 does, so one input gives one
/// signature. std fails only for a nonce of 0, which a hash does not give
/// in practice; then a signature with noise from `io` takes its place,
/// which verifies all the same.
fn signEd25519(pair: *const Ed25519.KeyPair, io: std.Io, message: []const u8, out: *[max_signature_bytes]u8) []const u8 {
    const length = Ed25519.Signature.encoded_length;
    var noise: ?[Ed25519.noise_length]u8 = null;
    defer if (noise) |*bytes| std.crypto.secureZero(u8, bytes);
    while (true) {
        const signature = pair.sign(message, noise) catch {
            noise = @as([Ed25519.noise_length]u8, undefined);
            io.random(&noise.?);
            continue;
        };
        out[0..length].* = signature.toBytes();
        return out[0..length];
    }
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

const Signer = @import("Signer.zig");
const Verifier = @import("Verifier.zig");
const FixedClock = @import("testing.zig").FixedClock;
const Details = @import("errors.zig").Details;
const keys = @import("testdata/keys.zig");

const every_algorithm = [_]Algorithm{ .HS256, .HS384, .HS512, .ES256, .ES384, .EdDSA };

test "ECDSA signatures carry noise, EdDSA ones do not" {
    var first: [max_signature_bytes]u8 = undefined;
    var second: [max_signature_bytes]u8 = undefined;
    for ([_]Algorithm{ .ES256, .ES384, .EdDSA }) |alg| {
        var signing: SigningKey = try .generate(testing.io, alg, .{});
        defer signing.deinit();
        var key = signing.verificationKey();
        defer key.deinit();
        const a = sign(&signing, testing.io, "header.payload", &first);
        const b = sign(&signing, testing.io, "header.payload", &second);
        try testing.expectEqual(algorithm.signatureBytes(alg), a.len);
        try verify(&key, "header.payload", a);
        try verify(&key, "header.payload", b);
        try testing.expectEqual(alg == .EdDSA, std.mem.eql(u8, a, b));
        try testing.expectError(error.BadSignature, verify(&key, "header.payloaD", a));
    }
}

const Roles = struct { roles: []const []const u8 = &.{} };

/// Signs a token with `signing` through a `Signer` and verifies it through
/// a `Verifier` with the verification key.
fn expectRoundTrip(signing: *const SigningKey, io: std.Io) !void {
    const signer: Signer = try .init(signing, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const token = try signer.sign(Roles, io, testing.allocator, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    defer testing.allocator.free(token);
    var own = [_]Key{signing.verificationKey()};
    defer own[0].deinit();
    const verifier: Verifier = try .init(.{ .keys = &own, .issuer = "orders", .audiences = &.{"orders"} });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const verified = try verifier.verify(Roles, io, arena_state.allocator(), token, .{});
    try testing.expectEqual(signing.algorithm, verified.header.algorithm);
    try testing.expectEqualStrings("user-7", verified.registered.subject.?);
    try testing.expectEqualStrings("buyer", verified.claims.roles[0]);
}

test "what sign issues, verify accepts, for all six algorithms" {
    var clock: FixedClock = try .init(testing.io, 1_760_000_000);
    defer clock.deinit();
    for (every_algorithm) |alg| {
        var generated: SigningKey = try .generate(testing.io, alg, .{ .id = "2026-10" });
        defer generated.deinit();
        try expectRoundTrip(&generated, clock.io());
    }
    for (keys.supported) |file| {
        if (file.part != .private) continue;
        errdefer std.debug.print("{s}\n", .{file.name});
        const alg = file.algorithm.?;
        var signing = try if (file.isPem()) SigningKey.fromPem(alg, file.bytes, .{}) else SigningKey.fromDer(alg, file.bytes, .{});
        defer signing.deinit();
        try expectRoundTrip(&signing, clock.io());
    }
}

test "HS256 under the kid of an EdDSA key, MACed with its public key, is AlgorithmMismatch" {
    var clock: FixedClock = try .init(testing.io, 1_760_000_000);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for ([_]Algorithm{ .EdDSA, .ES256 }) |alg| {
        var real: SigningKey = try .generate(testing.io, alg, .{ .id = "ed" });
        defer real.deinit();
        var own = [_]Key{real.verificationKey()};
        defer own[0].deinit();
        const verifier: Verifier = try .init(.{ .keys = &own, .issuer = "orders", .audiences = &.{"orders"} });

        // The attacker has the public key and takes its bytes as a secret.
        var public: [65]u8 = undefined;
        const secret: []const u8 = switch (alg) {
            .EdDSA => ed25519: {
                public[0..32].* = own[0].material.ed25519.toBytes();
                break :ed25519 public[0..32];
            },
            .ES256 => p256: {
                public = own[0].material.p256.toUncompressedSec1();
                break :p256 &public;
            },
            else => return error.TestUnexpectedResult,
        };
        var forger: SigningKey = try .hmac(.HS256, secret, .{ .id = "ed" });
        defer forger.deinit();
        const signer: Signer = try .init(&forger, .{ .issuer = "orders", .audiences = &.{"orders"} });
        const token = try signer.sign(void, clock.io(), testing.allocator, &{}, .{});
        defer testing.allocator.free(token);
        var details: Details = .{};
        try testing.expectError(error.AlgorithmMismatch, verifier.verify(void, clock.io(), arena_state.allocator(), token, .{ .details = &details }));
        try testing.expectEqualStrings("alg", details.claim.?);
    }
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
