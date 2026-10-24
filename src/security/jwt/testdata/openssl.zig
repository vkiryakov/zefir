//! A token that OpenSSL signed with ES384: a check of zefir-jwt's ES384
//! against another implementation, as RFC 7515 A.3 is one of ES256. The
//! key is keys/p384.pk8.pem. OpenSSL 3.6 signed the first two parts of the
//! token and wrote the signature in DER, which the token holds as r‖s:
//!
//! ```sh
//! printf '%s' "$SIGNING_INPUT" > input.txt
//! openssl dgst -sha384 -sign keys/p384.pk8.pem -out signature.der input.txt
//! openssl dgst -sha384 -verify keys/p384.pub.pem -signature signature.der input.txt
//! ```
//!
//! OpenSSL draws the nonce at random, and half of its signatures have the
//! high s that zefir-jwt refuses: this one has the low s.

/// The header `{"alg":"ES384","typ":"JWT"}` and the payload
/// `{"iss":"orders","sub":"user-7","aud":"orders","iat":1760000000,"exp":1760000900}`.
pub const es384_token = "eyJhbGciOiJFUzM4NCIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJvcmRlcnMiLCJzdWIiOiJ1c2VyLTciLCJhdWQiOiJvcmRlcnMiLCJpYXQiOjE3NjAwMDAwMDAsImV4cCI6MTc2MDAwMDkwMH0.VLmahIBDKP4YbAk27PvxswTijMa2ToVARnrP5HqY_o74Ew5XAS85mpHbCuQXzhGHMnD-Y_1ASwtxUhL2SwGuWLm8dK2QCFGprPwpVr0SJeX7PFc1GPqYIzg3qIN6kLjq";
/// signature.der, as OpenSSL wrote it, in hex.
pub const es384_der_hex = "3064023054b99a84804328fe186c0936ecfbf1b304e28cc6b64e8540467acfe47a98fe8ef8130e57012f399a91db0ae417ce118702303270fe63fd404b0b715212f64b01ae58b9bc74ad900851a9acfc2956bd1225e5fb3c573518fa98233837a8837a90b8ea";
