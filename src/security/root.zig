//! zefir-security: the security of zefir services. It will hold
//! authentication, authorization, MFA/TOTP, WebAuthn, TLS integration,
//! CORS and rate limiting; for now it holds one part, `jwt`: the JSON Web
//! Tokens that a service signs and checks itself. The guide,
//! src/security/examples/README.md, follows two services that use it.

pub const jwt = @import("jwt/root.zig");

test {
    _ = jwt;
}
