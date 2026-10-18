//! The error handler of the example app: the one place where errors become
//! responses. Handlers, middleware and the repository only return Zig
//! errors; `mapError` gives each one its status and body, and `handle`
//! adds what only the request knows.

const http = @import("http");
const v = @import("validator");

/// The body of every error response of this API, as `application/json`.
/// For the problem+json of RFC 9457, `mapError` returns
/// `http.ErrorResponse(http.Problem)` instead.
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
    /// The violations of a 422, each field by its outside name.
    details: []const http.Violation = &.{},
    /// The trace of the request, to find its records in the logs.
    trace_id: []const u8 = "",

    pub const field_rules = .{ .trace_id = v.rename("traceId") };
};

pub const AppErrors = struct {
    /// An error → its status and body. A pure function without a context:
    /// the compiler calls it while it builds the server, for every error a
    /// route can return (the strict error check).
    pub fn mapError(err: anyerror) http.ErrorResponse(ApiError) {
        return switch (err) {
            error.TodoNotFound => .{ .status = 404, .body = .{ .code = "todos.not_found", .message = "Todo not found" } },
            error.TodoLimitReached => .{ .status = 409, .body = .{ .code = "todos.limit_reached", .message = "The plan allows no more todos" } },
            error.ValidationFailed => .{ .status = 422, .body = .{ .code = "validation_failed", .message = "Invalid request" } },
            // Every other error: the framework's status, in this format.
            // `.fallback` marks the branch for the strict error check.
            else => .fallback(err, .{ .code = http.defaultCode(err), .message = http.defaultTitle(err) }),
        };
    }

    /// Optional: the trace id and the violations go into the body, and the
    /// header that every 401 needs into the response.
    pub fn handle(_: *AppErrors, ctx: *http.Context, err: anyerror, res: *http.ErrorResponse(ApiError)) !http.ErrorAction {
        res.body.trace_id = ctx.traceId();
        switch (err) {
            error.ValidationFailed => res.body.details = ctx.violations(),
            // RFC 9110 asks it of every 401.
            error.Unauthenticated => try ctx.response.setHeader("www-authenticate", "Bearer"),
            else => {},
        }
        return .respond;
    }
};
