//! Vectors of RFC 7519 (JSON Web Token), copied from
//! https://www.rfc-editor.org/rfc/rfc7519.txt without the line breaks the
//! RFC adds for display.

/// §3.1: the example JWT, HS256 with the key of RFC 7515 A.1; the same
/// bytes as RFC 7515 A.1. Its claims have no "aud".
pub const s3_1_token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

/// §6.1: the example Unsecured JWT, `{"alg":"none"}` and an empty
/// signature; the same bytes as RFC 7515 A.5.
pub const s6_1_token = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.";
