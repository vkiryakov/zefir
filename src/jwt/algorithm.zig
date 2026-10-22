//! The algorithms of zefir-jwt: `jwt.Algorithm` and the sizes that go
//! with each one.

const std = @import("std");

/// A signature algorithm of JWS (RFC 7518 §3.1, RFC 8037 §3.1). A key is
/// bound to one of them when it is loaded, and a token is checked by the
/// algorithm of its key, never by the "alg" it names.
pub const Algorithm = enum {
    HS256,
    HS384,
    HS512,
    ES256,
    ES384,
    EdDSA,

    /// The value of "alg": the name of the variant ("HS256", ..., "EdDSA").
    pub fn name(alg: Algorithm) []const u8 {
        return @tagName(alg);
    }

    /// The algorithm named `text`, compared exactly; null for "none",
    /// "RS256", "ES512", "Ed25519", "hs256" and every other name.
    pub fn fromName(text: []const u8) ?Algorithm {
        return std.meta.stringToEnum(Algorithm, text);
    }
};

/// The length of a signature of `alg`, in bytes: the MAC of HMAC, r‖s of
/// ECDSA (RFC 7518 §3.4), or an Ed25519 signature.
pub fn signatureBytes(alg: Algorithm) usize {
    return switch (alg) {
        .HS256 => 32,
        .HS384 => 48,
        .HS512 => 64,
        .ES256 => 64,
        .ES384 => 96,
        .EdDSA => 64,
    };
}

/// Whether `alg` takes a shared secret.
pub fn isHmac(alg: Algorithm) bool {
    return switch (alg) {
        .HS256, .HS384, .HS512 => true,
        .ES256, .ES384, .EdDSA => false,
    };
}

/// The shortest secret of an HMAC algorithm, in bytes: the size of its hash
/// (RFC 7518 §3.2). 0 for the algorithms without a secret.
pub fn minSecretBytes(alg: Algorithm) usize {
    return switch (alg) {
        .HS256 => 32,
        .HS384 => 48,
        .HS512 => 64,
        .ES256, .ES384, .EdDSA => 0,
    };
}

const testing = std.testing;

test "RFC 7518 §3.1: fromName knows the six names of zefir and nothing else" {
    for ([_]Algorithm{ .HS256, .HS384, .HS512, .ES256, .ES384, .EdDSA }) |alg| {
        try testing.expectEqual(alg, Algorithm.fromName(alg.name()).?);
    }
    try testing.expectEqualStrings("EdDSA", Algorithm.EdDSA.name());
    for ([_][]const u8{
        "none",  "None",  "NONE",    "RS256", "RS384", "RS512", "PS256",  "PS384",
        "PS512", "ES512", "Ed25519", "Ed448", "dir",   "hs256", "HS256 ", "",
    }) |text| {
        try testing.expectEqual(null, Algorithm.fromName(text));
    }
}

test "the sizes of signatures and secrets follow RFC 7518 and RFC 8037" {
    const expected = [_]struct { Algorithm, usize, bool, usize }{
        .{ .HS256, 32, true, 32 },
        .{ .HS384, 48, true, 48 },
        .{ .HS512, 64, true, 64 },
        .{ .ES256, 64, false, 0 },
        .{ .ES384, 96, false, 0 },
        .{ .EdDSA, 64, false, 0 },
    };
    for (expected) |row| {
        try testing.expectEqual(row[1], signatureBytes(row[0]));
        try testing.expectEqual(row[2], isHmac(row[0]));
        try testing.expectEqual(row[3], minSecretBytes(row[0]));
    }
}
