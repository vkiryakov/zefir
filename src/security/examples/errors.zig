// Application code (src/errors.zig of the orders service): zefir-security ships none of these.
//! The error handler of the orders service: the one place where errors
//! become responses. Every 401 carries `WWW-Authenticate`, as RFC 9110
//! asks: that of `requireUser` with the reason when a token was refused
//! (RFC 6750 §3), that of the sign-in without one.

const http = @import("http");
const auth = @import("auth.zig");

/// The body of every error response, as `application/json`.
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
};

pub const AppErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            // The sign-in's own refusal of a wrong name or secret.
            error.InvalidCredentials => .{ .status = 401, .body = .{ .code = "invalid_credentials", .message = "Wrong user or secret" } },
            // jwt.Signer refuses only what no token can hold, such as a
            // string that is not UTF-8, and a key that deinit wiped too
            // early: mistakes of the program.
            error.InvalidClaims, error.TokenTooLarge, error.BadSignature => .{ .status = 500, .body = .{ .code = "internal", .message = "Internal Server Error" } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }

    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, _: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        switch (err) {
            // requireUser found no user: the reason, if JwtAuth refused a token.
            error.Unauthenticated => try ctx.response.setHeader("www-authenticate", try auth.challenge(ctx)),
            // The sign-in refused the name or the secret: no reason of a
            // token here, even when the app still sends one.
            error.InvalidCredentials => try ctx.response.setHeader("www-authenticate", "Bearer"),
            else => {},
        }
        return .respond;
    }
};
