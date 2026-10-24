//! Vectors of RFC 8037 (CFRG Elliptic Curve Diffie-Hellman and
//! Signatures in JOSE), Appendix A, copied from
//! https://www.rfc-editor.org/rfc/rfc8037.txt without the line breaks the
//! RFC adds for display. The key is the one of RFC 8032 §7.1, TEST 1.

/// A.1: "d" of the JWK of the Ed25519 private key, the seed, in base64url.
pub const d = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A";
/// A.1 and A.2: "x", the public key, in base64url.
pub const x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";
/// A.1: the hexadecimal dump of the private key.
pub const d_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
/// A.1: the hexadecimal dump of the public key.
pub const x_hex = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";

/// A.4: the JWS of `payload` signed with the key; the header is
/// `{"alg":"EdDSA"}`, without "typ".
pub const token = "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc.hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg";
/// A.4: the payload, text and not JSON.
pub const payload = "Example of Ed25519 signing";
/// A.4: the signature in hex.
pub const signature_hex = "860c98d2297f3060a33f42739672d61b53cf3adefed3d3c672f320dc021b411e9d59b8628dc351e248b88b29468e0e41855b0fb7d83bb15be902bfccb8cd0a02";
