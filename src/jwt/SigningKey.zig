//! A key that signs the tokens of one algorithm: an HMAC secret, or the
//! private key of EC or Ed25519. A plain value of a fixed size without
//! heap memory; the same advice as for `jwt.Key` holds, more so: keep it
//! in one place, pass a pointer, and call `deinit` when it is no longer
//! used.

const SigningKey = @This();

const std = @import("std");
const root = @import("root.zig");
const crypto = @import("crypto.zig");
const pem = @import("pem.zig");
const pkcs = @import("pkcs.zig");
const Key = @import("Key.zig");
const KeyId = @import("KeyId.zig");
const isHmac = @import("algorithm.zig").isHmac;

const Algorithm = root.Algorithm;
const KeyError = root.KeyError;
const KeyOptions = root.KeyOptions;

/// The algorithm of every token the key signs; the "alg" of their header.
algorithm: Algorithm,
/// Internal; `id` reads it.
key_id: KeyId,
/// Internal: the key material, in a bare union, which `{any}` prints as
/// `.{ ... }`.
material: Material,

const Material = union {
    hmac: crypto.HmacSecret,
    p256: std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
    p384: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    ed25519: std.crypto.sign.Ed25519.KeyPair,
};

/// zefir-log writes a key as "[REDACTED]".
pub const zefir_sensitive = true;

/// A key of HS256, HS384 or HS512 with `secret` from the settings, at
/// least as long as the hash: 32, 48 or 64 bytes. The key keeps a copy of
/// what it needs, so the settings may be freed.
pub fn hmac(algorithm: Algorithm, secret: []const u8, options: KeyOptions) KeyError!SigningKey {
    return .{
        .algorithm = algorithm,
        .material = .{ .hmac = try .init(algorithm, secret) },
        .key_id = try .init(options.id),
    };
}

/// The private key of ES256 (P-256), ES384 (P-384) or EdDSA (Ed25519) in
/// the PEM of a "PRIVATE KEY" (PKCS#8) or an "EC PRIVATE KEY" (SEC1) block,
/// as `openssl genpkey` and `openssl ecparam -genkey` write them. The PEM
/// may come as the settings hold it: with CRLF, indented, or on one line;
/// the key keeps a copy of what it needs, and its buffers are wiped. The
/// errors are those of `Key.fromPem`; a public key is no signing key, and
/// an encrypted one is `UnsupportedKey`.
pub fn fromPem(algorithm: Algorithm, text: []const u8, options: KeyOptions) KeyError!SigningKey {
    if (isHmac(algorithm)) return error.KeyAlgorithmMismatch;
    var der: [pem.max_der_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &der);
    const block = try pem.decode(&der, text, &.{ .private_key, .ec_private_key });
    return fromDer(algorithm, block.der, options);
}

/// The private key of `fromPem` in DER: PKCS#8 or SEC1.
pub fn fromDer(algorithm: Algorithm, der: []const u8, options: KeyOptions) KeyError!SigningKey {
    // The id first: nothing may fail once the key is in the result.
    const key_id: KeyId = try .init(options.id);
    var private = try pkcs.privateKey(algorithm, der);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&private));
    return .{
        .algorithm = algorithm,
        .key_id = key_id,
        .material = switch (private) {
            .p256 => |*pair| .{ .p256 = pair.* },
            .p384 => |*pair| .{ .p384 = pair.* },
            .ed25519 => |*pair| .{ .ed25519 = pair.* },
        },
    };
}

/// The key id, "kid", which the header of every token it signs carries;
/// null for a key without one.
pub fn id(key: *const SigningKey) ?[]const u8 {
    return key.key_id.get();
}

/// The key that verifies what this one signs, with the same algorithm and
/// id: the public part of the key, or for HMAC the same secret, which is
/// then a secret too.
pub fn verificationKey(key: *const SigningKey) Key {
    return .{
        .algorithm = key.algorithm,
        .key_id = key.key_id,
        .material = switch (key.algorithm) {
            .HS256, .HS384, .HS512 => .{ .hmac = key.material.hmac },
            .ES256 => .{ .p256 = key.material.p256.public_key },
            .ES384 => .{ .p384 = key.material.p384.public_key },
            .EdDSA => .{ .ed25519 = key.material.ed25519.public_key },
        },
    };
}

/// `jwt.SigningKey(EdDSA, kid "2026-10")`, or `jwt.SigningKey(HS256)` for
/// a key without an id: never the key material.
pub fn format(key: SigningKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("jwt.SigningKey({s}", .{key.algorithm.name()});
    if (key.id()) |kid| try w.print(", kid \"{s}\"", .{kid});
    try w.writeByte(')');
}

/// Wipes the whole key with `std.crypto.secureZero`; there is nothing to
/// free. A signer that holds the key must not be used afterwards.
pub fn deinit(key: *SigningKey) void {
    std.crypto.secureZero(u8, std.mem.asBytes(key));
}

const testing = std.testing;

test "the verification key of an HMAC signing key keeps its algorithm and id" {
    var signing: SigningKey = try .hmac(.HS384, "0123456789abcdef0123456789abcdef0123456789abcdef", .{ .id = "2026-10" });
    defer signing.deinit();
    var key = signing.verificationKey();
    defer key.deinit();
    try testing.expectEqual(.HS384, key.algorithm);
    try testing.expectEqualStrings("2026-10", key.id().?);
}
