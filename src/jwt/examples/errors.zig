//! The error handler of the orders service: the one place where errors
//! become responses. Every 401 carries `WWW-Authenticate`, as RFC 9110
//! asks, with the reason when a token was refused (RFC 6750 §3).

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
            // jwt.Signer refuses only claims that no token can hold, such
            // as a string that is not UTF-8: a mistake of the program.
            error.InvalidClaims, error.TokenTooLarge => .{ .status = 500, .body = .{ .code = "internal", .message = "Internal Server Error" } },
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }

    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, _: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        if (err == error.Unauthenticated) try ctx.response.setHeader("www-authenticate", try auth.challenge(ctx));
        return .respond;
    }
};
