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

pub const KeyOptions = struct {
    /// The key id, "kid": 1 to `max_key_id_bytes` bytes of visible ASCII,
    /// such as "2026-10"; null for a key without one.
    id: ?[]const u8 = null,
};
pub const Key = @import("Key.zig");
pub const SigningKey = @import("SigningKey.zig");

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
}

test "limits have their documented values" {
    try std.testing.expectEqual(8192, max_token_bytes);
    try std.testing.expectEqual(32, max_json_depth);
    try std.testing.expectEqual(128, max_key_id_bytes);
    const details: Details = .{};
    try std.testing.expectEqual(256, details.path_buf.len);
}
