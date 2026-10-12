//! Redaction by field name: a field named like a secret is written as
//! "[REDACTED]", whatever its value. Decided at compile time, so it costs
//! nothing at run time.

const std = @import("std");

/// What a redacted value is written as.
pub const placeholder = "[REDACTED]";

/// Exact names, compared after lowercasing and dropping '_' and '-', so
/// `api_key`, `apiKey` and `API-KEY` are one name. A bare `token` is left
/// out on purpose: lexers and pagination use it.
const names = [_][]const u8{
    "password",   "passwd",      "secret",        "client_secret",
    "api_key",    "apikey",      "access_token",  "refresh_token",
    "id_token",   "auth_token",  "authorization", "cookie",
    "set_cookie", "private_key",
};

/// Whether a field called `name` is redacted. Every dot-separated segment
/// is checked, so `db.password` is redacted as a nested `password` would
/// be.
pub fn isSensitiveName(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    var segments = std.mem.splitScalar(u8, name, '.');
    while (segments.next()) |segment| {
        for (names) |sensitive| {
            if (sameName(segment, sensitive)) return true;
        }
    }
    return false;
}

/// Whether `segment` spells `sensitive` (lowercase) in any case, with or
/// without '_' and '-'.
fn sameName(segment: []const u8, sensitive: []const u8) bool {
    var a: usize = 0;
    var b: usize = 0;
    while (true) {
        while (a < segment.len and isSeparator(segment[a])) a += 1;
        while (b < sensitive.len and isSeparator(sensitive[b])) b += 1;
        if (a == segment.len or b == sensitive.len) return a == segment.len and b == sensitive.len;
        if (std.ascii.toLower(segment[a]) != sensitive[b]) return false;
        a += 1;
        b += 1;
    }
}

fn isSeparator(c: u8) bool {
    return c == '_' or c == '-';
}

test "secret names are redacted whatever their case or dashes" {
    try std.testing.expect(comptime isSensitiveName("password"));
    try std.testing.expect(comptime isSensitiveName("Api-Key"));
    try std.testing.expect(comptime isSensitiveName("APIKEY"));
    try std.testing.expect(comptime isSensitiveName("set-cookie"));
    try std.testing.expect(comptime isSensitiveName("private_key"));
}

test "any segment of a dotted name counts" {
    try std.testing.expect(comptime isSensitiveName("db.password"));
    try std.testing.expect(comptime isSensitiveName("http.authorization.scheme"));
}

test "camelCase and SCREAMING_CASE spellings count too" {
    inline for (.{ "apiKey", "accessToken", "refreshToken", "idToken", "authToken", "clientSecret", "privateKey", "setCookie", "API_KEY", "Pass-Word" }) |name| {
        try std.testing.expect(comptime isSensitiveName(name));
    }
}

test "similar names are written as they are" {
    try std.testing.expect(comptime !isSensitiveName("token"));
    try std.testing.expect(comptime !isSensitiveName("password_hash"));
    try std.testing.expect(comptime !isSensitiveName("passwords"));
    try std.testing.expect(comptime !isSensitiveName("user_id"));
}
