//! A key that verifies the tokens of one algorithm: an HMAC secret, or
//! the public key of EC or Ed25519. A plain value of a fixed size without
//! heap memory, so a verifier takes its keys as an array built from the
//! settings. A copy of a secret is a secret too: keep a key in one place,
//! pass a pointer, and call `deinit` when it is no longer used.

const Key = @This();

const std = @import("std");
const root = @import("root.zig");
const crypto = @import("crypto.zig");
const pem = @import("pem.zig");
const pkcs = @import("pkcs.zig");
const KeyId = @import("KeyId.zig");
const isHmac = @import("algorithm.zig").isHmac;

const Algorithm = root.Algorithm;
const KeyError = root.KeyError;
const KeyOptions = root.KeyOptions;

/// The algorithm of every token the key verifies (RFC 8725 §3.1): never
/// the "alg" a token names.
algorithm: Algorithm,
/// Internal; `id` reads it.
key_id: KeyId,
/// Internal: the key material, in a bare union, which `{any}` prints as
/// `.{ ... }`.
material: Material,

const Material = union {
    hmac: crypto.HmacSecret,
    p256: std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey,
    p384: std.crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey,
    ed25519: std.crypto.sign.Ed25519.PublicKey,
};

/// zefir-log writes a key as "[REDACTED]".
pub const zefir_sensitive = true;

/// A key of HS256, HS384 or HS512 with `secret` from the settings, at
/// least as long as the hash: 32, 48 or 64 bytes. The key keeps a copy of
/// what it needs, so the settings may be freed.
pub fn hmac(algorithm: Algorithm, secret: []const u8, options: KeyOptions) KeyError!Key {
    return .{
        .algorithm = algorithm,
        .material = .{ .hmac = try .init(algorithm, secret) },
        .key_id = try .init(options.id),
    };
}

/// The public key of ES256 (P-256), ES384 (P-384) or EdDSA (Ed25519) in
/// the PEM of a "PUBLIC KEY" block, as `openssl pkey -pubout` writes it.
/// The PEM may come as the settings hold it: with CRLF, indented, or on one
/// line. `InvalidKey`: no such block, or one that is broken; a private key
/// is no key here. `UnsupportedKey`: RSA, P-521, Ed448, a certificate and
/// the rest of what zefir-jwt does not take. `KeyAlgorithmMismatch`: the
/// key is of another algorithm than `algorithm`, or `algorithm` is HMAC.
pub fn fromPem(algorithm: Algorithm, text: []const u8, options: KeyOptions) KeyError!Key {
    if (isHmac(algorithm)) return error.KeyAlgorithmMismatch;
    var der: [pem.max_der_bytes]u8 = undefined;
    const block = try pem.decode(&der, text, &.{.public_key});
    return fromDer(algorithm, block.der, options);
}

/// The public key of `fromPem` in DER: an SPKI.
pub fn fromDer(algorithm: Algorithm, der: []const u8, options: KeyOptions) KeyError!Key {
    const key_id: KeyId = try .init(options.id);
    const public = try pkcs.publicKey(algorithm, der);
    return .{
        .algorithm = algorithm,
        .key_id = key_id,
        .material = switch (public) {
            .p256 => |*key| .{ .p256 = key.* },
            .p384 => |*key| .{ .p384 = key.* },
            .ed25519 => |*key| .{ .ed25519 = key.* },
        },
    };
}

/// The key id, "kid"; null for a key without one.
pub fn id(key: *const Key) ?[]const u8 {
    return key.key_id.get();
}

/// `jwt.Key(EdDSA, kid "2026-10")`, or `jwt.Key(HS256)` for a key without
/// an id: never the key material.
pub fn format(key: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("jwt.Key({s}", .{key.algorithm.name()});
    if (key.id()) |kid| try w.print(", kid \"{s}\"", .{kid});
    try w.writeByte(')');
}

/// Wipes the whole key with `std.crypto.secureZero`; there is nothing to
/// free. A verifier that holds the key must not be used afterwards.
pub fn deinit(key: *Key) void {
    std.crypto.secureZero(u8, std.mem.asBytes(key));
}

const testing = std.testing;
const SigningKey = @import("SigningKey.zig");

const secret_64: *const [64]u8 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "a secret shorter than the hash is WeakKey" {
    inline for (.{ Key, SigningKey }) |K| {
        for ([_]struct { Algorithm, usize }{ .{ .HS256, 32 }, .{ .HS384, 48 }, .{ .HS512, 64 } }) |row| {
            try testing.expectError(error.WeakKey, K.hmac(row[0], secret_64[0 .. row[1] - 1], .{}));
            var key = try K.hmac(row[0], secret_64[0..row[1]], .{});
            defer key.deinit();
            try testing.expectEqual(row[0], key.algorithm);
        }
    }
}

test "hmac takes only the HS algorithms" {
    inline for (.{ Key, SigningKey }) |K| {
        for ([_]Algorithm{ .ES256, .ES384, .EdDSA }) |alg| {
            try testing.expectError(error.KeyAlgorithmMismatch, K.hmac(alg, secret_64, .{}));
        }
    }
}

test "a key id is 1 to 128 bytes of visible ASCII" {
    const longest: [128]u8 = @splat('a');
    const too_long: [129]u8 = @splat('a');
    inline for (.{ Key, SigningKey }) |K| {
        for ([_][]const u8{ "", &too_long, "a b", "a\x7f", "\xd0\xba", "a\tb" }) |bad| {
            try testing.expectError(error.InvalidKeyId, K.hmac(.HS256, secret_64, .{ .id = bad }));
        }
        var at_most = try K.hmac(.HS256, secret_64, .{ .id = &longest });
        defer at_most.deinit();
        try testing.expectEqualStrings(&longest, at_most.id().?);
        var named = try K.hmac(.HS256, secret_64, .{ .id = "2026-10" });
        defer named.deinit();
        try testing.expectEqualStrings("2026-10", named.id().?);
        var unnamed = try K.hmac(.HS256, secret_64, .{});
        defer unnamed.deinit();
        try testing.expectEqual(null, unnamed.id());
    }
}

test "format names the algorithm and the kid, never the secret" {
    var key: Key = try .hmac(.HS256, secret_64, .{ .id = "2026-10" });
    defer key.deinit();
    try testing.expectFmt("jwt.Key(HS256, kid \"2026-10\")", "{f}", .{key});
    var unnamed: Key = try .hmac(.HS256, secret_64, .{});
    defer unnamed.deinit();
    try testing.expectFmt("jwt.Key(HS256)", "{f}", .{unnamed});
    var signing: SigningKey = try .hmac(.HS512, secret_64, .{ .id = "a" });
    defer signing.deinit();
    try testing.expectFmt("jwt.SigningKey(HS512, kid \"a\")", "{f}", .{signing});

    const secret = "SECRET-SECRET-SECRET-SECRET-SECRET!";
    var visible: Key = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer visible.deinit();
    var visible_signing: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer visible_signing.deinit();
    const text = try std.fmt.allocPrint(testing.allocator, "{any} {any} {f} {f}", .{ visible, visible_signing, visible, visible_signing });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "SECRET") == null);
    // {any} would print bytes as numbers: what hides them is that std
    // prints a bare union as `.{ ... }`.
    try testing.expectEqual(2, std.mem.count(u8, text, ".material = .{ ... }"));
}

test "format and deinit hide and wipe EC and Ed25519 keys too" {
    for ([_]Algorithm{ .ES256, .ES384, .EdDSA }) |alg| {
        var a: SigningKey = try .generate(testing.io, alg, .{ .id = "2026-10" });
        var b: SigningKey = try .generate(testing.io, alg, .{ .id = "2026-10" });
        var key_a = a.verificationKey();
        var key_b = b.verificationKey();

        // Two keys with one id print the same: nothing of their material.
        const text_a = try std.fmt.allocPrint(testing.allocator, "{any} {any}", .{ a, key_a });
        defer testing.allocator.free(text_a);
        const text_b = try std.fmt.allocPrint(testing.allocator, "{any} {any}", .{ b, key_b });
        defer testing.allocator.free(text_b);
        try testing.expectEqualStrings(text_a, text_b);
        var buf: [64]u8 = undefined;
        try testing.expectFmt(try std.fmt.bufPrint(&buf, "jwt.SigningKey({t}, kid \"2026-10\")", .{alg}), "{f}", .{a});
        try testing.expectFmt(try std.fmt.bufPrint(&buf, "jwt.Key({t}, kid \"2026-10\")", .{alg}), "{f}", .{key_a});

        a.deinit();
        b.deinit();
        key_a.deinit();
        key_b.deinit();
        for (std.mem.asBytes(&a)) |byte| try testing.expectEqual(0, byte);
        for (std.mem.asBytes(&key_a)) |byte| try testing.expectEqual(0, byte);
    }
}

test "deinit zeroes the whole key" {
    var key: Key = try .hmac(.HS512, secret_64, .{ .id = "2026-10" });
    key.deinit();
    for (std.mem.asBytes(&key)) |byte| try testing.expectEqual(0, byte);
    var signing: SigningKey = try .hmac(.HS512, secret_64, .{ .id = "2026-10" });
    signing.deinit();
    for (std.mem.asBytes(&signing)) |byte| try testing.expectEqual(0, byte);
}
