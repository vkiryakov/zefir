//! Errors and their responses (design section 11): the framework's own
//! errors, `http.Error`, the status, code and title of every error the
//! framework knows, and `http.Problem`, the body of RFC 9457 that answers
//! an error when the application has no error handler of its own.
const std = @import("std");
const Violation = @import("validator").Violation;

/// The framework's own errors, with their statuses in `defaultStatus`.
pub const Error = error{
    InvalidRequest, // 400
    Unauthenticated, // 401
    PermissionDenied, // 403
    RouteNotFound, // 404
    MethodNotAllowed, // 405, with Allow
    PayloadTooLarge, // 413
    UnsupportedMediaType, // 415
    ValidationFailed, // 422
    RateLimited, // 429
    Overloaded, // 503: .max_in_flight, .max_streams
    Unavailable, // 503
    RequestTimeout, // 504: the deadline of the request passed
    // 500: mistakes of the program.
    ResponseCommitted,
    InvalidHeaderValue,
    /// `setHeader` of a field the backend writes itself.
    ReservedHeader,
    LocalMissing,
    BodyConsumed,
    HandledWithoutResponse,
    /// CR, LF or NUL in the `event` or the `id` of an SSE event.
    InvalidEvent,
};

/// RFC 9457 problem details, with the members `code` and `errors` of
/// zefir: the body of `application/problem+json`.
pub const Problem = struct {
    type: []const u8 = "about:blank",
    title: []const u8,
    status: u16,
    detail: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    /// A stable code: `defaultCode`.
    code: []const u8,
    /// The violations of a 422.
    errors: []const Violation = &.{},
};

/// The status of `err` when nobody maps it: the framework's errors and
/// those of std and core the framework knows; else 500. Pure, callable at
/// compile time.
pub fn defaultStatus(err: anyerror) u16 {
    return switch (err) {
        error.InvalidRequest => 400,
        error.Unauthenticated => 401,
        error.PermissionDenied => 403,
        error.RouteNotFound => 404,
        error.MethodNotAllowed => 405,
        error.PayloadTooLarge => 413,
        error.UnsupportedMediaType => 415,
        error.ValidationFailed => 422,
        error.RateLimited => 429,
        error.Overloaded, error.Unavailable, error.ConcurrencyUnavailable => 503,
        error.RequestTimeout, error.DeadlineExceeded => 504,
        else => 500,
    };
}

/// The stable code of `err` for a response body. Pure, callable at
/// compile time.
pub fn defaultCode(err: anyerror) []const u8 {
    return switch (defaultStatus(err)) {
        400 => "invalid_request",
        401 => "unauthenticated",
        403 => "permission_denied",
        404 => "not_found",
        405 => "method_not_allowed",
        413 => "payload_too_large",
        415 => "unsupported_media_type",
        422 => "validation_failed",
        429 => "rate_limited",
        503 => "unavailable",
        504 => "timeout",
        else => "internal",
    };
}

/// The reason phrase of `defaultStatus(err)`. Pure, callable at compile
/// time.
pub fn defaultTitle(err: anyerror) []const u8 {
    return switch (defaultStatus(err)) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Internal Server Error",
    };
}

/// The error handler of a server without `.error_handler`:
/// problem+json with the framework's status, code and title.
pub const DefaultErrors = struct {
    pub fn problem(err: anyerror) Problem {
        return .{ .title = defaultTitle(err), .status = defaultStatus(err), .code = defaultCode(err) };
    }
};

/// The errors that end a request without a response: the client has gone
/// or the server stops (`Canceled` of std.Io, `Cancelled` of core).
pub fn isCancellation(err: anyerror) bool {
    return err == error.Canceled or err == error.Cancelled;
}

test "the default problem of an error: its status, code and title" {
    const p = DefaultErrors.problem(error.MethodNotAllowed);
    try std.testing.expectEqual(405, p.status);
    try std.testing.expectEqualStrings("method_not_allowed", p.code);
    try std.testing.expectEqualStrings("Method Not Allowed", p.title);
    // An error of the application, of std, or of core.
    try std.testing.expectEqual(500, DefaultErrors.problem(error.TodoNotFound).status);
    try std.testing.expectEqualStrings("internal", defaultCode(error.OutOfMemory));
    try std.testing.expectEqual(504, defaultStatus(error.DeadlineExceeded));
    try std.testing.expectEqual(503, defaultStatus(error.ConcurrencyUnavailable));
    try std.testing.expect(isCancellation(error.Canceled) and isCancellation(error.Cancelled));
    try std.testing.expect(!isCancellation(error.RequestTimeout));
}
