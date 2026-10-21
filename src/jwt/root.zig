//! zefir-jwt: JSON Web Tokens of zefir services. A service signs its own
//! tokens with `jwt.Signer` after a login, and its routes and the other
//! services of the system check them with `jwt.Verifier`: the signature,
//! the issuer, the audience and the time. The algorithms are HS256, HS384,
//! HS512, ES256, ES384 and EdDSA (Ed25519), in the compact form only. The
//! keys come from the settings of the service: an HMAC secret, or an EC or
//! Ed25519 key in PEM or DER, chosen by `kid`. The application's claims
//! arrive in a struct of its own, checked by the rules of zefir-validator.
//!
//! ```zig
//! var key: jwt.SigningKey = try .fromPem(.EdDSA, config.auth.signing_key.expose(), .{ .id = "2026-10" });
//! defer key.deinit();
//! const signer: jwt.Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
//! const token = try signer.sign(Claims, io, gpa, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
//! const keys = [_]jwt.Key{key.verificationKey()};
//! const verifier: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });
//! const verified = try verifier.verify(Claims, io, arena, token, .{}); // verified.registered.subject, verified.claims.roles
//! ```
//!
//! The module has no network code, no tasks and no global state: `verify`
//! and `sign` take only the clock from `io` (and, for ECDSA, its random
//! noise), and the keys are plain values with a `deinit` that wipes them.

const std = @import("std");
const v = @import("validator");
const claims = @import("claims.zig");

/// The longest token, in bytes: `verify` refuses a longer one before it
/// reads anything else (`error.TokenTooLarge`), and `sign` never issues one.
pub const max_token_bytes = 8 * 1024;
/// The deepest nesting of objects and arrays in the header and in the
/// payload, the top object included: `{}` is 1. A deeper one is
/// `error.Malformed`.
pub const max_json_depth = 32;
/// The longest key id (`kid`), in bytes of visible ASCII.
pub const max_key_id_bytes = 128;

pub const Algorithm = @import("algorithm.zig").Algorithm;

const errors = @import("errors.zig");
pub const KeyError = errors.KeyError;
pub const VerifyError = errors.VerifyError;
pub const SignError = errors.SignError;
pub const Details = errors.Details;

pub const Header = @import("header.zig").Header;
pub const Registered = claims.Registered;
pub const describe = errors.describe;

/// What `Verifier.verify` gives for a token it accepts. Everything in it
/// lives in the arena of the call and nothing points into the token.
pub fn Verified(comptime Claims: type) type {
    return struct {
        header: Header,
        registered: Registered,
        /// The application's claims; `void` when the registered ones are
        /// enough.
        claims: Claims,
    };
}

pub const VerifyOptions = struct {
    /// Where `verify` says what a refusal was about, for the response and
    /// the log; `verify` clears it first, so one `Details` serves many
    /// calls.
    details: ?*Details = null,
};

pub const Verifier = @import("Verifier.zig");

pub const SignOptions = struct {
    /// "sub": whom the token is about, such as a user's id.
    subject: ?[]const u8 = null,
    /// "jti": the token's own id.
    id: ?[]const u8 = null,
    /// How long this token lives, instead of the signer's lifetime; at
    /// least one second.
    lifetime: ?std.Io.Duration = null,
    /// "nbf": the first second the token is valid, in seconds of Unix
    /// time.
    not_before: ?i64 = null,
};

pub const Signer = @import("Signer.zig");

pub const KeyOptions = struct {
    /// The key id, "kid": 1 to `max_key_id_bytes` bytes of visible ASCII,
    /// such as "2026-10"; null for a key without one.
    id: ?[]const u8 = null,
};
pub const Key = @import("Key.zig");
pub const SigningKey = @import("SigningKey.zig");

/// Test support: `jwt.testing.FixedClock`, the clock a test sets.
pub const testing = @import("testing.zig");

/// Checks at compile time that `Claims` can be the claims of `verify` and
/// `sign`: `void`, or a struct of the claim types, whose claim names are
/// its own (`claim_names`, `v.rename`) and whose rules fit their fields.
/// `verify` and `sign` run the same check; a test of the package that
/// declares the claims calls it, as `v.assertRules` for a DTO:
/// `test { comptime jwt.assertClaims(Claims); }`.
pub fn assertClaims(comptime Claims: type) void {
    comptime {
        claims.check(Claims);
        v.assertRules(Claims);
    }
}

test {
    _ = @import("algorithm.zig");
    _ = @import("base64url.zig");
    _ = @import("compact.zig");
    _ = @import("errors.zig");
    _ = @import("json.zig");
    _ = @import("header.zig");
    _ = @import("KeyId.zig");
    _ = @import("crypto.zig");
    _ = @import("Key.zig");
    _ = @import("SigningKey.zig");
    _ = @import("jws.zig");
    _ = @import("vectors_test.zig");
    _ = @import("claims.zig");
    _ = @import("testing.zig");
    _ = @import("Verifier.zig");
    _ = @import("Signer.zig");
    _ = @import("hostile_test.zig");
    _ = @import("concurrency_test.zig");
}

test "limits have their documented values" {
    try std.testing.expectEqual(8192, max_token_bytes);
    try std.testing.expectEqual(32, max_json_depth);
    try std.testing.expectEqual(128, max_key_id_bytes);
    const details: Details = .{};
    try std.testing.expectEqual(256, details.path_buf.len);
    try std.testing.expectEqual(253402300799, claims.max_numeric_date);
    const verifier: Verifier.Options = .{ .keys = &.{}, .issuer = "orders", .audiences = &.{"orders"} };
    try std.testing.expectEqual(60, verifier.leeway.toSeconds());
    try std.testing.expectEqual(1, verifier.token_types.len);
    try std.testing.expectEqualStrings("JWT", verifier.token_types[0]);
    const signer: Signer.Options = .{ .issuer = "orders", .audiences = &.{"orders"} };
    try std.testing.expectEqual(900, signer.lifetime.toSeconds());
    try std.testing.expectEqualStrings("JWT", signer.token_type);
}
