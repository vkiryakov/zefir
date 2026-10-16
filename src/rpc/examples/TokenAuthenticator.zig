//! The authenticator of the users service: who calls. It checks the bearer
//! token of a call against the tokens of its settings and gives the caller
//! an identity with permissions. A real one verifies a signed token (a
//! JWT) or asks a store of sessions; its shape stays the same.

const std = @import("std");
const confy = @import("confy");
const rpc = @import("rpc");

const TokenAuthenticator = @This();

/// The token of the admin console, which may change users.
admin_token: confy.Secret,
/// The token of the reporting job, which may only read them.
reporting_token: confy.Secret,

pub fn authenticate(self: *TokenAuthenticator, ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView {
    return switch (ctx.credentials) {
        // No credentials: an anonymous call, which a method with
        // `.auth = .required` refuses.
        .none => null,
        .bearer => |token| {
            if (sameToken(token, self.admin_token.expose())) {
                return .{ .subject = "admin", .permissions = &.{ "users.write", "users.delete" } };
            }
            if (sameToken(token, self.reporting_token.expose())) return .{ .subject = "reporting" };
            // Wrong credentials never pass as anonymous ones.
            return error.InvalidCredentials;
        },
        // Basic credentials or a scheme of another kind: this service takes none.
        else => error.InvalidCredentials,
    };
}

/// Compares the tokens in a time that does not depend on where they
/// differ, so that a caller cannot guess a token byte by byte.
fn sameToken(given: []const u8, expected: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(given, &a, .{});
    Sha256.hash(expected, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}
