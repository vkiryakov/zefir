//! The key files of zefir-jwt in DER: SPKI for public keys (RFC 5280
//! §4.1.2.7, RFC 5480, RFC 8410), PKCS#8 (RFC 5958) and SEC1 (RFC 5915) for
//! private ones, each of P-256, P-384 or Ed25519. Every point and scalar is
//! checked before it becomes a key, and every public part of a private key
//! is computed from its secret, never read from the file.

const std = @import("std");
const der = @import("der.zig");
const algorithm = @import("algorithm.zig");
const KeyError = @import("errors.zig").KeyError;

const Algorithm = algorithm.Algorithm;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const Ed25519 = std.crypto.sign.Ed25519;

/// A public key of an SPKI.
pub const Public = union(enum) {
    p256: EcdsaP256Sha256.PublicKey,
    p384: EcdsaP384Sha384.PublicKey,
    ed25519: Ed25519.PublicKey,
};

/// A private key of a PKCS#8 or a SEC1, with its public key.
pub const Private = union(enum) {
    p256: EcdsaP256Sha256.KeyPair,
    p384: EcdsaP384Sha384.KeyPair,
    ed25519: Ed25519.KeyPair,
};

const Curve = enum { p256, p384, ed25519 };

const tag = struct {
    const integer = 0x02;
    const bit_string = 0x03;
    const octet_string = 0x04;
    const oid = 0x06;
    const sequence = 0x30;
    /// `[0]`: the attributes of PKCS#8, the curve of SEC1.
    const context_0 = 0xa0;
    /// `[1]`: the public key of SEC1.
    const context_1 = 0xa1;
    /// `[1] IMPLICIT BIT STRING`: the public key of PKCS#8 version 2.
    const context_1_primitive = 0x81;
};

/// The contents of the OIDs zefir-jwt takes. Any other algorithm or curve
/// is `UnsupportedKey`: rsaEncryption, RSASSA-PSS, secp521r1, Ed448,
/// X25519, X448 and the rest.
const oid = struct {
    const ec_public_key = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
    const prime256v1 = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
    const secp384r1 = [_]u8{ 0x2b, 0x81, 0x04, 0x00, 0x22 };
    const ed25519 = [_]u8{ 0x2b, 0x65, 0x70 };
};

/// The public key of the SPKI `bytes` for `alg`. `KeyAlgorithmMismatch`:
/// an HS algorithm, or a key of another one. `UnsupportedKey`: an algorithm
/// or a curve that zefir-jwt does not take. `InvalidKey`: anything else
/// that is not a key, such as a point off its curve or of small order.
pub fn publicKey(alg: Algorithm, bytes: []const u8) KeyError!Public {
    if (algorithm.isHmac(alg)) return error.KeyAlgorithmMismatch;
    const spki = try der.top(bytes, tag.sequence);
    var fields: der.Reader = .init(spki.body);
    const identifier = try fields.expect(tag.sequence);
    const key_bits = try fields.expect(tag.bit_string);
    if (!fields.done()) return error.InvalidKey;
    const curve = try curveOf(identifier.body, alg);
    // The first byte of a BIT STRING counts the unused bits of its last.
    if (key_bits.body.len == 0 or key_bits.body[0] != 0) return error.InvalidKey;
    const key = key_bits.body[1..];
    return switch (curve) {
        .p256 => .{ .p256 = try ecPublicKey(EcdsaP256Sha256, key) },
        .p384 => .{ .p384 = try ecPublicKey(EcdsaP384Sha384, key) },
        .ed25519 => .{ .ed25519 = try ed25519PublicKey(key) },
    };
}

/// The private key of the PKCS#8 or SEC1 `bytes` for `alg`, told apart by
/// their second field: an AlgorithmIdentifier or the private key. The
/// errors are those of `publicKey`.
pub fn privateKey(alg: Algorithm, bytes: []const u8) KeyError!Private {
    if (algorithm.isHmac(alg)) return error.KeyAlgorithmMismatch;
    const top = try der.top(bytes, tag.sequence);
    var fields: der.Reader = .init(top.body);
    const version = try fields.expect(tag.integer);
    const second = try fields.next() orelse return error.InvalidKey;
    return switch (second.tag) {
        tag.sequence => oneAsymmetricKey(alg, version, second, &fields),
        tag.octet_string => ecPrivateKey(alg, version, second, &fields, null),
        else => error.InvalidKey,
    };
}

/// PKCS#8 after its version and its AlgorithmIdentifier: the private key,
/// then the optional `[0]` attributes and `[1]` public key, which are
/// skipped.
fn oneAsymmetricKey(alg: Algorithm, version: der.Element, identifier: der.Element, fields: *der.Reader) KeyError!Private {
    // Version 1 (v1) or 2 (v2), written as 0 and 1.
    if (!isSmallInteger(version.body, 0) and !isSmallInteger(version.body, 1)) return error.InvalidKey;
    const curve = try curveOf(identifier.body, alg);
    const private_key = try fields.expect(tag.octet_string);
    var next = try fields.next();
    if (next != null and next.?.tag == tag.context_0) next = try fields.next();
    if (next != null and next.?.tag == tag.context_1_primitive) next = try fields.next();
    if (next != null) return error.InvalidKey;
    switch (curve) {
        .p256, .p384 => {
            const inner = try der.top(private_key.body, tag.sequence);
            var inner_fields: der.Reader = .init(inner.body);
            const inner_version = try inner_fields.expect(tag.integer);
            const scalar = try inner_fields.expect(tag.octet_string);
            return ecPrivateKey(alg, inner_version, scalar, &inner_fields, curve);
        },
        .ed25519 => {
            // RFC 8410: CurvePrivateKey, an OCTET STRING with the seed.
            const curve_private_key = try der.top(private_key.body, tag.octet_string);
            const seed_length = Ed25519.KeyPair.seed_length;
            if (curve_private_key.body.len != seed_length) return error.InvalidKey;
            var seed: [seed_length]u8 = curve_private_key.body[0..seed_length].*;
            defer std.crypto.secureZero(u8, &seed);
            return .{ .ed25519 = Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidKey };
        },
    }
}

/// ECPrivateKey after its version and its scalar: the optional `[0]` curve
/// and `[1]` public key; the public key is skipped. `outer` is the curve of
/// the PKCS#8 around it, which `[0]`, if there, must name too; SEC1 alone
/// has only `[0]` to name its curve.
fn ecPrivateKey(alg: Algorithm, version: der.Element, scalar: der.Element, fields: *der.Reader, outer: ?Curve) KeyError!Private {
    if (!isSmallInteger(version.body, 1)) return error.InvalidKey;
    var named: ?Curve = null;
    var next = try fields.next();
    if (next != null and next.?.tag == tag.context_0) {
        named = try namedCurve(next.?.body);
        next = try fields.next();
    }
    if (next != null and next.?.tag == tag.context_1) next = try fields.next();
    if (next != null) return error.InvalidKey;
    const curve = outer orelse named orelse return error.InvalidKey;
    if (outer != null) {
        if (named != null and named.? != curve) return error.InvalidKey;
    } else try fits(curve, alg);
    return switch (curve) {
        .p256 => .{ .p256 = try ecKeyPair(EcdsaP256Sha256, scalar.body) },
        .p384 => .{ .p384 = try ecKeyPair(EcdsaP384Sha384, scalar.body) },
        .ed25519 => error.InvalidKey,
    };
}

/// The curve of an AlgorithmIdentifier, which must fit `alg`.
fn curveOf(identifier: []const u8, alg: Algorithm) KeyError!Curve {
    var fields: der.Reader = .init(identifier);
    const algorithm_oid = try fields.expect(tag.oid);
    const curve: Curve = if (std.mem.eql(u8, algorithm_oid.body, &oid.ec_public_key)) ec: {
        // RFC 5480: the curve must be there.
        const parameters = try fields.next() orelse return error.InvalidKey;
        break :ec try curveNamed(parameters);
    } else if (std.mem.eql(u8, algorithm_oid.body, &oid.ed25519)) .ed25519 else return error.UnsupportedKey;
    // RFC 8410: Ed25519 has no parameters.
    if (!fields.done()) return error.InvalidKey;
    try fits(curve, alg);
    return curve;
}

/// The curve that the `[0]` of an ECPrivateKey holds.
fn namedCurve(body: []const u8) KeyError!Curve {
    var fields: der.Reader = .init(body);
    const parameters = try fields.next() orelse return error.InvalidKey;
    if (!fields.done()) return error.InvalidKey;
    return curveNamed(parameters);
}

/// ECParameters: zefir-jwt takes a curve named by its OID, P-256 or P-384,
/// and neither explicit parameters nor implicitCA.
fn curveNamed(parameters: der.Element) KeyError!Curve {
    if (parameters.tag != tag.oid) return error.UnsupportedKey;
    if (std.mem.eql(u8, parameters.body, &oid.prime256v1)) return .p256;
    if (std.mem.eql(u8, parameters.body, &oid.secp384r1)) return .p384;
    return error.UnsupportedKey;
}

fn fits(curve: Curve, alg: Algorithm) KeyError!void {
    const curve_alg: Algorithm = switch (curve) {
        .p256 => .ES256,
        .p384 => .ES384,
        .ed25519 => .EdDSA,
    };
    if (curve_alg != alg) return error.KeyAlgorithmMismatch;
}

fn isSmallInteger(body: []const u8, value: u8) bool {
    return body.len == 1 and body[0] == value;
}

/// A SEC1 point, uncompressed or compressed: on the curve and not the
/// identity.
fn ecPublicKey(comptime Scheme: type, sec1: []const u8) KeyError!Scheme.PublicKey {
    const key = Scheme.PublicKey.fromSec1(sec1) catch return error.InvalidKey;
    key.p.rejectIdentity() catch return error.InvalidKey;
    return key;
}

/// A scalar of exactly the curve's size, in 1…n−1, and the public key it
/// makes.
fn ecKeyPair(comptime Scheme: type, scalar: []const u8) KeyError!Scheme.KeyPair {
    const length = Scheme.SecretKey.encoded_length;
    if (scalar.len != length) return error.InvalidKey;
    var secret_key: Scheme.SecretKey = .{ .bytes = scalar[0..length].* };
    defer std.crypto.secureZero(u8, &secret_key.bytes);
    Scheme.Curve.scalar.rejectNonCanonical(secret_key.bytes, .big) catch return error.InvalidKey;
    if (std.mem.allEqual(u8, &secret_key.bytes, 0)) return error.InvalidKey;
    return Scheme.KeyPair.fromSecretKey(secret_key) catch error.InvalidKey;
}

/// 32 bytes of a canonical point that is not of small order.
fn ed25519PublicKey(bytes: []const u8) KeyError!Ed25519.PublicKey {
    const length = Ed25519.PublicKey.encoded_length;
    if (bytes.len != length) return error.InvalidKey;
    const key = Ed25519.PublicKey.fromBytes(bytes[0..length].*) catch return error.InvalidKey;
    const point = Ed25519.Curve.fromBytes(key.bytes) catch return error.InvalidKey;
    point.rejectLowOrder() catch return error.InvalidKey;
    return key;
}

const testing = std.testing;
const keys = @import("testdata/keys.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const KeyOptions = @import("root.zig").KeyOptions;
const crypto = @import("crypto.zig");

const tlv = keys.tlv;
const hex = keys.hex;
const every_algorithm = [_]Algorithm{ .HS256, .HS384, .HS512, .ES256, .ES384, .EdDSA };
const asymmetric = [_]Algorithm{ .ES256, .ES384, .EdDSA };

fn loadPublic(alg: Algorithm, file: keys.File, options: KeyOptions) KeyError!Key {
    return if (file.isPem()) Key.fromPem(alg, file.bytes, options) else Key.fromDer(alg, file.bytes, options);
}

fn loadPrivate(alg: Algorithm, file: keys.File, options: KeyOptions) KeyError!SigningKey {
    return if (file.isPem()) SigningKey.fromPem(alg, file.bytes, options) else SigningKey.fromDer(alg, file.bytes, options);
}

/// The verification key of `file`: the key itself or the public part of
/// the signing key.
fn verificationKeyOf(alg: Algorithm, file: keys.File, options: KeyOptions) KeyError!Key {
    switch (file.part) {
        .public => return loadPublic(alg, file, options),
        .private => {
            var signing = try loadPrivate(alg, file, options);
            defer signing.deinit();
            return signing.verificationKey();
        },
    }
}

/// The public key of `key`: the uncompressed SEC1 point of EC, the 32
/// bytes of Ed25519.
fn publicBytes(key: *const Key, buf: *[97]u8) ![]const u8 {
    switch (key.algorithm) {
        .ES256 => {
            buf[0..65].* = key.material.p256.toUncompressedSec1();
            return buf[0..65];
        },
        .ES384 => {
            buf[0..97].* = key.material.p384.toUncompressedSec1();
            return buf[0..97];
        },
        .EdDSA => {
            buf[0..32].* = key.material.ed25519.toBytes();
            return buf[0..32];
        },
        .HS256, .HS384, .HS512 => return error.TestUnexpectedResult,
    }
}

fn expectRefused(alg: Algorithm, bytes: []const u8, pem: bool, part: keys.Part, expected: KeyError) !void {
    errdefer std.debug.print("{t} key of {t} from {x}\n", .{ part, alg, bytes[0..@min(bytes.len, 48)] });
    const file: keys.File = .{ .name = if (pem) "test.pem" else "test.der", .bytes = bytes, .part = part, .algorithm = alg };
    switch (part) {
        .public => try testing.expectError(expected, loadPublic(alg, file, .{})),
        .private => try testing.expectError(expected, loadPrivate(alg, file, .{})),
    }
}

fn expectFileRefused(alg: Algorithm, file: keys.File, part: keys.Part, expected: KeyError) !void {
    errdefer std.debug.print("{s}\n", .{file.name});
    try expectRefused(alg, file.bytes, file.isPem(), part, expected);
}

test "5.8: every key file loads" {
    for (asymmetric) |alg| {
        // The files of one algorithm hold one key: every one of them
        // verifies what any private one signs.
        var verifiers: [keys.supported.len]Key = undefined;
        var count: usize = 0;
        defer for (verifiers[0..count]) |*key| key.deinit();
        for (keys.supported) |file| {
            if (file.algorithm.? != alg) continue;
            errdefer std.debug.print("{s}\n", .{file.name});
            verifiers[count] = try verificationKeyOf(alg, file, .{ .id = "2026-10" });
            count += 1;
            const key = &verifiers[count - 1];
            try testing.expectEqual(alg, key.algorithm);
            try testing.expectEqualStrings("2026-10", key.id().?);
            var first_buf: [97]u8 = undefined;
            var buf: [97]u8 = undefined;
            try testing.expectEqualSlices(u8, try publicBytes(&verifiers[0], &first_buf), try publicBytes(key, &buf));
        }
        for (keys.supported) |file| {
            if (file.algorithm.? != alg or file.part != .private) continue;
            errdefer std.debug.print("{s}\n", .{file.name});
            var signing = try loadPrivate(alg, file, .{});
            defer signing.deinit();
            var out: [crypto.max_signature_bytes]u8 = undefined;
            const signature = crypto.sign(&signing, testing.io, "abc", &out);
            for (verifiers[0..count]) |*key| try crypto.verify(key, "abc", signature);
        }
    }
}

test "UnsupportedKey: RSA in every form, P-521, Ed448, encrypted PEM, certificates and OpenSSH" {
    for (keys.unsupported) |file| {
        for (asymmetric) |alg| try expectFileRefused(alg, file, file.part, error.UnsupportedKey);
    }
}

test "KeyAlgorithmMismatch: the file and the algorithm disagree" {
    for (keys.supported) |file| {
        for (every_algorithm) |alg| {
            if (alg != file.algorithm.?) try expectFileRefused(alg, file, file.part, error.KeyAlgorithmMismatch);
        }
    }
    // HS* before anything is parsed.
    try testing.expectError(error.KeyAlgorithmMismatch, Key.fromPem(.HS256, "no PEM", .{}));
    try testing.expectError(error.KeyAlgorithmMismatch, SigningKey.fromDer(.HS512, "", .{}));
}

test "a public key file is no signing key, and the other way round" {
    for (keys.supported) |file| {
        const other: keys.Part = if (file.part == .public) .private else .public;
        try expectFileRefused(file.algorithm.?, file, other, error.InvalidKey);
    }
}

test "the key id of a key file" {
    const file = keys.get("ed25519.pub.pem");
    try testing.expectError(error.InvalidKeyId, Key.fromPem(.EdDSA, file.bytes, .{ .id = "" }));
    try testing.expectError(error.InvalidKeyId, SigningKey.fromPem(.EdDSA, keys.get("ed25519.pk8.pem").bytes, .{ .id = "a b" }));
    var key: Key = try .fromPem(.EdDSA, file.bytes, .{});
    defer key.deinit();
    try testing.expectEqual(null, key.id());
}

/// RFC 8032 §7.1, TEST 1: the seed and the public key of RFC 8037 A.1.
const rfc8032_seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
const rfc8032_public = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
const ed25519_id = tlv(0x30, tlv(0x06, hex("2b6570")));

fn expectEd25519(bytes: []const u8) !void {
    var signing: SigningKey = try .fromDer(.EdDSA, bytes, .{});
    defer signing.deinit();
    var key = signing.verificationKey();
    defer key.deinit();
    var buf: [97]u8 = undefined;
    try testing.expectEqualSlices(u8, rfc8032_public, try publicBytes(&key, &buf));
}

test "Ed25519 PKCS#8 of version 1 with its public key loads" {
    const private_key = comptime tlv(0x04, tlv(0x04, rfc8032_seed));
    try expectEd25519(comptime hex("3051020101300506032b657004220420") ++ rfc8032_seed ++ hex("812100") ++ rfc8032_public);
    // The public key of [1] is never used: it comes from the seed.
    try expectEd25519(comptime tlv(0x30, hex("020101") ++ ed25519_id ++ private_key ++ tlv(0x81, hex("00") ++ &@as([32]u8, @splat(0x55)))));
    // Nor are the attributes of [0].
    try expectEd25519(comptime tlv(0x30, hex("020100") ++ ed25519_id ++ private_key ++ tlv(0xa0, "")));
    try expectEd25519(comptime tlv(0x30, hex("020100") ++ ed25519_id ++ private_key));
}

/// A P-256 scalar: 1 < d < n.
const p256_scalar = &@as([32]u8, @splat(0x11));
const p256_oid = tlv(0x06, hex("2a8648ce3d030107"));
const p384_oid = tlv(0x06, hex("2b81040022"));
const ec_id_p256 = tlv(0x30, tlv(0x06, hex("2a8648ce3d0201")) ++ p256_oid);

test "decision 10: the fields of PKCS#8 and SEC1" {
    const sec1 = comptime tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, p256_oid));
    var loaded: SigningKey = try .fromDer(.ES256, sec1, .{});
    loaded.deinit();
    var wrapped: SigningKey = try .fromDer(.ES256, comptime tlv(0x30, hex("020100") ++ ec_id_p256 ++ tlv(0x04, sec1)), .{});
    wrapped.deinit();

    const refused = comptime [_]struct { []const u8, KeyError }{
        // SEC1: version 1, a scalar of the curve's size, the curve in [0].
        .{ tlv(0x30, hex("020100") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, p256_oid)), error.InvalidKey },
        .{ tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar)), error.InvalidKey },
        .{ tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar[0..31]) ++ tlv(0xa0, p256_oid)), error.InvalidKey },
        .{ tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, p384_oid)), error.KeyAlgorithmMismatch },
        .{ tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, p256_oid) ++ hex("0500")), error.InvalidKey },
        .{ tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, tlv(0x30, ""))), error.UnsupportedKey },
        // PKCS#8: version 0 or 1, and an inner curve that is the outer one.
        .{ tlv(0x30, hex("020102") ++ ec_id_p256 ++ tlv(0x04, sec1)), error.InvalidKey },
        .{ tlv(0x30, hex("020100") ++ ec_id_p256 ++ tlv(0x04, tlv(0x30, hex("020101") ++ tlv(0x04, p256_scalar) ++ tlv(0xa0, p384_oid)))), error.InvalidKey },
        .{ tlv(0x30, hex("020100") ++ ec_id_p256 ++ tlv(0x04, sec1) ++ hex("0500")), error.InvalidKey },
        .{ tlv(0x30, hex("020100") ++ ec_id_p256 ++ tlv(0x04, sec1[0 .. sec1.len - 1])), error.InvalidKey },
        // Ed25519: no parameters, and a seed of 32 bytes.
        .{ tlv(0x30, hex("020100") ++ tlv(0x30, tlv(0x06, hex("2b6570")) ++ hex("0500")) ++ tlv(0x04, tlv(0x04, rfc8032_seed))), error.InvalidKey },
        .{ tlv(0x30, hex("020100") ++ ed25519_id ++ tlv(0x04, tlv(0x04, rfc8032_seed[0..31]))), error.InvalidKey },
        .{ tlv(0x30, hex("020100") ++ ed25519_id ++ tlv(0x04, rfc8032_seed)), error.InvalidKey },
        // Neither PKCS#8 nor SEC1.
        .{ tlv(0x30, hex("020100") ++ hex("0500")), error.InvalidKey },
    };
    for (refused) |case| {
        const alg: Algorithm = if (std.mem.find(u8, case[0], comptime hex("2b6570")) != null) .EdDSA else .ES256;
        try expectRefused(alg, case[0], false, .private, case[1]);
    }
}

test "SPKI holds one key of a known algorithm" {
    const point = comptime keys.get("p256.pub.der").bytes[26..];
    const ed25519_x = comptime keys.get("ed25519.pub.der").bytes[12..];
    var p256: Key = try .fromDer(.ES256, comptime tlv(0x30, ec_id_p256 ++ tlv(0x03, hex("00") ++ point)), .{});
    p256.deinit();
    var ed25519: Key = try .fromDer(.EdDSA, comptime tlv(0x30, ed25519_id ++ tlv(0x03, hex("00") ++ ed25519_x)), .{});
    ed25519.deinit();

    const refused = comptime [_]struct { Algorithm, []const u8, KeyError }{
        // A BIT STRING with unused bits.
        .{ .ES256, tlv(0x30, ec_id_p256 ++ tlv(0x03, hex("01") ++ point)), error.InvalidKey },
        .{ .ES256, tlv(0x30, ec_id_p256 ++ tlv(0x03, "")), error.InvalidKey },
        // EC names its curve: explicit parameters and implicitCA are not taken.
        .{ .ES256, tlv(0x30, tlv(0x30, tlv(0x06, hex("2a8648ce3d0201"))) ++ tlv(0x03, hex("00") ++ point)), error.InvalidKey },
        .{ .ES256, tlv(0x30, tlv(0x30, tlv(0x06, hex("2a8648ce3d0201")) ++ tlv(0x30, "")) ++ tlv(0x03, hex("00") ++ point)), error.UnsupportedKey },
        .{ .ES256, tlv(0x30, tlv(0x30, tlv(0x06, hex("2a8648ce3d0201")) ++ hex("0500")) ++ tlv(0x03, hex("00") ++ point)), error.UnsupportedKey },
        .{ .ES256, tlv(0x30, tlv(0x30, tlv(0x06, hex("2a8648ce3d0201")) ++ p256_oid ++ hex("0500")) ++ tlv(0x03, hex("00") ++ point)), error.InvalidKey },
        // Ed25519 has no parameters and 32 bytes.
        .{ .EdDSA, tlv(0x30, tlv(0x30, tlv(0x06, hex("2b6570")) ++ hex("0500")) ++ tlv(0x03, hex("00") ++ ed25519_x)), error.InvalidKey },
        .{ .EdDSA, tlv(0x30, ed25519_id ++ tlv(0x03, hex("00") ++ ed25519_x[0..31])), error.InvalidKey },
        // X25519 and X448 agree on keys; they do not sign.
        .{ .EdDSA, tlv(0x30, tlv(0x30, tlv(0x06, hex("2b656e"))) ++ tlv(0x03, hex("00") ++ ed25519_x)), error.UnsupportedKey },
        .{ .EdDSA, tlv(0x30, tlv(0x30, tlv(0x06, hex("2b656f"))) ++ tlv(0x03, hex("00") ++ ed25519_x)), error.UnsupportedKey },
        // RSASSA-PSS.
        .{ .ES256, tlv(0x30, tlv(0x30, tlv(0x06, hex("2a864886f70d01010a")) ++ tlv(0x30, "")) ++ tlv(0x03, hex("00") ++ point)), error.UnsupportedKey },
        // The key's parts in another order, or one more.
        .{ .ES256, tlv(0x30, tlv(0x03, hex("00") ++ point) ++ ec_id_p256), error.InvalidKey },
        .{ .ES256, tlv(0x30, ec_id_p256 ++ tlv(0x03, hex("00") ++ point) ++ hex("0500")), error.InvalidKey },
    };
    for (refused) |case| try expectRefused(case[0], case[1], false, .public, case[2]);
}
