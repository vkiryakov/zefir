// Application code (src/auth.zig of the orders service): zefir-jwt ships none of these.
//! The authentication of the orders service, made of ordinary middleware.
//! `JwtAuth` sits in the server's middleware and checks the token of
//! `Authorization: Bearer` on every request: a token of orders puts its
//! user into `ctx.locals`, and a request without a token goes on as
//! anonymous. So does one with a token that does not pass, but with the
//! reason kept for the answer. `requireUser` sits in the middleware of the
//! controllers that need a user, and answers 401 with that reason.
//!
//! ```zig
//! // main: the server's middleware, for every request
//! .middleware = .{&jwt_auth},
//! // a protected controller
//! .middleware = .{auth.requireUser},
//! // a handler
//! const user = try ctx.local(auth.CurrentUser);
//! ```

const std = @import("std");
const http = @import("http");
const jwt = @import("security").jwt;
const log = @import("log");
const v = @import("validator");

/// The claims of the tokens of orders, besides the registered ones that
/// jwt sets and checks itself.
pub const Claims = struct {
    /// What the user may do, such as "buyer".
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

/// The signed-in user of a request, as `JwtAuth` puts it into
/// `ctx.locals`.
pub const CurrentUser = struct {
    /// "sub" of the token.
    id: []const u8,
    roles: []const []const u8,
};

/// Why `JwtAuth` refused the token of a request, for the 401 of
/// `requireUser`.
pub const Refusal = struct { reason: jwt.VerifyError };

/// Checks the bearer token of every request with the verifier of orders.
pub const JwtAuth = struct {
    /// Borrowed: it lives as long as the server.
    verifier: *const jwt.Verifier,
    logger: log.Logger,

    pub fn run(self: *JwtAuth, ctx: *http.Context) !http.MiddlewareResult {
        const token = bearer(ctx.request.header("authorization")) orelse return .next;
        var details: jwt.Details = .{};
        const verified = self.verifier.verify(Claims, ctx.io(), ctx.allocator(), token, .{ .details = &details }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.refuse(ctx, err, &details);
        };
        // orders signs the token of every user with "sub".
        const id = verified.registered.subject orelse return self.refuse(ctx, error.MissingClaim, &.{ .claim = "sub" });
        try ctx.locals.put(CurrentUser, .{ .id = id, .roles = verified.claims.roles });
        return .next;
    }

    /// Logs why the token is refused and keeps the reason for the answer.
    /// The request goes on without a user: a route that needs none, such
    /// as the sign-in, still serves an app that holds an expired token, and
    /// `requireUser` answers the others with 401.
    fn refuse(self: *JwtAuth, ctx: *http.Context, reason: jwt.VerifyError, details: *const jwt.Details) !http.MiddlewareResult {
        // What the refusal was about, never the token: it is a credential.
        self.logger.warn("Token refused", .{ .reason = reason, .claim = details.claim, .violation = details.violation });
        try ctx.locals.put(Refusal, .{ .reason = reason });
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

/// 401 without a signed-in user: `error.Unauthenticated`, which the
/// framework answers with 401, and `challenge` with the reason when
/// `JwtAuth` refused a token. A wrong token never passes as a user.
pub fn requireUser(ctx: *http.Context) !http.MiddlewareResult {
    _ = ctx.locals.get(CurrentUser) orelse return error.Unauthenticated;
    return .next;
}

/// The value of `WWW-Authenticate` for the 401 of `requireUser`, as RFC
/// 6750 §3 has it: `Bearer` when the request brought no token, and with
/// `error="invalid_token"` and the reason when `JwtAuth` refused one. The
/// texts of `jwt.describe` stand between quotes as they are.
pub fn challenge(ctx: *http.Context) ![]const u8 {
    const refusal = ctx.locals.get(Refusal) orelse return "Bearer";
    return std.fmt.allocPrint(ctx.allocator(), "Bearer error=\"invalid_token\", error_description=\"{s}\"", .{jwt.describe(refusal.reason)});
}
