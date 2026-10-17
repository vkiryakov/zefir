// Application code (src/auth.zig of the example app): zefir-http ships none of these.
//! The authentication of the example app, made of ordinary middleware.
//! `TokenAuth` sits in the server's middleware and puts the user of a
//! known token into `ctx.locals`; a request without one, or with a token
//! nobody has, goes on as anonymous. `requireUser` and
//! `requirePermission` sit in the middleware of the controllers that need
//! a user, and refuse the request with 401 and 403.
//!
//! ```zig
//! // main: the server's middleware, for every request
//! .middleware = .{ &token_auth },
//! // a protected controller
//! .middleware = .{ auth.requireUser, auth.requirePermission("todos") },
//! // a handler
//! const user = try ctx.local(auth.CurrentUser);
//! ```
//!
//! A real service verifies a signed token (a JWT) or asks a store of
//! sessions instead of a table; the shape of the middleware stays the same.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");

/// The signed-in user of a request, as `TokenAuth` puts it into
/// `ctx.locals`.
pub const CurrentUser = struct {
    id: []const u8,
    permissions: []const []const u8,

    pub fn has(user: CurrentUser, permission: []const u8) bool {
        for (user.permissions) |held| {
            if (std.mem.eql(u8, held, permission)) return true;
        }
        return false;
    }
};

/// Who is calling: the bearer token of `Authorization`, or the cookie
/// `session` (a browser's `EventSource` cannot send `Authorization`),
/// looked up in a table of tokens that comes from the settings.
pub const TokenAuth = struct {
    /// The tokens and their users; borrowed, they live as long as the
    /// server.
    users: []const User,

    pub const User = struct {
        /// From the settings, such as `APP_AUTH_ANN_TOKEN`; never logged.
        token: confy.Secret,
        id: []const u8,
        permissions: []const []const u8,
    };

    /// A known token puts its user into `ctx.locals`; no token, or one
    /// nobody has, goes on as anonymous: only `requireUser` refuses a
    /// request, and only where it stands, so an old cookie does not break
    /// the pages that need no user.
    pub fn run(self: *TokenAuth, ctx: *http.Context) !http.MiddlewareResult {
        const token = bearer(ctx.request.header("authorization")) orelse ctx.request.cookie("session") orelse return .next;
        for (self.users) |user| {
            if (!sameToken(token, user.token.expose())) continue;
            try ctx.locals.put(CurrentUser, .{ .id = user.id, .permissions = user.permissions });
            return .next;
        }
        return .next;
    }
};

/// The token of `Authorization: Bearer <token>`.
fn bearer(value: ?[]const u8) ?[]const u8 {
    const header = value orelse return null;
    const scheme = "bearer ";
    if (header.len <= scheme.len or !std.ascii.startsWithIgnoreCase(header, scheme)) return null;
    return header[scheme.len..];
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

/// 401 without a signed-in user: `error.Unauthenticated`, which the
/// framework answers with 401. The application's error handler adds
/// `WWW-Authenticate`, as RFC 9110 asks of every 401.
pub fn requireUser(ctx: *http.Context) !http.MiddlewareResult {
    _ = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
    return .next;
}

/// 403 without the permission: a type made at compile time for each
/// permission, with a name of its own, so that the log and the messages of
/// the build say `requirePermission(todos:delete)`.
pub fn requirePermission(comptime permission: []const u8) type {
    return struct {
        pub const name = "requirePermission(" ++ permission ++ ")";

        pub fn run(ctx: *http.Context) !http.MiddlewareResult {
            const user = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
            if (!user.has(permission)) return error.PermissionDenied;
            return .next;
        }
    };
}
