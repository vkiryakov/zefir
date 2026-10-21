//! The errors of zefir-jwt, one per reason, and `Details`, which says
//! what a refusal of `verify` was about.

const std = @import("std");
const v = @import("validator");

/// Why a key did not load.
pub const KeyError = error{
    /// Not a key in the expected format: the PEM or DER is broken, cut
    /// short or of another kind.
    InvalidKey,
    /// A type or a curve that zefir-jwt does not take: RSA in any form,
    /// P-521, Ed448, an encrypted PEM, a certificate, an OpenSSH key.
    UnsupportedKey,
    /// Weaker than the algorithm requires: an HMAC secret shorter than
    /// the hash.
    WeakKey,
    /// The key does not fit the algorithm: P-384 for ES256, Ed25519 for
    /// ES256, a PEM for HS256, a secret for EdDSA.
    KeyAlgorithmMismatch,
    /// The key id is empty, longer than `max_key_id_bytes`, or holds a
    /// byte that is not visible ASCII.
    InvalidKeyId,
};

/// Why `Verifier.verify` refused a token, one error per reason. The
/// guide's middleware answers each with 401, and `OutOfMemory` with 500.
pub const VerifyError = error{
    /// The token is longer than `max_token_bytes`.
    TokenTooLarge,
    /// Not three parts; bad base64url or JSON; a key given twice; nesting
    /// deeper than `max_json_depth`; a member of the header of the wrong
    /// type.
    Malformed,
    /// "alg" is absent or names none of the six algorithms; "none" too.
    UnsupportedAlgorithm,
    /// The header has "crit", or "cty" says the payload is a nested token.
    UnsupportedHeader,
    /// "typ" is absent or none of the verifier's token types.
    WrongType,
    /// No key of the verifier has the token's "kid", or the token has no
    /// "kid" and the verifier more than one key.
    UnknownKey,
    /// The key of the token is bound to another algorithm than its "alg".
    AlgorithmMismatch,
    /// The signature does not verify.
    BadSignature,
    /// "exp", "iss" or "aud" is absent.
    MissingClaim,
    /// A registered claim of the wrong type or out of range, or a payload
    /// that does not fit the application's claims.
    InvalidClaims,
    /// "iss" is not the verifier's issuer.
    WrongIssuer,
    /// "aud" names none of the verifier's audiences.
    WrongAudience,
    /// The token has expired: now ≥ exp + leeway.
    Expired,
    /// "nbf" or "iat" lies in the future, past the leeway.
    NotYetValid,
    /// The claims break a rule of zefir-validator.
    ClaimsRejected,
    OutOfMemory,
};

/// Why `Signer.sign` issued no token.
pub const SignError = error{
    /// A string that is not UTF-8, a number that is not finite, or a time
    /// that a NumericDate cannot hold.
    InvalidClaims,
    /// The token would be longer than `max_token_bytes`: zefir issues no
    /// token that it would refuse itself.
    TokenTooLarge,
    OutOfMemory,
};

/// What a refusal of `verify` was about, for the response and the log.
/// It holds only static strings and paths by the names of the claims'
/// types: never bytes of the token, not even its "kid".
pub const Details = struct {
    /// The member of the header or the registered claim that the error is
    /// about: "alg", "typ", "kid", "exp", "aud", ...; null when there is
    /// none.
    claim: ?[]const u8 = null,
    /// For `InvalidClaims` from the application's claims and for
    /// `ClaimsRejected`; its path lives in `path_buf`.
    violation: ?v.Violation = null,
    path_buf: [256]u8 = undefined,
};

/// A short English text of why `verify` refused a token, for the
/// `error_description` of `WWW-Authenticate: Bearer` (RFC 6750 §3): ASCII
/// without '"' and '\', such as "the token has expired".
pub fn describe(err: VerifyError) []const u8 {
    return switch (err) {
        error.TokenTooLarge => "the token is too large",
        error.Malformed => "the token is malformed",
        error.UnsupportedAlgorithm => "the token's algorithm is not supported",
        error.UnsupportedHeader => "the token's header asks for what is not supported",
        error.WrongType => "the token is of another type",
        error.UnknownKey => "the token's key is unknown",
        error.AlgorithmMismatch => "the token's algorithm does not fit its key",
        error.BadSignature => "the token's signature is invalid",
        error.MissingClaim => "the token lacks a required claim",
        error.InvalidClaims => "the token's claims are invalid",
        error.WrongIssuer => "the token is from another issuer",
        error.WrongAudience => "the token is not meant for this service",
        error.Expired => "the token has expired",
        error.NotYetValid => "the token is not valid yet",
        error.ClaimsRejected => "the token's claims are not accepted",
        error.OutOfMemory => "the server ran out of memory",
    };
}

const testing = std.testing;

fn names(comptime E: type) usize {
    return @typeInfo(E).error_set.error_names.?.len;
}

test "the error sets hold one name per reason" {
    try testing.expectEqual(5, names(KeyError));
    try testing.expectEqual(16, names(VerifyError));
    try testing.expectEqual(3, names(SignError));
    // What sign refuses, verify would refuse too.
    const refused: VerifyError = @as(SignError, error.InvalidClaims);
    try testing.expectEqual(error.InvalidClaims, refused);
}

test "describe gives every error a short text for error_description" {
    inline for (@typeInfo(VerifyError).error_set.error_names.?) |name| {
        const text = describe(@field(VerifyError, name));
        try testing.expect(text.len > 0);
        // RFC 6750 §3: error_description is %x20-21 / %x23-5B / %x5D-7E.
        for (text) |c| try testing.expect(c >= 0x20 and c <= 0x7e and c != '"' and c != '\\');
    }
    try testing.expectEqualStrings("the token has expired", describe(error.Expired));
}

test "a fresh Details names nothing" {
    const details: Details = .{};
    try testing.expectEqual(null, details.claim);
    try testing.expectEqual(null, details.violation);
}
