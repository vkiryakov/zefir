//! Redaction by field name: a field named like a secret is written as
//! "[REDACTED]", whatever its value. Decided at compile time, so it costs
//! nothing at run time.

const std = @import("std");

/// What a redacted value is written as.
pub const placeholder = "[REDACTED]";

/// Exact names, compared after lowercasing and mapping '-' to '_'. A bare
/// `token` is left out on purpose: lexers and pagination use it.
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

fn sameName(segment: []const u8, sensitive: []const u8) bool {
    if (segment.len != sensitive.len) return false;
    for (segment, sensitive) |a, b| {
        const normalized = if (a == '-') '_' else std.ascii.toLower(a);
        if (normalized != b) return false;
    }
    return true;
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

test "similar names are written as they are" {
    try std.testing.expect(comptime !isSensitiveName("token"));
    try std.testing.expect(comptime !isSensitiveName("password_hash"));
    try std.testing.expect(comptime !isSensitiveName("passwords"));
    try std.testing.expect(comptime !isSensitiveName("user_id"));
}
