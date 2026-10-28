// Application code (src/LoginController.zig of the orders service): zefir-security ships none of these.
//! Signing in: POST /api/login. A user sends a name and a secret, and the
//! answer is a token of orders, in the form that OAuth clients read (RFC
//! 6749 §5.1). zefir has no passwords: here the users and their secrets
//! come from the settings. A real service checks a password against its
//! hash in a store of users, or lets another system sign users in; the
//! token it gives then is made the same way.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const jwt = @import("security").jwt;
const v = @import("validator");
const auth = @import("auth.zig");

const LoginController = @This();

/// Signs the tokens; borrowed.
signer: *const jwt.Signer,
/// The users who may sign in; borrowed.
users: []const User,

pub const User = struct {
    /// The name a user signs in with.
    name: []const u8,
    /// From the settings, such as `APP_USERS_ANN`; never logged.
    secret: confy.Secret,
    /// The id of the user: "sub" of their tokens.
    id: []const u8,
    roles: []const []const u8,
};

pub const http_routes = http.routes(.{
    .methods = .{
        // A name and a secret: a small limit for the body.
        .login = http.post("/login", .{ .max_body_bytes = 1024 }),
    },
});

pub const LoginRequest = struct {
    user: []const u8,
    secret: []const u8,

    pub const field_rules = .{
        .user = .{ v.notBlank, v.maxLength(64) },
        .secret = .{ v.notEmpty, v.maxLength(256) },
    };
};

pub const LoginResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    /// How long the token lives, in seconds.
    expires_in: i64,
};

pub fn login(self: *LoginController, ctx: *http.Context) !http.Json(LoginResponse) {
    const body = try ctx.json(LoginRequest);
    // A wrong name or secret: a 401 of the sign-in's own (errors.zig),
    // whatever token the app still sends.
    const user = self.userOf(body.user, body.secret) orelse return error.InvalidCredentials;
    const token = try self.signer.sign(auth.Claims, ctx.io(), ctx.allocator(), &.{ .roles = user.roles }, .{ .subject = user.id });
    return .{ .value = .{ .access_token = token, .expires_in = self.signer.options.lifetime.toSeconds() } };
}

/// The user of `name` whose secret is `secret`; null for anybody else.
fn userOf(self: *const LoginController, name: []const u8, secret: []const u8) ?User {
    for (self.users) |user| {
        const same_secret = sameSecret(secret, user.secret.expose());
        if (same_secret and std.mem.eql(u8, user.name, name)) return user;
    }
    return null;
}

/// Compares the secrets in a time that does not depend on where they
/// differ, so that a caller cannot guess a secret byte by byte.
fn sameSecret(given: []const u8, expected: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var a: [Sha256.digest_length]u8 = undefined;
    var b: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(given, &a, .{});
    Sha256.hash(expected, &b, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, a, b);
}
